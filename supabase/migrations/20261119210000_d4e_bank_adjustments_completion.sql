-- ============================================================================
-- D4e completion: the gaps found when the feature was reviewed as a whole.
--
-- 1. A decision records WHY it was allowed. approve_bank_adjustment sets
--    self_approved when the one-person exception is in force, but nothing
--    recorded whether a normal two-person approval actually involved two
--    people. Both are now explicit, and a CHECK keeps them consistent.
-- 2. The exception is discoverable by the screen that has to honour it
--    (bank_adjustment_can_self_approve), instead of the UI guessing.
-- 3. An adjustment cannot point at a bank account that is not in the
--    company's registry. approval used to fail only at posting time with
--    ADJ_BANK_MISSING; the proposal is now refused up front, and the line's
--    registry name is what gets stored.
-- 4. An event carries the name of who acted, so the history on screen does
--    not need a second, RLS-different read of app_users.
-- 5. Report reads the screens need, behind finance-only RPCs: the event
--    history of one adjustment, unusual-account usage, and the configured
--    usual accounts with add/remove. The views stay (they are the SQL-level
--    contract and are covered by tests); these are the read paths the web
--    client uses.
--
-- Tax codes stay deferred by decision (19 Nov 2026): no tax column, no tax GL
-- line. A bank charge or interest posting is not re-declared for VAT here;
-- adding it needs a stated accounting treatment (tax account, gross vs net
-- basis, rate source, who reviews) and that has not been agreed.
--
-- Fix forward (rule 9): nothing applied is edited. Idempotent; safe to replay.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Decision provenance on the adjustment itself.
-- ----------------------------------------------------------------------------
alter table public.bank_adjustments
  add column if not exists approval_mode text;

update public.bank_adjustments
   set approval_mode = case when self_approved then 'one_person_exception'
                            else 'two_person' end
 where approval_mode is null
   and status in ('posted', 'reversed', 'rejected');

alter table public.bank_adjustments
  drop constraint if exists bank_adjustments_approval_mode_check;
alter table public.bank_adjustments
  add constraint bank_adjustments_approval_mode_check
  check (approval_mode is null
         or approval_mode in ('two_person', 'one_person_exception'));

-- The flag and the mode must agree in both directions: a self-approved row is
-- always the exception, and the exception is always flagged.
alter table public.bank_adjustments
  drop constraint if exists bank_adjustments_self_approved_mode_check;
alter table public.bank_adjustments
  add constraint bank_adjustments_self_approved_mode_check
  check (
    case when self_approved
         then approval_mode = 'one_person_exception'
         else approval_mode is distinct from 'one_person_exception'
    end
  );

comment on column public.bank_adjustments.approval_mode is
  'How the decision was allowed: two_person (a different finance user approved) or one_person_exception (the creator approved their own under the approved allow_self_approved_bank_adjustments setting). Null while pending.';

-- ----------------------------------------------------------------------------
-- 2. Event actor names (the history screen shows who did what).
-- ----------------------------------------------------------------------------
alter table public.bank_adjustment_events
  add column if not exists actor_name text;

comment on column public.bank_adjustment_events.actor_name is
  'Snapshot of the actor''s name at the time of the event, so the history is readable without joining app_users (whose read policy is narrower than finance''s).';

