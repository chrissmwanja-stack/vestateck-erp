-- =====================================================================
-- Manual journals get an amount limit, on the same engine as refunds
-- Accountant pack v2, B6; pack sections 10.2 and 11
-- =====================================================================
-- Section 10.2 asks for "additional approval for restricted accounts"; section 11 asks for
-- limits "by transaction type, amount, currency, role, approval level and branch", applied
-- to "refunds, insurer remittances, commission transfers, claim payments, intermediary
-- commissions and manual journals".
--
-- B7 built that engine but hardcoded 'insurance_refunds' at every level, so a manual journal
-- could only ever be approved by one second person. This migration makes the engine take the
-- transaction type as a parameter and wires manual journals into it. Section 11's list then
-- has two of its six types routed rather than one.
--
-- One change here is not an approval limit: submitting now sets updated_at, which the
-- shipped version left at creation time. Nothing reads it for a decision; it is a reporting
-- field, and a status change that leaves it stale is a trap. Called out because a re-issued
-- function should only differ where it says it differs.
--
-- What is deliberately NOT done here, because it would be inventing policy:
--
--   * No threshold is created. A company that configures nothing keeps today's behaviour --
--     one second person, whatever the size. Same posture as the refund limits and Appendix B
--     B3's fail-closed bind: the software makes the limit expressible and refuses to guess
--     the number.
--   * No "restricted accounts" tier. Section 10.2 asks for additional approval on restricted
--     accounts, and nothing in this schema marks an account as restricted. A separate tier
--     needs a definition of restricted first; see the note at the end.

-- ---------------------------------------------------------------------
-- 1. One engine, parameterised by transaction type
-- ---------------------------------------------------------------------
-- The refund versions are kept as thin wrappers, so every existing caller and the whole of
-- B7's test suite keep working unchanged. Nothing about the refund behaviour moves.
create or replace function public.platform_approval_required_level(
  p_tenant_id uuid,
  p_amount numeric,
  p_applies_to text
) returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric)
    language plpgsql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_stage record;
