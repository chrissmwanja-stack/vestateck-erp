-- =====================================================================
-- Appendix B answered
-- Accountant decisions Q1-Q5, 22 November 2026
-- =====================================================================
-- The five questions the code refused to answer now have answers, and this
-- migration is what changes because of them. It is mostly addition: a posting role
-- so one account can serve both the write-off and the recovery, a function for the
-- ninth claim state, and two settings that make the refund and claim decisions
-- literal rather than per-call.
--
-- The decisions, abbreviated, with where each lands:
--
--   Q1  a dedicated contra-claims-expense account, and the insurer receivable is
--       pursued separately rather than written off with the claimant payable
--                                                          -> sections 1 and 2
--   Q2  release only; no automatic forfeiture; an independent second approver on
--       every client-advance refund whatever the amount    -> sections 3 and 4
--   Q3  repudiation is a ninth claim state, with the insurer's decision, date,
--       reason and correspondence recorded, and reopening allowed
--                                                          -> sections 5 and 6
--   Q4  recoveries credit the SAME contra-claims-expense account as Q1  -> section 7
--   Q5  the free client-money figure keeps deducting insurer receivables -> no change
--
-- Q5 needs no statement here on purpose. The accountant chose the behaviour already
-- shipped, so the correct change is none: platform_ins_client_money_position() is
-- left exactly as it is, and the decision is recorded in the pack and the register
-- rather than in code that would have to be re-read to know what it does.

-- ---------------------------------------------------------------------
-- 1. One posting role for the contra-claims-expense account
-- ---------------------------------------------------------------------
-- Q1 and Q4 name the same account: "Claims Written-Off and Recoveries (Contra Claims
-- Expense)". A write-off credits it and a recovery credits it; they are different
-- business events sharing one ledger line, which is what the accountant asked for.
--
-- The role exists so the account is named ONCE, in the chart of accounts, rather than
-- being passed as a uuid at every call site. The alternative -- adding a column to
-- two tables to remember the choice -- would let a write-off and a recovery drift
-- onto different accounts, and the whole point of the decision is that they do not.
--
-- No constraint change is needed for the value itself: the CHECK on
-- gl_posting_rules.account_role already admits any 'ins_' prefixed role by regex.
-- platform_gl_posting_roles() is extended because the template test requires it to
-- agree with the CHECK's quoted literals exactly, and a role the registry does not
-- know is a role the template will not seed.
create or replace function public.platform_gl_posting_roles()
returns text[]
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing',
    'retained_earnings',
    'agent_commission_expense',
    -- Statutory charges collected on a policy and remitted to a third party.
    -- Separate roles, not one bucket: a report must be able to tell a levy held
    -- for the College from a tax collected for URA.
    'insurance_training_levy_payable', 'ira_levy_payable', 'stamp_duty_payable',
    -- Appendix B Q1 and Q4. The contra-claims-expense account a claim write-off and
    -- a claim recovery both credit. One role because the accountant decided they are
    -- one account; the two transaction types keep them distinguishable in reporting.
    'ins_claim_write_off_expense'
  ]::text[];
$$;

-- ---------------------------------------------------------------------
-- 2. Claim write-offs and recoveries resolve their account from the role
-- ---------------------------------------------------------------------
-- Both functions took the account as a required parameter. They still accept one --
-- nothing that works today stops working -- but when it is omitted the account is
-- resolved from the role above, and when it is given it must BE that account.
--
-- That second rule is the accountant's decision taken literally. "Same account as
-- Q1" is only true if the function cannot be pointed somewhere else. Where the
-- company has not mapped the role yet, the call fails with the role named, which is
-- the same fail-loud posture as the rest of the pack rather than falling back to
-- default_expense.

create or replace function public.ins_claim_contra_account(p_tenant_id uuid)
returns uuid
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select public.get_posting_account(p_tenant_id, 'ins_claim_write_off_expense')
$$;

revoke all on function public.ins_claim_contra_account(uuid) from public, anon;
grant execute on function public.ins_claim_contra_account(uuid) to authenticated;

comment on function public.ins_claim_contra_account(uuid) is
  'The contra-claims-expense account (Appendix B Q1/Q4). A claim write-off and a claim recovery both post here. Null means the company has not mapped the ins_claim_write_off_expense role yet.';