-- ----------------------------------------------------------------------------
-- 3. approve_bank_adjustment: record the mode, stamp the actor's name.
--    Body identical to 20261119064626 apart from the two additions, which are
--    marked D4e-completion below.
-- ----------------------------------------------------------------------------
create or replace function public.approve_bank_adjustment(p_adjustment_id uuid)
returns public.bank_adjustments
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  v_actor   uuid := public.effective_user_id();
  v_adj     public.bank_adjustments%rowtype;
  v_orig    public.bank_adjustments%rowtype;
  v_line    public.bank_statement_lines%rowtype;
  v_bank    public.fin_bank_accounts%rowtype;
  v_entry   public.journal_entries%rowtype;
  v_lines   jsonb;
  v_desc    text;
  v_self    boolean := false;
  v_setting jsonb;
  v_actor_name text;
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: approving a bank adjustment requires the finance role' using errcode = '42501';
  end if;

  select * into v_adj
    from public.bank_adjustments
   where id = p_adjustment_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'ADJ_NOT_FOUND: adjustment % not found', p_adjustment_id using errcode = '42501';
  end if;
  if v_adj.status <> 'pending' then
    raise exception 'ADJ_NOT_PENDING: this adjustment is already %', v_adj.status;
  end if;

  select * into v_line
    from public.bank_statement_lines
   where id = v_adj.bank_statement_line_id and tenant_id = v_tenant
   for key share;
  if not found then
    raise exception 'ADJ_LINE_STALE: the statement line no longer exists';
  end if;
  perform public.bank_adjustment_validate_counter(v_tenant, v_adj.counter_account_id);

  if v_actor = v_adj.created_by then
    v_setting := public.acct_get_setting('allow_self_approved_bank_adjustments', current_date);
    if coalesce(v_setting ->> 'value', 'false') <> 'true' then
      raise exception 'ADJ_SELF_APPROVAL_FORBIDDEN: the creator cannot approve their own adjustment; a different Finance user must approve' using errcode = '42501';
    end if;
    v_self := true;
  end if;

  -- D4e-completion: one name lookup, used by every event written below.
  select u.name into v_actor_name from public.app_users u where u.id = v_actor;

  if v_adj.kind = 'adjustment' then
    if exists (select 1 from public.bank_reconciliations r where r.bank_statement_line_id = v_line.id) then
      raise exception 'ADJ_LINE_RECONCILED: this statement line was reconciled since the adjustment was created';
    end if;
    perform public.bank_adjustment_check_period(v_tenant, v_adj.statement_date);

    select * into v_bank
      from public.fin_bank_accounts
     where tenant_id = v_tenant and name = v_adj.bank_account
     for share;
    if not found then
      raise exception 'ADJ_BANK_MISSING: no bank account named % is configured for this line', v_adj.bank_account;
    end if;
    if v_bank.gl_account_id is null then
      raise exception 'ADJ_BANK_GL_MISSING: bank account % has no GL account mapped', v_bank.name;
    end if;

    v_desc := left('Bank adjustment - ' || coalesce(v_line.reference, v_line.description, 'statement line') || ': ' || v_adj.reason, 240);
    if v_adj.direction = 'out' then
      v_lines := jsonb_build_array(
        jsonb_build_object('gl_account_id', v_adj.counter_account_id, 'debit',  v_adj.amount, 'currency', v_adj.currency, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_bank.gl_account_id,     'credit', v_adj.amount, 'currency', v_adj.currency, 'description', v_desc));
    else
      v_lines := jsonb_build_array(
        jsonb_build_object('gl_account_id', v_bank.gl_account_id,     'debit',  v_adj.amount, 'currency', v_adj.currency, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_adj.counter_account_id, 'credit', v_adj.amount, 'currency', v_adj.currency, 'description', v_desc));
    end if;

    v_entry := public.post_journal_entry(v_tenant, 'bank_adjustment', v_adj.id,
                                         v_adj.statement_date, v_desc, v_lines);

    perform set_config('app.bank_adjustment_rpc', 'on', true);
    insert into public.bank_reconciliations (
      tenant_id, bank_statement_line_id, bank_adjustment_id, match_type, variance, matched_by
    ) values (
      v_tenant, v_line.id, v_adj.id, 'adjustment', 0, v_actor
    );
    update public.bank_adjustments
       set status = 'posted', decided_by = v_actor,
           decided_at = now(), self_approved = v_self,
           approval_mode = case when v_self then 'one_person_exception' else 'two_person' end,
           journal_entry_id = v_entry.id, updated_at = now()
     where id = v_adj.id
     returning * into v_adj;
    perform set_config('app.bank_adjustment_rpc', 'off', true);

    insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, actor_name, note)
    values (v_tenant, v_adj.id, 'approved', v_actor, v_actor_name,
            'posted via journal ' || v_entry.id::text || case when v_self then ' (self-approved under approved one-person exception)' else '' end);

    return v_adj;
  end if;

  -- Reversal of a posted adjustment: post the opposite entry, un-match the
  -- line, and close both the reversal row and the original.
  select * into v_orig
    from public.bank_adjustments
   where id = v_adj.reverses_adjustment_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'ADJ_REVERSAL_ORIGIN: the adjustment being reversed no longer exists';
  end if;
  if v_orig.status <> 'posted' then
    raise exception 'ADJ_REVERSAL_ORIGIN_STATE: the adjustment being reversed is %', v_orig.status;
  end if;
  if exists (select 1 from public.bank_adjustments a
              where a.reverses_adjustment_id = v_orig.id
                and a.id <> v_adj.id
                and a.status in ('pending', 'posted')) then
    raise exception 'ADJ_REVERSAL_DUPLICATE: a reversal of this adjustment is already pending or posted';
  end if;
  perform public.bank_adjustment_check_period(v_tenant, v_adj.statement_date);

  select * into v_bank
    from public.fin_bank_accounts
   where tenant_id = v_tenant and name = v_orig.bank_account
   for share;
  if not found then
    raise exception 'ADJ_BANK_MISSING: no bank account named % is configured for this line', v_orig.bank_account;
  end if;
  if v_bank.gl_account_id is null then
    raise exception 'ADJ_BANK_GL_MISSING: bank account % has no GL account mapped', v_bank.name;
  end if;

  v_desc := left('Bank adjustment reversal - ' || v_orig.reason || ': ' || v_adj.reason, 240);
  if v_orig.direction = 'out' then
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_bank.gl_account_id,     'debit',  v_orig.amount, 'currency', v_orig.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_orig.counter_account_id, 'credit', v_orig.amount, 'currency', v_orig.currency, 'description', v_desc));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_orig.counter_account_id, 'debit',  v_orig.amount, 'currency', v_orig.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_bank.gl_account_id,     'credit', v_orig.amount, 'currency', v_orig.currency, 'description', v_desc));
  end if;

  v_entry := public.post_journal_entry(v_tenant, 'bank_adjustment_reversal', v_adj.id,
                                       v_adj.statement_date, v_desc, v_lines);

  perform set_config('app.bank_adjustment_rpc', 'on', true);
  delete from public.bank_reconciliations where bank_adjustment_id = v_orig.id;
  update public.bank_adjustments
     set status = 'reversed', reversed_at = now(), updated_at = now()
   where id = v_orig.id;
  update public.bank_adjustments
     set status = 'posted', decided_by = v_actor, decided_at = now(),
         self_approved = v_self,
         approval_mode = case when v_self then 'one_person_exception' else 'two_person' end,
         reversal_journal_entry_id = v_entry.id, updated_at = now()
   where id = v_adj.id
   returning * into v_adj;
  perform set_config('app.bank_adjustment_rpc', 'off', true);

  insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, actor_name, note)
  values (v_tenant, v_orig.id, 'reversed', v_actor, v_actor_name, 'reversed via ' || v_entry.id::text || ': ' || v_adj.reason),
         (v_tenant, v_adj.id,  'approved', v_actor, v_actor_name, 'reversal posted via journal ' || v_entry.id::text);

  return v_adj;