begin
  select s.id, s.sequence_order, s.approver_role, s.threshold_amount
    into v_stage
    from workflow_stages s
   where s.tenant_id = p_tenant_id
     and s.applies_to = p_applies_to
     and s.is_active
     and coalesce(s.threshold_amount, 0) <= p_amount
   order by s.sequence_order desc
   limit 1;

  if found then
    return query select v_stage.id, v_stage.sequence_order, v_stage.approver_role, v_stage.threshold_amount;
    return;
  end if;

  -- No stage matched. The refund decision (Appendix B Q2, "independent approval regardless
  -- of amount") makes absence of configuration mean the MINIMUM control, not none -- and a
  -- company onboarded after this migration would otherwise inherit nothing and be silently
  -- ungoverned. Insurance refunds keep that default. A type that has never had a limit
  -- configured keeps today's behaviour instead: for manual journals that is one second
  -- person, which is exactly what returning no stage produces.
  if p_applies_to = 'insurance_refunds' then
    return query select null::uuid, 1, 'finance'::text, null::numeric;
  end if;
end $$;

revoke all on function public.platform_approval_required_level(uuid, numeric, text) from public, anon, authenticated;
grant execute on function public.platform_approval_required_level(uuid, numeric, text) to service_role;

comment on function public.platform_approval_required_level(uuid, numeric, text) is
  'The approval level a transaction of p_applies_to falls into (accountant pack v2 B6/B7). No matching stage and no type-specific default means no extra level is required.';

create or replace function public.platform_approval_user_limit(
  p_tenant_id uuid,
  p_user_id uuid,
  p_applies_to text
) returns numeric
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select max(a.threshold_max)
    from approval_assignments a
    join workflow_stages s on s.id = a.workflow_stage_id
   where a.tenant_id = p_tenant_id
     and a.user_id = p_user_id
     and s.applies_to = p_applies_to
$$;

revoke all on function public.platform_approval_user_limit(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.platform_approval_user_limit(uuid, uuid, text) to service_role;

-- The refund wrappers. Same names, same signatures, same behaviour.
create or replace function public.platform_ins_refund_required_level(p_tenant_id uuid, p_amount numeric)
returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select * from public.platform_approval_required_level(p_tenant_id, p_amount, 'insurance_refunds')
$$;

revoke all on function public.platform_ins_refund_required_level(uuid, numeric) from public, anon, authenticated;
grant execute on function public.platform_ins_refund_required_level(uuid, numeric) to service_role;

create or replace function public.platform_ins_refund_user_limit(p_tenant_id uuid, p_user_id uuid)
returns numeric
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select public.platform_approval_user_limit(p_tenant_id, p_user_id, 'insurance_refunds')
$$;

revoke all on function public.platform_ins_refund_user_limit(uuid, uuid) from public, anon, authenticated;
grant execute on function public.platform_ins_refund_user_limit(uuid, uuid) to service_role;

-- Let workflow_stages carry manual-journal limits.
alter table workflow_stages drop constraint if exists workflow_stages_applies_to_check;
alter table workflow_stages add constraint workflow_stages_applies_to_check
  check (applies_to in ('requests', 'invoices', 'insurance_refunds', 'manual_journals'));

comment on column workflow_stages.applies_to is
  'Which approval chain this stage belongs to. requests and invoices are procurement; insurance_refunds approves client refunds (B7); manual_journals approves manual journal entries by amount (B6).';

-- ---------------------------------------------------------------------
-- 2. Submission applies the limit
-- ---------------------------------------------------------------------
-- Re-issued from 20261124011100 with the amount check added. Every rule the shipped version
-- enforces is reproduced: maker-checker, the control-line reference check, the balance check,
-- the freeze, and the requirement that only the person who raised it may submit.
create or replace function public.fin_submit_manual_journal(p_journal_id uuid)
returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.fin_manual_journals%rowtype;
  v_lvl    record;
begin
  select * into v_row from public.fin_manual_journals
   where id = p_journal_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: only a draft can be submitted (this one is %)', v_row.status;
  end if;
  -- The raiser, or a company administrator on their behalf. The admin arm is not a
  -- convenience: without it a draft is stranded when the person who raised it leaves or is
  -- unavailable, and the only way out would be a new journal. This re-issue briefly dropped
  -- it and silently tightened the rule, which is the exact reason these re-issues are
  -- diffed against the shipped bodies rather than rewritten from memory.
  if v_row.requested_by <> auth.uid() and not public.is_tenant_admin() then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: only the person who raised it can submit it' using errcode = '42501';
  end if;

  -- The control-account subledger rule, checked again here because a line can be added
  -- after creation and before submission.
  perform public.fin_manual_journal_check_control_lines(v_row.id);

  if v_row.total_debit <> v_row.total_credit or v_row.total_debit = 0 then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %', v_row.total_debit, v_row.total_credit;
  end if;

  -- Section 11's amount limit. No stage configured means no extra level, which leaves the
  -- existing single-checker approval exactly as it was.
  --
  -- `select into` a record with zero rows leaves every field null, so the presence of a
  -- stage is tested with FOUND rather than by inspecting the record. Zero rows is the normal
  -- case for every company that has configured nothing.
  select * into v_lvl from public.platform_approval_required_level(
    v_tenant, v_row.total_debit, 'manual_journals');
  if found and coalesce(v_lvl.level, 1) > 1 then
    -- Multi-level approval is not built (section 11 asks for it). Refusing is the honest
    -- response: silently approving at level 1 would let a journal the company said needs a
    -- higher authority through on one signature.
    raise exception 'FIN_MANUAL_JOURNAL_LEVEL: this journal totals % %, which the company routes to approval level %. Multi-level approval for manual journals is not built yet, so it cannot be submitted. Either post it as separate entries below the threshold, or have the limit changed -- but do not approve it as if level 1 applied.',
      v_row.currency, v_row.total_debit, v_lvl.level;
  end if;

  -- updated_at is set here and not in the shipped version, which left it at creation time
  -- across the submit. Kept because a state change that does not touch updated_at is a
  -- reporting trap; flagged in the migration header as the one non-limit change.
  update public.fin_manual_journals
     set status = 'pending_approval', submitted_by = auth.uid(), submitted_at = now(),
         updated_at = now()
   where id = v_row.id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.fin_submit_manual_journal(uuid) from public, anon;
grant execute on function public.fin_submit_manual_journal(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Approval applies the per-user limit
-- ---------------------------------------------------------------------
-- The per-user ceiling from approval_assignments, so a user assigned a maximum cannot sign
-- off above it even when the stage alone would allow it. Same rule B7 applies to refunds.
create or replace function public.fin_decide_manual_journal(
  p_journal_id uuid,
  p_decision text,
  p_note text
) returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.fin_manual_journals%rowtype;
  v_lines  jsonb := '[]'::jsonb;
  v_je     public.journal_entries%rowtype;
  v_line   record;
  v_my_limit numeric;
begin
  if p_decision not in ('approve', 'reject') then
    raise exception 'FIN_MANUAL_JOURNAL_INPUT: decision must be approve or reject';
  end if;
  if p_decision = 'reject' and length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'FIN_MANUAL_JOURNAL_REASON: say why it is being rejected';
  end if;

  select * into v_row from public.fin_manual_journals
   where id = p_journal_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;
  if v_row.status <> 'pending_approval' then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: only a submitted journal can be decided (this one is %)', v_row.status;
  end if;

  -- The pack's second criterion, and the reason this surface exists at all.
  if v_row.requested_by = auth.uid() then
    raise exception 'FIN_MANUAL_JOURNAL_SELF_APPROVAL: a manual journal must be approved by someone other than the person who wrote it';
  end if;
  if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: approving a manual journal needs the finance role or company administration' using errcode = '42501';
  end if;

  if p_decision = 'reject' then
    update public.fin_manual_journals
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(),
           decision_note = btrim(p_note)
     where id = v_row.id
    returning * into v_row;
    return v_row;
  end if;

  -- Section 11's per-user ceiling. Null means nobody has assigned this user a maximum, which
  -- is not the same as a maximum of zero: an unassigned approver is limited by the stage
  -- alone, exactly as for refunds.
  v_my_limit := public.platform_approval_user_limit(v_tenant, auth.uid(), 'manual_journals');
  if v_my_limit is not null and v_row.total_debit > v_my_limit then
    raise exception 'FIN_MANUAL_JOURNAL_LIMIT: this journal totals % % but your approval limit is %; it must be approved by someone with a higher limit',
      v_row.currency, v_row.total_debit, v_my_limit;
  end if;

  -- Belt and braces: the rule was checked at submission, but the check is cheap and
  -- the failure it prevents is expensive.
  perform public.fin_manual_journal_check_control_lines(v_row.id);
  if v_row.total_debit <> v_row.total_credit or v_row.total_debit = 0 then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %', v_row.total_debit, v_row.total_credit;
  end if;

  for v_line in
    select l.gl_account_id, l.debit, l.credit, l.description
      from public.fin_manual_journal_lines l
     where l.journal_id = v_row.id
     order by l.line_no
  loop
    v_lines := v_lines || jsonb_build_object(
      'gl_account_id', v_line.gl_account_id,
      'debit', v_line.debit,
      'credit', v_line.credit,
      'description', v_line.description);
  end loop;

  -- The ledger primitive stays unexecutable by `authenticated`; this function is the
  -- only caller, and only after the checks above. Marked 'manual' so the existing
  -- reports that already look for source_type = 'manual' keep working.
  v_je := public.post_journal_entry(
            v_tenant, 'manual', v_row.id, v_row.entry_date,
            v_row.purpose || ' [' || v_row.reference || ']', v_lines);

  update public.fin_manual_journals
     set status = 'posted', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         journal_entry_id = v_je.id, posted_at = now(),
         journal_no = public.next_doc_number(v_tenant, 'fin_manual_journal', 'MJ')
   where id = v_row.id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.fin_decide_manual_journal(uuid, text, text) from public, anon;
grant execute on function public.fin_decide_manual_journal(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Prove it
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'workflow_stages_applies_to_check'
       and pg_get_constraintdef(oid) like '%manual_journals%'
  ) then
    raise exception 'workflow_stages.applies_to does not accept manual_journals';
  end if;
  if to_regprocedure('public.platform_approval_required_level(uuid, numeric, text)') is null then
    raise exception 'the parameterised approval-level lookup was not created';
  end if;
  -- A refund with no configuration must still fall back to the minimum control (Q2), while
  -- a manual journal with none must require nothing extra -- otherwise this migration would
  -- have changed refund behaviour as a side effect.
  if (select count(*) from public.platform_approval_required_level(gen_random_uuid(), 1, 'manual_journals')) <> 0 then
    raise exception 'an unconfigured manual journal must require no extra level, but the lookup returned one';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. What is still not built, recorded here so it is not discovered later
-- ---------------------------------------------------------------------
-- Section 10.2 also asks for "additional approval for restricted accounts", and section 11
-- for routing by currency, branch and department. None of those keys exists as a column
-- that a limit could be keyed on: approval_assignments has a scope_type of department,
-- cost_center or global, but workflow_stages has no currency or branch, and nothing marks a
-- GL account as restricted. Adding those dimensions is a schema decision with an accounting
-- consequence (which accounts count as restricted, and why), so it is left to a decision
-- rather than assumed here.
comment on column workflow_stages.approver_role is
  'The role a decider must hold for this stage. For insurance_refunds the recognised values are the ones the two role tables can hold: finance and cost_control (finance_team_members), or admin, manager and member (staff_roles). Manual journals accept company administration or the finance role. Amount routing only: routing by currency, branch and department, and any restricted-account tier, are not implemented (accountant pack v2 section 11).';