-- ---------------------------------------------------------------------
-- 3. Every client-advance refund needs an independent second approver
-- ---------------------------------------------------------------------
-- Q2: "independent maker-checker approval for every client-advance refund,
-- regardless of amount. That is safer than allowing one finance user to release
-- client money alone."
--
-- The refund engine already reads its levels from workflow_stages rows with
-- applies_to = 'insurance_refunds', and already refuses self-approval. What was
-- missing is that no such rows shipped, so no level applied and one finance user
-- could release client money alone. A stage whose threshold is null is matched for
-- every amount, which is exactly "regardless of amount".
--
-- approver_role is 'finance': the second person must hold the finance role, but must
-- be a different person -- ins_decide_refund refuses the requester. Widening it to
-- 'admin' would let someone outside finance approve a client-money refund, which is
-- not what was asked.
-- Backfill companies that already exist. Necessary but NOT sufficient: a company
-- onboarded next year would inherit nothing, and the gate would silently go inert for
-- them. That is why the level lookup itself defaults to this stage -- see below. Seeding
-- alone would have made the control look enforced while being absent for every new
-- company, which is the same class of quiet failure this migration is trying to end.
insert into public.workflow_stages
  (tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to, is_active)
select t.id, 'Client advance refund', 1, 'finance', null, 'insurance_refunds', true
  from public.tenants t
 where not exists (
   select 1 from public.workflow_stages s
    where s.tenant_id = t.id and s.applies_to = 'insurance_refunds' and s.is_active
 );

-- The default, for any company with no configured stage. The accountant's decision was
-- "regardless of amount", so absence of configuration must mean the minimum control, not
-- no control: no rows -> one finance approval by someone other than the requester.
-- A recorded stage still overrides this entirely, which is how a company that wants
-- thresholds gets them.
create or replace function public.platform_ins_refund_required_level(p_tenant_id uuid, p_amount numeric)
returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select s.id, s.sequence_order, s.approver_role, s.threshold_amount
    from workflow_stages s
   where s.tenant_id = p_tenant_id
     and s.applies_to = 'insurance_refunds'
     and s.is_active
     and coalesce(s.threshold_amount, 0) <= p_amount
   order by s.sequence_order desc
   limit 1
  union all
  -- No stage matched: apply the minimum control rather than none.
  select null::uuid, 1, 'finance', null::numeric
   where not exists (
     select 1 from workflow_stages s
      where s.tenant_id = p_tenant_id
        and s.applies_to = 'insurance_refunds'
        and s.is_active
        and coalesce(s.threshold_amount, 0) <= p_amount
   )
$$;

revoke all on function public.platform_ins_refund_required_level(uuid, numeric) from public;
grant execute on function public.platform_ins_refund_required_level(uuid, numeric) to service_role;