end;
$function$;

revoke all on function public.approve_bank_adjustment(uuid) from public, anon;
grant execute on function public.approve_bank_adjustment(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. create_bank_adjustment: refuse an unregistered bank account, store the
--    registry name, and stamp the actor's name on the event.
--    Body identical to 20261119064626 apart from the marked additions.
-- ----------------------------------------------------------------------------
create or replace function public.create_bank_adjustment(
  p_statement_line_id uuid,
  p_counter_account_id uuid,
  p_reason text,
  p_reworked_from uuid default null
)
returns public.bank_adjustments
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_actor  uuid := public.effective_user_id();
  v_line   public.bank_statement_lines%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_adj    public.bank_adjustments%rowtype;
  v_rework public.bank_adjustments%rowtype;
  v_bank   public.fin_bank_accounts%rowtype;
  v_event  text := 'created';
  v_actor_name text;
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: creating a bank adjustment requires the finance role' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'ADJ_REASON: a reason of at least 5 characters is required';
  end if;

  select * into v_line
    from public.bank_statement_lines
   where id = p_statement_line_id and tenant_id = v_tenant
   for key share;
  if not found then
    raise exception 'ADJ_LINE_NOT_FOUND: statement line not found in this company' using errcode = '42501';
  end if;

  -- D4e-completion: the bank must be in the registry before an adjustment is
  -- proposed, not only when it posts. An unrecognised statement account is a
  -- data problem the reconciler should fix (register the bank, or re-import),
  -- not something to book against. Resolution is by name, the same key the
  -- statement rows and the posting path use.
  select * into v_bank
    from public.fin_bank_accounts
   where tenant_id = v_tenant and name = v_line.bank_account
   for share;
  if not found then
    raise exception 'ADJ_BANK_UNREGISTERED: bank account % on this statement line is not in the bank account registry; register it (with its GL account) before adjusting its lines', v_line.bank_account
      using errcode = '42501';
  end if;
  if v_bank.gl_account_id is null then
    raise exception 'ADJ_BANK_GL_MISSING: bank account % has no GL account mapped', v_bank.name;
  end if;

  if exists (select 1 from public.bank_reconciliations r where r.bank_statement_line_id = v_line.id) then
    raise exception 'ADJ_LINE_RECONCILED: this statement line is already reconciled';
  end if;

  if exists (select 1 from public.bank_adjustments a
              where a.bank_statement_line_id = v_line.id
                and a.kind = 'adjustment'
                and a.status in ('pending', 'posted')) then
    raise exception 'ADJ_LIVE_EXISTS: an adjustment for this statement line is already pending or posted';
  end if;

  perform public.bank_adjustment_validate_counter(v_tenant, p_counter_account_id);
  perform public.bank_adjustment_check_period(v_tenant, v_line.statement_date);

  if p_reworked_from is not null then
    select * into v_rework
      from public.bank_adjustments
     where id = p_reworked_from and tenant_id = v_tenant;
    if not found then
      raise exception 'ADJ_REWORK_NOT_FOUND: the adjustment being reworked was not found' using errcode = '42501';
    end if;
    if v_rework.kind <> 'adjustment' or v_rework.status <> 'rejected' then
      raise exception 'ADJ_REWORK_STATE: only a rejected adjustment can be reworked';
    end if;
    if v_rework.bank_statement_line_id <> v_line.id then
      raise exception 'ADJ_REWORK_LINE: a rework must reference the same statement line as the rejected adjustment';
    end if;
    v_event := 'reworked';
  end if;

  -- D4e-completion: one name lookup for the event.
  select u.name into v_actor_name from public.app_users u where u.id = v_actor;

  perform set_config('app.bank_adjustment_rpc', 'on', true);
  insert into public.bank_adjustments (
    tenant_id, kind, bank_statement_line_id, bank_account, statement_date,
    amount, currency, direction, counter_account_id, reason,
    status, reworked_from, created_by
  ) values (
    v_tenant, 'adjustment', v_line.id, v_bank.name, v_line.statement_date,
    abs(v_line.amount), v_line.currency, case when v_line.amount >= 0 then 'in' else 'out' end,
    p_counter_account_id, v_reason,
    'pending', p_reworked_from, v_actor
  ) returning * into v_adj;
  perform set_config('app.bank_adjustment_rpc', 'off', true);

  insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, actor_name, note)
  values (v_tenant, v_adj.id, v_event, v_actor, v_actor_name,
          case when p_reworked_from is not null then 'rework of adjustment ' || p_reworked_from::text end);

  return v_adj;
