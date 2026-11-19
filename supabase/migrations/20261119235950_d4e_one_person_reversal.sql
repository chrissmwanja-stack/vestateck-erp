-- ============================================================================
-- D4e: the one-person exception must work for the ACTIONS that only one person
-- can perform.
--
-- The exception exists for a team where the person who prepares a posting is
-- the only person who can approve anything. Two paths still locked that team
-- out even with an approved, compliance-reviewed exception in force:
--
--   1. withdraw a rejected-or-pending proposal of their own. reject_bank_adjustment
--      has no creator/approver distinction — anyone on finance could always
--      reject anything — so this is not a new permission, it is the same one
--      that was already there, made explicit so the screen can say "Withdraw".
--
--   2. reverse an adjustment they posted themselves. Reversal is deliberately
--      a request plus an independent approval, and that stays true. But when
--      the same person created the original adjustment, the reversal row's
--      creator is that person, so approving it raised ADJ_SELF_APPROVAL_FORBIDDEN
--      and the reversal could never complete: a wrong posting would be stuck
--      posted forever with no way back except a manual journal.
--
-- The rule this file implements, stated once: the exception is about approving
-- YOUR OWN submission, and it is honoured wherever that situation arises —
-- adjustments and reversals alike. It is still recorded (approval_mode =
-- one_person_exception, self_approved = true) and still requires the setting to
-- be approved AND compliance-reviewed (20261119220000). Where a genuinely
-- different finance user is available, nothing changes for them.
--
-- approve_bank_adjustment is the only function re-created here; the exception
-- check itself is unchanged from 20261119220000. The fix is in the reversal
-- branch: it now compares the reversal's creator with the ACTOR (as the
-- adjustment branch does) rather than assuming a different actor, and refuses
-- self-approval of a reversal only when the exception is not in force.
--
-- Fix forward (rule 9): nothing applied is edited. Idempotent.
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

  -- A different finance user, or the company's one-person exception. Same check
  -- for an adjustment and for a reversal request: what matters is whether the
  -- actor wrote the row they are now approving.
  if v_actor = v_adj.created_by then
    begin
      v_exception := public.acct_assert_reviewed('allow_self_approved_bank_adjustments', current_date);
    exception
      when others then
        v_exception := null;
    end;
    if coalesce(v_exception, 'false') <> 'true' then
      raise exception 'ADJ_SELF_APPROVAL_FORBIDDEN: the creator cannot approve their own %, a different Finance user must approve, or the company must have an approved and compliance-reviewed one-person exception', case when v_adj.kind = 'reversal' then 'reversal request' else 'adjustment' end using errcode = '42501';
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

  -- Reversal. The origin is re-read and re-checked: it may have changed since
  -- the request was raised.
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
  values (v_tenant, v_orig.id, 'reversed', v_actor, v_actor_name,
          'reversed via ' || v_entry.id::text || ': ' || v_adj.reason || case when v_self then ' (self-approved reversal under approved one-person exception)' else '' end),
         (v_tenant, v_adj.id,  'approved', v_actor, v_actor_name, 'reversal posted via journal ' || v_entry.id::text);

  return v_adj;
end;
$function$;

revoke all on function public.approve_bank_adjustment(uuid) from public, anon;
grant execute on function public.approve_bank_adjustment(uuid) to authenticated;