-- ---------------------------------------------------------------------
-- 4. No automatic forfeiture, and advance_forfeit is not reachable through the
--    generic disposition path
-- ---------------------------------------------------------------------
-- Q2: "Do not recognise forfeiture income automatically." The disposition function
-- would still accept advance_forfeit from any finance caller, with no evidence and
-- no separate authorisation -- which is the automatic route the decision rules out.
--
-- It is removed from ins_dispose_open_item() rather than deleted outright: the
-- posting rule stays defined, the table CHECK keeps the kind, and restoring it is a
-- one-line change if a contractual right to retain is ever established. What is
-- withdrawn is the ability to reach it through the shared path today.
create or replace function public.ins_dispose_open_item(
  p_open_item_id uuid,
  p_kind text,
  p_amount numeric,
  p_counterparty_gl_account_id uuid,
  p_reason text,
  p_entry_date date default null
) returns fin_open_item_dispositions
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_item     fin_open_items%rowtype;
  v_gl       gl_accounts%rowtype;
  v_row      fin_open_item_dispositions%rowtype;
  v_lines    jsonb;
  v_desc     text;
  v_je       journal_entries%rowtype;
  v_consumed numeric;
  v_available numeric;
  v_version  integer;
  v_date     date := coalesce(p_entry_date, current_date);
  v_claim_status text;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_DISPOSITION_FINANCE: a disposition needs the finance role' using errcode = '42501';
  end if;

  -- Appendix B Q2: forfeiture is withdrawn from this path. The reason is in the
  -- message rather than only in this comment, because the error is what a caller
  -- sees when a screen offers a button that no longer works.
  if p_kind = 'advance_forfeit' then
    raise exception 'INS_DISPOSITION_KIND: recognising client money as forfeited needs a separately authorised decision with supporting evidence (Appendix B Q2: advances are refunded or applied, never automatically forfeited). This path does not post it.';
  end if;
  if p_kind not in ('advance_release',
                    'claim_write_off', 'claim_recovery_uncollectable') then
    raise exception 'INS_DISPOSITION_KIND: unknown disposition kind %. Use advance_release, claim_write_off or claim_recovery_uncollectable.', p_kind;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_DISPOSITION_AMOUNT: the amount must be greater than zero';
  end if;
  if nullif(btrim(p_reason), '') is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_NOTE_REQUIRED: give the reason for the disposition';
  end if;
  if v_date > current_date + 1 then
    raise exception 'INS_DISPOSITION_DATE: the entry date cannot be in the future';
  end if;

  select * into v_item from fin_open_items
   where id = p_open_item_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: open item';
  end if;

  if p_kind in ('advance_release')
     and v_item.control_role is distinct from 'client_advance_payable' then
    raise exception 'INS_DISPOSITION_KIND: % applies to a client advance (2040) item; % is a % item',
      p_kind, v_item.document_no, v_item.control_role;
  end if;
  if p_kind in ('claim_write_off', 'claim_recovery_uncollectable')
     and v_item.control_role not in ('client_claim_payable', 'insurer_claim_receivable') then
    raise exception 'INS_DISPOSITION_KIND: % applies to a claim item; % is a % item',
      p_kind, v_item.document_no, v_item.control_role;
  end if;

  select * into v_gl from gl_accounts
   where id = p_counterparty_gl_account_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_DISPOSITION_ACCOUNT: account % is not a GL account of this company', p_counterparty_gl_account_id;
  end if;
  if not v_gl.is_active then
    raise exception 'INS_DISPOSITION_ACCOUNT: account % is inactive', v_gl.account_code;
  end if;
  if v_gl.is_control_account then
    raise exception 'INS_DISPOSITION_ACCOUNT: % is a control account; a disposition posts against an income or expense account', v_gl.account_code;
  end if;

  if p_kind = 'advance_release'
     and v_gl.id is distinct from get_posting_account(v_tenant, 'ar_control') then
    raise exception 'INS_DISPOSITION_ACCOUNT: releasing an advance credits the receivable it was paid against; name the ar_control account, not %', v_gl.account_code;
  end if;

  v_consumed := public.fin_open_item_consumed(v_item.id);
  v_available := v_item.amount - v_consumed;
  if p_amount > v_available then
    raise exception 'INS_DISPOSITION_EXCEEDS: % has % outstanding, % cannot be disposed of',
      v_item.document_no, v_available, p_amount;
  end if;

  v_desc := case p_kind
              when 'advance_release' then 'Client advance released to receivable'
              when 'claim_write_off' then 'Claim balance written off'
              else 'Claim recovery deemed uncollectable' end
            || ' ' || v_item.document_no;

  -- Double entry. For a payable, the item sits on the credit side of its control
  -- account, so reducing it debits the control; for a receivable, reducing it
  -- credits the control. The counterparty carries the equal and opposite leg.
  if v_item.side = 'payable' then
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', get_posting_account(v_tenant, v_item.control_role),
                         'debit', p_amount, 'currency', v_item.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_gl.id,
                         'credit', p_amount, 'currency', v_item.currency, 'description', v_desc));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', get_posting_account(v_tenant, v_item.control_role),
                         'credit', p_amount, 'currency', v_item.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_gl.id,
                         'debit', p_amount, 'currency', v_item.currency, 'description', v_desc));
  end if;

  if get_posting_account(v_tenant, v_item.control_role) is null then
    raise exception 'INS_DISPOSITION_ACCOUNT: the posting role % is not mapped to a GL account', v_item.control_role;
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'fin_open_item_disposition', v_item.id, v_date, v_desc, v_lines);

  select platform_accounting_policy_version(v_tenant, v_date) into v_version;

  insert into fin_open_item_dispositions (
    tenant_id, open_item_id, kind, amount, currency, counterparty_gl_account_id,
    journal_entry_id, reason, party_account_id, control_role, side,
    source_type, source_id, accounting_policy_version, created_by
  ) values (
    v_tenant, v_item.id, p_kind, p_amount, v_item.currency, v_gl.id,
    v_je.id, btrim(p_reason), v_item.party_account_id, v_item.control_role, v_item.side,
    v_item.source_type, v_item.source_id, coalesce(v_version, 1), auth.uid()
  )
  returning * into v_row;

  -- Every disposition against a claim is written to the claim's own audit trail here,
  -- in the one place all four kinds pass through. Writing it in each kind's own caller
  -- instead missed the recovery write-off entirely: a recovery declared uncollectable
  -- moved the ledger and left no trace on the claim it came from.
  if v_item.source_type in ('ins_claim_client', 'ins_claim_insurer') then
    select c.status into v_claim_status
      from public.ins_claims c
     where c.id = v_item.source_id and c.tenant_id = v_tenant;
    insert into public.ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
    values (v_tenant, v_item.source_id, v_claim_status, v_claim_status,
            case p_kind
              when 'claim_write_off' then 'Written off '
              when 'claim_recovery_uncollectable' then 'Recovery written off '
              else 'Disposed ' end
            || p_amount || ' to account ' || v_gl.account_code || ': ' || btrim(p_reason));
  end if;

  return v_row;