end;
$function$;

revoke all on function public.create_bank_adjustment(uuid, uuid, text, uuid) from public, anon;
grant execute on function public.create_bank_adjustment(uuid, uuid, text, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. reject / reversal-request: stamp the actor's name too. Bodies unchanged
--    from 20261119064626 apart from the actor_name column in the event.
-- ----------------------------------------------------------------------------
create or replace function public.reject_bank_adjustment(p_adjustment_id uuid, p_reason text)
returns public.bank_adjustments
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_actor  uuid := public.effective_user_id();
  v_adj    public.bank_adjustments%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_actor_name text;
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: rejecting a bank adjustment requires the finance role' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'ADJ_REASON: a rejection reason of at least 5 characters is required';
  end if;

  select * into v_adj
    from public.bank_adjustments
   where id = p_adjustment_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'ADJ_NOT_FOUND: adjustment % not found', p_adjustment_id using errcode = '42501';
  end if;
  if v_adj.status <> 'pending' then
    raise exception 'ADJ_NOT_PENDING: this adjustment is already %', v_adj.status;
  end if;

  select u.name into v_actor_name from public.app_users u where u.id = v_actor;

  perform set_config('app.bank_adjustment_rpc', 'on', true);
  update public.bank_adjustments
     set status = 'rejected', decided_by = v_actor, decided_at = now(),
         rejection_reason = v_reason, updated_at = now()
   where id = v_adj.id
   returning * into v_adj;
  perform set_config('app.bank_adjustment_rpc', 'off', true);

  insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, actor_name, note)
  values (v_tenant, v_adj.id, 'rejected', v_actor, v_actor_name, v_reason);

  return v_adj;
