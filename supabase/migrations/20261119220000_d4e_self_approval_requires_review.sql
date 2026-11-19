-- ============================================================================
-- D4e safety: using the one-person self-approval exception requires a
-- compliance-reviewed setting, not merely an approved one.
--
-- Why. allow_self_approved_bank_adjustments is declared with
-- requires_legal_review = true: a company admin cannot plausibly decide on
-- their own that segregation of duties may be switched off. The settings
-- workflow records two separate attestations for such a key — an admin
-- approves the choice, and a named accountant/adviser review is recorded on it
-- (acct_setting_record_review). Everything that posts money reads a legal key
-- through acct_assert_reviewed(), which raises ACCT_LEGAL_UNREVIEWED until both
-- exist.
--
-- approve_bank_adjustment did not: it resolved the key through acct_get_setting
-- and compared the value, so an approved-but-never-reviewed exception would
-- have let a finance user approve their own adjustment. That is the one place
-- in this feature where a control depends on a setting being taken seriously,
-- so it now uses the same reviewed-setting gate as the rest of the ledger.
--
-- Nothing else changes: the refusal is still ADJ_SELF_APPROVAL_FORBIDDEN with
-- errcode 42501, so callers and tests that assert on that error keep working,
-- and a company that has not configured the key at all is refused exactly as
-- before (acct_assert_reviewed raises, this treats that as "not in force").
--
-- bank_adjustment_can_self_approve() moves with it, so the screen never offers
-- an approval the server would refuse.
--
-- Fix forward (rule 9): 20261119064626 and 20261119210000 are not edited.
-- Idempotent; safe to replay.
-- ============================================================================

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
  v_exception text;
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

  -- A different finance user, or the company's one-person exception. The
  -- exception only counts when the approved value in force has also been
  -- compliance-reviewed (see the header); any failure to read it is "not in
  -- force", which is the safe answer.
  if v_actor = v_adj.created_by then
    begin
      v_exception := public.acct_assert_reviewed('allow_self_approved_bank_adjustments', current_date);
    exception
      when others then
        v_exception := null;
    end;
    if coalesce(v_exception, 'false') <> 'true' then
      raise exception 'ADJ_SELF_APPROVAL_FORBIDDEN: the creator cannot approve their own adjustment; a different Finance user must approve, or the company must have an approved and compliance-reviewed one-person exception' using errcode = '42501';
    end if;
    v_self := true;
  end if;

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

-- The screen's question must match the server's answer, or the button lies.
create or replace function public.bank_adjustment_can_self_approve()
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null then
    return false;
  end if;
  if not public.is_finance_team_member('finance') then
    return false;
  end if;
  -- acct_assert_reviewed raises unless the approved value in force has a
  -- recorded compliance review; anything it refuses is "not in force".
  return public.acct_assert_reviewed('allow_self_approved_bank_adjustments', current_date) = 'true';
exception
  when others then
    return false;
end;
$function$;

revoke all on function public.bank_adjustment_can_self_approve() from public, anon;
grant execute on function public.bank_adjustment_can_self_approve() to authenticated;