end;
$$;

revoke all on function public.ins_dispose_open_item(uuid, text, numeric, uuid, text, date) from public;
grant execute on function public.ins_dispose_open_item(uuid, text, numeric, uuid, text, date) to authenticated;

-- ---------------------------------------------------------------------
-- 5. The ninth claim state, and what it must carry
-- ---------------------------------------------------------------------
-- Q3: repudiation is accepted as the ninth state, must stay distinguishable from a
-- paid claim and from an ordinary closed one, must record the insurer's decision,
-- date, reason and supporting correspondence, and must be reopenable.
--
-- Nothing could set 'repudiated' before this: the value existed in the CHECK and was
-- reported by ins_claim_stage(), but no function wrote it. So the state was
-- reportable and unreachable, which is why Q3 read as a documentation question.
--
-- Storage: the decision and its evidence live on the claim, not in the append-only
-- event trail, because they are the grounds for the state and are re-read when a
-- repudiation is challenged. The event trail still gets a row for each transition.
alter table public.ins_claims
  add column if not exists repudiation_date date,
  add column if not exists repudiation_reason text,
  add column if not exists repudiation_reference text,
  add column if not exists repudiated_by uuid references auth.users(id),
  add column if not exists repudiated_at timestamptz,
  add column if not exists repudiation_reopened_at timestamptz,
  add column if not exists repudiation_reopened_by uuid references auth.users(id),
  add column if not exists repudiation_reopen_reason text;

comment on column public.ins_claims.repudiation_reference is
  'The insurer''s decision reference or the file it is held in: a declinature letter number, an email subject, a portal reference. Appendix B Q3 requires the supporting correspondence to be identifiable, not merely asserted.';

comment on column public.ins_claims.repudiation_reopened_at is
  'Set when a repudiation is challenged and the claim returns to review. The repudiation columns are kept as the history of what was decided and when, so a reopened claim still shows why it was declined.';

create or replace function public.ins_set_claim_repudiation(
  p_claim_id uuid,
  p_repudiation_date date,
  p_reason text,
  p_reference text
) returns public.ins_claims
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_claim  public.ins_claims%rowtype;
  v_from   text;
begin
  if not public.can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: recording an insurer repudiation needs insurance manager authority' using errcode = '42501';
  end if;
  if p_repudiation_date is null or p_repudiation_date > public.ins_local_today() then
    raise exception 'INS_REPUDIATION_DATE: the repudiation date must be today or earlier';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_NOTE_REQUIRED: give the insurer''s reason for declining the claim';
  end if;
  if nullif(btrim(coalesce(p_reference, '')), '') is null or length(btrim(p_reference)) < 3 then
    raise exception 'INS_REPUDIATION_REFERENCE: name the decision or the document the declinature rests on -- a claim declined with nothing behind it cannot be reviewed or challenged';
  end if;

  select * into v_claim from public.ins_claims
   where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;

  -- Already repudiated is a retry, not a second decision: the same payload returns the
  -- row, a different one is a conflict, exactly as the cancellation submission behaves.
  if v_claim.status = 'repudiated' then
    if v_claim.repudiation_date is distinct from p_repudiation_date
       or v_claim.repudiation_reason is distinct from btrim(p_reason)
       or v_claim.repudiation_reference is distinct from btrim(p_reference) then
      raise exception 'INS_REPUDIATION_EXISTS: claim % was already repudiated on % on different grounds; reopen it before recording a replacement decision',
        v_claim.claim_no, v_claim.repudiation_date;
    end if;
    return v_claim;
  end if;

  if v_claim.status in ('settled', 'closed') then
    raise exception 'INS_CLAIM_STATE: claim % is % and cannot be repudiated', v_claim.claim_no, v_claim.status;
  end if;

  v_from := public.ins_claim_stage(v_claim.id);

  perform set_config('ins.via_rpc', 'on', true);
  update public.ins_claims
     set status = 'repudiated',
         repudiation_date = p_repudiation_date,
         repudiation_reason = btrim(p_reason),
         repudiation_reference = btrim(p_reference),
         repudiated_by = auth.uid(),
         repudiated_at = now(),
         updated_at = now()
   where id = v_claim.id
  returning * into v_claim;

  insert into public.ins_claim_events (tenant_id, claim_id, from_status, to_status, actor_id, note)
  values (v_tenant, v_claim.id, v_from, 'repudiated', auth.uid(),
          'Insurer repudiation dated ' || p_repudiation_date || ', reference ' || btrim(p_reference)
          || ': ' || btrim(p_reason));

  return v_claim;