end;
$function$;

revoke all on function public.reject_bank_adjustment(uuid, text) from public, anon;
grant execute on function public.reject_bank_adjustment(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Can this user approve their own proposal? The screen asks instead of
--    assuming. Read-only, finance-only, no tenant id argument.
-- ----------------------------------------------------------------------------
create or replace function public.bank_adjustment_can_self_approve()
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_setting jsonb;
begin
  if v_tenant is null then
    return false;
  end if;
  if not public.is_finance_team_member('finance') then
    return false;
  end if;
  v_setting := public.acct_get_setting('allow_self_approved_bank_adjustments', current_date);
  return coalesce(v_setting ->> 'value', 'false') = 'true';
exception
  when others then
    -- A missing or unreadable setting is not permission.
    return false;
end;
$function$;

revoke all on function public.bank_adjustment_can_self_approve() from public, anon;
grant execute on function public.bank_adjustment_can_self_approve() to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Event history for one adjustment (screen read).
-- ----------------------------------------------------------------------------
create or replace function public.bank_adjustment_history(p_adjustment_id uuid)
returns table (
  event       text,
  actor_id    uuid,
  actor_name  text,
  note        text,
  created_at  timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null or not public.is_finance_team_member(null) then
    raise exception 'not authorized: reading bank adjustment history requires the finance role' using errcode = '42501';
  end if;
  if not exists (select 1 from public.bank_adjustments a
                  where a.id = p_adjustment_id and a.tenant_id = v_tenant) then
    raise exception 'ADJ_NOT_FOUND: adjustment % not found', p_adjustment_id using errcode = '42501';
  end if;

  return query
    select e.event, e.actor_id,
           coalesce(e.actor_name, u.name, 'Unknown user'),
           e.note, e.created_at
      from public.bank_adjustment_events e
      left join public.app_users u on u.id = e.actor_id
     where e.tenant_id = v_tenant and e.adjustment_id = p_adjustment_id
     order by e.created_at, e.id;
end;
$function$;

revoke all on function public.bank_adjustment_history(uuid) from public, anon;
grant execute on function public.bank_adjustment_history(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 8. Unusual-account usage (screen read). p_days limits the window; null means
--    everything posted, newest first.
-- ----------------------------------------------------------------------------
create or replace function public.bank_adjustment_unusual_account_usage(p_days integer default 90)
returns table (
  adjustment_id     uuid,
  bank_account      text,
  statement_date    date,
  currency          text,
  amount            numeric,
  direction         text,
  counter_account_code text,
  counter_account_name text,
  reason            text,
  created_by_name   text,
  approver_name     text,
  approval_date     timestamptz,
  posting_journal_reference uuid,
  self_approved     boolean
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null or not public.is_finance_team_member(null) then
    raise exception 'not authorized: reading unusual account usage requires the finance role' using errcode = '42501';
  end if;

  return query
    select v.adjustment_id, v.bank_account, v.statement_date, v.currency,
           v.amount, v.direction, v.counter_account_code, v.counter_account_name,
           v.reason, v.created_by_name, v.approver_name, v.approval_date,
           v.posting_journal_reference, v.self_approved
      from public.bank_adjustment_unusual_accounts v
     where v.tenant_id = v_tenant
       and (p_days is null or v.statement_date >= current_date - p_days)
     order by v.statement_date desc, v.approval_date desc;
end;
$function$;

revoke all on function public.bank_adjustment_unusual_account_usage(integer) from public, anon;
grant execute on function public.bank_adjustment_unusual_account_usage(integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 9. Usual accounts: the config the report is measured against. Writes go
--    through RPCs so the screen never needs table write privileges (and F1's
--    tightening of the table grants stays true).
-- ----------------------------------------------------------------------------
create or replace function public.bank_adjustment_list_usual_accounts()
returns table (
  gl_account_id uuid,
  account_code  text,
  account_name  text,
  created_at    timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null or not public.is_finance_team_member(null) then
    raise exception 'not authorized: reading usual bank adjustment accounts requires the finance role' using errcode = '42501';
  end if;
  return query
    select u.gl_account_id, g.account_code, g.name, u.created_at
      from public.bank_adjustment_usual_accounts u
      join public.gl_accounts g on g.id = u.gl_account_id
     where u.tenant_id = v_tenant
     order by g.account_code;
end;
$function$;

revoke all on function public.bank_adjustment_list_usual_accounts() from public, anon;
grant execute on function public.bank_adjustment_list_usual_accounts() to authenticated;

create or replace function public.bank_adjustment_add_usual_account(p_gl_account_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: changing usual bank adjustment accounts requires the finance role' using errcode = '42501';
  end if;
  if not exists (select 1 from public.gl_accounts g
                  where g.id = p_gl_account_id and g.tenant_id = v_tenant and g.is_active) then
    raise exception 'ADJ_USUAL_ACCOUNT: that account is not an active account in this company' using errcode = '42501';
  end if;
  insert into public.bank_adjustment_usual_accounts (tenant_id, gl_account_id, created_by)
  values (v_tenant, p_gl_account_id, public.effective_user_id())
  on conflict (tenant_id, gl_account_id) do nothing;
end;
$function$;

revoke all on function public.bank_adjustment_add_usual_account(uuid) from public, anon;
grant execute on function public.bank_adjustment_add_usual_account(uuid) to authenticated;

create or replace function public.bank_adjustment_remove_usual_account(p_gl_account_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: changing usual bank adjustment accounts requires the finance role' using errcode = '42501';
  end if;
  delete from public.bank_adjustment_usual_accounts u
   where u.tenant_id = v_tenant and u.gl_account_id = p_gl_account_id;
end;
$function$;

revoke all on function public.bank_adjustment_remove_usual_account(uuid) from public, anon;
grant execute on function public.bank_adjustment_remove_usual_account(uuid) to authenticated;