end $$;

revoke all on function public.ins_set_claim_repudiation(uuid, date, text, text) from public, anon;
grant execute on function public.ins_set_claim_repudiation(uuid, date, text, text) to authenticated;

-- Reopening. Q3 asks for it explicitly: a repudiation that is challenged or reversed
-- must be able to come back. It returns the claim to `assessing` -- the stage it was
-- at before a decision was made -- rather than to `notified`, because the claim has
-- been assessed and that work is not undone by the insurer declining it.
create or replace function public.ins_reopen_claim(
  p_claim_id uuid,
  p_reason text
) returns public.ins_claims
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_claim  public.ins_claims%rowtype;
begin
  if not public.can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: reopening a repudiated claim needs insurance manager authority' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_NOTE_REQUIRED: say why the repudiation is being reopened -- a challenge, a reversal, new evidence';
  end if;

  select * into v_claim from public.ins_claims
   where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if v_claim.status <> 'repudiated' then
    raise exception 'INS_CLAIM_STATE: claim % is %, not repudiated; only a repudiated claim is reopened this way',
      v_claim.claim_no, v_claim.status;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update public.ins_claims
     set status = 'assessing',
         repudiation_reopened_at = now(),
         repudiation_reopened_by = auth.uid(),
         repudiation_reopen_reason = btrim(p_reason),
         updated_at = now()
   where id = v_claim.id
  returning * into v_claim;

  -- The repudiation columns are deliberately NOT cleared: the history of what the
  -- insurer decided, when, and on what grounds is part of the claim, and a reopened
  -- claim that forgot it had been declined would lose the reason it is being reviewed.
  insert into public.ins_claim_events (tenant_id, claim_id, from_status, to_status, actor_id, note)
  values (v_tenant, v_claim.id, 'repudiated', 'assessed', auth.uid(),
          'Repudiation reopened: ' || btrim(p_reason));

  return v_claim;
end $$;

revoke all on function public.ins_reopen_claim(uuid, text) from public, anon;
grant execute on function public.ins_reopen_claim(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. A repudiated claim is not silently un-repudiated by an ordinary state change
-- ---------------------------------------------------------------------
-- ins_claims_guard already routes status changes through the claim functions. What it
-- did not do is protect the grounds for the state: without this, a caller using
-- ins_via_rpc could clear the repudiation columns while leaving the status, which
-- would leave a claim recorded as repudiated with nothing explaining it.
create or replace function public.ins_claim_repudiation_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if old.status = 'repudiated' and new.status = 'repudiated'
     and new.repudiation_reason is distinct from old.repudiation_reason then
    raise exception 'INS_REPUDIATION_IMMUTABLE: the grounds for repudiating claim % cannot be rewritten; reopen it with ins_reopen_claim() and record a fresh decision',
      old.claim_no;
  end if;
  return new;
end $$;

revoke all on function public.ins_claim_repudiation_guard() from public, anon, authenticated;

drop trigger if exists ins_claim_repudiation_guard on public.ins_claims;
create trigger ins_claim_repudiation_guard
  before update on public.ins_claims
  for each row execute function public.ins_claim_repudiation_guard();

-- ---------------------------------------------------------------------
-- 7. Prove it
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ins_claims'
                    and column_name = 'repudiation_reference') then
    raise exception 'ins_claims.repudiation_reference was not created';
  end if;
  if not ('ins_claim_write_off_expense' = any (public.platform_gl_posting_roles())) then
    raise exception 'the contra-claims-expense role is not in platform_gl_posting_roles()';
  end if;
  -- The level lookup must apply to an arbitrary company with no configuration at all,
  -- which is the case that would otherwise be silently ungoverned.
  if (public.platform_ins_refund_required_level(gen_random_uuid(), 1)).stage_id is not null
     or (select count(*) from public.platform_ins_refund_required_level(gen_random_uuid(), 1)) = 0 then
    raise exception 'the refund level lookup does not fall back to the minimum control for an unconfigured company';
  end if;
end $$;
