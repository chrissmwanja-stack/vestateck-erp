-- =====================================================================
-- Correct and resubmit a rejected manual journal
-- Accountant pack v2, B15; conditions C5 and C8 of AE5
-- =====================================================================
-- Condition C5 of the reviewer's approval says: "A rejection must stop the chain and return the
-- journal for correction or cancellation." The chain-stopping half was already true. The
-- correction half was NOT: 'rejected' was terminal, so the only way to correct a rejected
-- journal was to raise a new one. That is safe but it is not what the condition asks for, and it
-- splits one correction across two journal records -- which is also why condition C8 could not be
-- met, since there was no resubmission for the audit trail to preserve.
--
-- This migration adds the missing transition: rejected -> draft, by the person who raised it (or
-- a company administrator), with a reason. The journal is then an ordinary draft again: the
-- lines unfreeze, it can be edited, and it is submitted through the existing path.
--
-- ---------------------------------------------------------------------
-- THE HAZARD THIS HAS TO SOLVE, BEFORE ANY OF THAT IS SAFE
-- ---------------------------------------------------------------------
-- Approvals are rows on fin_manual_journal_approvals, and nothing about them was tied to a
-- submission. Consider a journal routed to level 3 that was approved at level 1, then REJECTED
-- at level 2. Reopen it, change the lines, resubmit it -- and the level-1 approval row is still
-- sitting there. The chain counts approved levels by querying those rows, so it would report
-- level 1 as already approved ON A JOURNAL WHOSE LINES HAVE CHANGED. The resubmitted journal
-- would post with one signature instead of three, by a person who approved different figures.
--
-- That is the four-eyes failure this whole feature exists to prevent, arrived at by adding a
-- convenience. So the transition is scoped to a ROUND:
--
--   * fin_manual_journals.approval_round, starting at 1 and incremented on every reopen.
--   * fin_manual_journal_approvals.round, so each decision records which round it belongs to.
--   * the chain counts only approvals whose round equals the journal's current round;
--   * the "each level needs a different person" rule is also per round, because the people
--     who signed round 1 are entitled to sign round 2 -- it is a different decision about
--     different figures.
--
-- Nothing is deleted. Every approval from every round stays in the table, which is what makes
-- condition C8 true: submission, approval, rejection and resubmission are all preserved on the
-- same journal instead of scattered across replacement records.
--
-- ---------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
-- ---------------------------------------------------------------------
--   * It does not allow editing a journal that is pending, approved, posted or withdrawn. Only
--     'rejected' can be reopened, and only to 'draft'.
--   * It does not carry any approval forward. A resubmission needs every level signed again.
--     That is deliberate and is the point of the round.
--   * It does not let the person who raised a journal approve it, in any round. The
--     maker-checker rule is unchanged and is re-asserted in the decider.

-- ---------------------------------------------------------------------
-- 1. The round
-- ---------------------------------------------------------------------
alter table fin_manual_journals
  add column if not exists approval_round integer not null default 1;

alter table fin_manual_journals
  drop constraint if exists fin_manual_journals_round_check;
alter table fin_manual_journals
  add constraint fin_manual_journals_round_check check (approval_round >= 1);

comment on column fin_manual_journals.approval_round is
  'Which submission of this journal the current approvals belong to. Incremented when a rejected journal is reopened, so a resubmission needs fresh signatures at every level and cannot inherit an approval given for different figures.';

alter table fin_manual_journal_approvals
  add column if not exists round integer not null default 1;

-- The one-decision-per-person-per-level rule is now per round. Without this, the same person
-- could not sign level 1 again after a correction, and a two-level chain whose only two eligible
-- people had both signed round 1 could never be completed.
alter table fin_manual_journal_approvals
  drop constraint if exists fin_manual_journal_approvals_once;
alter table fin_manual_journal_approvals
  add constraint fin_manual_journal_approvals_once unique (journal_id, round, level, approver_id);

-- The chain reads approvals by journal and round on every decision, so index that pair.
create index if not exists fin_manual_journal_approvals_round_idx
  on fin_manual_journal_approvals (tenant_id, journal_id, round);

comment on column fin_manual_journal_approvals.round is
  'The submission this decision belongs to. A resubmission gets a new round, so no approval from an earlier set of figures is ever counted towards a later one. Nothing is deleted when a journal is reopened.';

-- ---------------------------------------------------------------------
-- 2. The chain counts only the current round
-- ---------------------------------------------------------------------
create or replace function public.platform_manual_journal_chain_state(
  p_tenant_id uuid,
  p_journal_id uuid
) returns table (
  required_level  integer,
  approved_levels integer,
  next_level      integer,
  next_stage_id   uuid,
  next_role       text,
  complete        boolean,
  gap_levels      integer
)
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_amount   numeric;
  v_ccy      text;
  v_round    integer;
  v_req      record;
  v_next     integer;
  v_stage_id uuid;
  v_role     text;
  v_gaps     integer;
begin
  select j.total_debit, j.currency, j.approval_round
    into v_amount, v_ccy, v_round
    from public.fin_manual_journals j
   where j.id = p_journal_id and j.tenant_id = p_tenant_id;
  if not found then
    return;
  end if;

  select * into v_req
    from public.platform_approval_required_level(p_tenant_id, v_amount, 'manual_journals', v_ccy);

  if not found then
    return query select 0, 0, 0, null::uuid, null::text, true, 0;
    return;
  end if;

  -- ONLY THIS ROUND. An approval given for the figures of round 1 says nothing about the
  -- figures of round 2, so it must not count -- see the hazard at the top of this file.
  select min(g) into v_next
    from generate_series(1, v_req.level) g
   where g not in (select a.level
                     from public.fin_manual_journal_approvals a
                    where a.journal_id = p_journal_id
                      and a.tenant_id = p_tenant_id
                      and a.round = v_round
                      and a.decision = 'approved');
  v_next := coalesce(v_next, v_req.level);

  select s.id, s.approver_role into v_stage_id, v_role
    from public.workflow_stages s
   where s.tenant_id = p_tenant_id
     and s.applies_to = 'manual_journals'
     and s.is_active
     and s.sequence_order = v_next
     and (s.currency is null
          or btrim(upper(s.currency)) = btrim(upper(v_ccy)))
   order by (s.currency is not null) desc
   limit 1;

  select count(*)::integer into v_gaps
    from generate_series(1, v_req.level) g
   where not exists (select 1
                       from public.workflow_stages s
                      where s.tenant_id = p_tenant_id
                        and s.applies_to = 'manual_journals'
                        and s.is_active
                        and s.sequence_order = g
                        and (s.currency is null
                             or btrim(upper(s.currency)) = btrim(upper(v_ccy))));

  return query
  with done as (
    select a.level
      from public.fin_manual_journal_approvals a
     where a.journal_id = p_journal_id
       and a.tenant_id = p_tenant_id
       and a.round = v_round
       and a.decision = 'approved'
     group by a.level
  )
  select v_req.level,
         (select count(*)::integer from done),
         v_next,
         v_stage_id,
         v_role,
         (select count(*) from done) >= v_req.level,
         v_gaps;
end $$;

revoke all on function public.platform_manual_journal_chain_state(uuid, uuid) from public, anon;
grant execute on function public.platform_manual_journal_chain_state(uuid, uuid) to authenticated;

comment on function public.platform_manual_journal_chain_state(uuid, uuid) is
  'How far through its approval chain a manual journal is FOR ITS CURRENT ROUND: the level it routes to given the journal''s amount and currency, how many levels are approved this round, which level is next, the stage and role that level requires, whether the chain is satisfied, and how many sequence positions have no applicable active stage. Approvals from an earlier round never count. complete = true with required_level = 0 means no chain applies, not that the journal is approved.';

-- ---------------------------------------------------------------------
-- 3. The decider records the round
-- ---------------------------------------------------------------------
-- Re-issued from 20261124011700. Every rule is reproduced. The changes are:
--   * approvals are written with round = the journal's current round;
--   * the "one signature per person per journal" rule is scoped to the round;
--   * nothing else.
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
  v_state  record;
  v_lines  jsonb := '[]'::jsonb;
  v_je     public.journal_entries%rowtype;
  v_line   record;
  v_my_limit numeric;
  v_sign_level integer;
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

  -- Unchanged, and asserted in every round: a manual journal must be approved by someone other
  -- than the person who wrote it.
  if v_row.requested_by = auth.uid() then
    raise exception 'FIN_MANUAL_JOURNAL_SELF_APPROVAL: a manual journal must be approved by someone other than the person who wrote it';
  end if;

  select * into v_state from public.platform_manual_journal_chain_state(v_tenant, v_row.id);
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: could not read the approval chain for this journal';
  end if;

  -- Who may decide this journal -- approve OR reject. The authority is the same either way:
  -- being entitled to sign a level and not entitled to refuse it would strand a journal at a
  -- level whose holder disagrees with it. Two cases:
  --
  --   required_level > 0 -- the company configured a chain. Authority comes from the role the
  --     CURRENT LEVEL requires, not from the finance team. Holding finance is not enough to
  --     sign a level that asks for a manager, and a cost_control level must be signable by
  --     cost control. Finance and company administration are accepted at every level, because
  --     otherwise a stranded configuration could never be unblocked.
  --
  --   required_level = 0 -- no stages configured, so the single-checker rule from 011500
  --     applies unchanged. Refusing here would block every manual journal for every company
  --     that has configured nothing, a far worse regression than the one being fixed.
  if v_state.required_level = 0 then
    if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
      raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: deciding a manual journal needs the finance role or company administration' using errcode = '42501';
    end if;
    v_sign_level := 1;
  else
    if v_state.complete then
      raise exception 'FIN_MANUAL_JOURNAL_STATE: every required approval is already on this journal';
    end if;

<<<<<<< ours
    -- A chain with a hole cannot be decided at the hole: a missing stage has no role, and "no
    -- role" reads as "anyone", turning a three-level chain into a two-level one with a free
    -- signature in the middle. A company admin is not exempt -- it is a configuration fault.
    if v_state.gap_levels > 0 then
      raise exception 'FIN_MANUAL_JOURNAL_CHAIN_GAP: one of levels 1..% of this journal has no active workflow stage, so that level could be signed by anyone. Add a stage at every sequence position before this journal is decided.', v_state.required_level;
    end if;
=======
  -- A chain with a hole cannot GRANT approval: a missing stage has no role, and "no role" reads
  -- as "anyone", so a free signature would appear in the middle of a three-level chain. A
  -- company admin is not exempt -- it is a configuration fault, not an authority question.
  --
  -- It is checked for an approval only. A rejection posts nothing and cannot launder a missing
  -- level, so blocking it would only trap the journal: someone who can see it is wrong would
  -- have no way to say so. Fail closed on the control, not on the complaint.
  --
  -- Placed before the null-role test because a missing stage has no role either, and
  -- 'somebody forgot level 2' is a more useful report than 'level 2 has no role'.
  --
  -- Read 'at the hole', not 'anywhere': the position about to be signed is v_state.next_level,
  -- so that is the one that must have a stage. Earlier levels exist by definition -- they
  -- have been signed -- and a later gap is caught when someone arrives at it. This test's §9
  -- case is the reason: levels 1 and 3 configured with 2 missing, a legitimate level-1
  -- signature on a correctly authorised journal, refused by an over-broad check.
  if p_decision = 'approve' and v_state.required_level > 0
     and not exists (
       select 1 from public.workflow_stages s
        where s.tenant_id = v_tenant
          and s.applies_to = 'manual_journals'
          and s.is_active
          and s.sequence_order = v_state.next_level
          and (s.currency is null
               or btrim(upper(s.currency)) = btrim(upper(v_row.currency)))
     ) then
    raise exception 'FIN_MANUAL_JOURNAL_CHAIN_GAP: level % of this journal has no active workflow stage, so that level could be signed by anyone. Add a stage at every sequence position before this journal can be approved.', v_state.next_level;
  end if;
>>>>>>> theirs

    if v_state.next_role is null then
      raise exception 'FIN_MANUAL_JOURNAL_ROLE_UNCONFIGURED: level % of this journal has no approver_role set, so no one can be shown to be entitled to decide it. Set the stage approver_role, or have a company administrator sign it.',
        v_state.next_level;
    end if;

    if not (public.is_tenant_admin()
            or public.is_finance_team_member('finance')
            or public.platform_user_holds_role(v_tenant, auth.uid(), v_state.next_role)) then
      if exists (select 1 from public.finance_team_members f
                  where f.tenant_id = v_tenant and f.role = v_state.next_role)
         or exists (select 1 from public.staff_roles s
                     where s.tenant_id = v_tenant and s.role = v_state.next_role) then
        raise exception 'FIN_MANUAL_JOURNAL_ROLE: level % of this journal needs the % role; you do not hold it',
          v_state.next_level, v_state.next_role;
      else
        raise exception 'FIN_MANUAL_JOURNAL_ROLE_UNCONFIGURED: this journal needs the % role at level %, but no user on this company holds that role. Either change the stage approver_role, or have a company administrator sign it.',
          v_state.next_role, v_state.next_level;
      end if;
    end if;

    v_sign_level := v_state.next_level;
  end if;

  -- A rejection ends THIS ROUND wherever in the chain it happens, recorded at the level that
  -- refused it.
  if p_decision = 'reject' then
    insert into public.fin_manual_journal_approvals
      (tenant_id, journal_id, round, level, stage_id, required_role, approver_id, decision, comment)
    values
      (v_tenant, v_row.id, v_row.approval_round, v_sign_level, v_state.next_stage_id,
       v_state.next_role, auth.uid(), 'rejected', btrim(p_note));

    update public.fin_manual_journals
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(),
           decision_note = btrim(p_note), rejection_reason = btrim(p_note), updated_at = now()
     where id = v_row.id
    returning * into v_row;

    perform public.log_platform_event('fin.manual_journal.rejected', v_tenant,
      'fin_manual_journal', v_row.id::text,
      format('rejected at level %s of %s in round %s',
             v_sign_level, v_state.required_level, v_row.approval_round),
      null, to_jsonb(v_row));

    return v_row;
  end if;

  v_my_limit := public.platform_approval_user_limit(v_tenant, auth.uid(), 'manual_journals');
  if v_my_limit is not null and v_row.total_debit > v_my_limit then
    raise exception 'FIN_MANUAL_JOURNAL_LIMIT: this journal totals % % but your approval limit is %; it must be approved by someone with a higher limit',
      v_row.currency, v_row.total_debit, v_my_limit;
  end if;

  -- One signature per person per round, not merely per level. The unique constraint
  -- (journal_id, round, level, approver_id) would allow the same person to sign level 1 and
  -- level 2; this refuses it, because a two-level chain signed twice by one person is a single
  -- signature wearing two hats. Scoped to the round so a corrected journal can be signed again
  -- by the people who signed the rejected one -- a different decision about different figures.
  if v_state.required_level > 0
     and exists (select 1 from public.fin_manual_journal_approvals a
                  where a.journal_id = v_row.id
                    and a.round = v_row.approval_round
                    and a.approver_id = auth.uid()
                    and a.decision = 'approved') then
    raise exception 'FIN_MANUAL_JOURNAL_DISTINCT: you have already approved this journal at an earlier level in this round; each level needs a different person';
  end if;

  perform public.fin_manual_journal_check_control_lines(v_row.id);
  if v_row.total_debit <> v_row.total_credit or v_row.total_debit = 0 then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %', v_row.total_debit, v_row.total_credit;
  end if;

  insert into public.fin_manual_journal_approvals
    (tenant_id, journal_id, round, level, stage_id, required_role, approver_id, decision, comment)
  values
    (v_tenant, v_row.id, v_row.approval_round, v_sign_level, v_state.next_stage_id,
     v_state.next_role, auth.uid(), 'approved', btrim(coalesce(p_note, 'approved')));

  select * into v_state from public.platform_manual_journal_chain_state(v_tenant, v_row.id);
  if not v_state.complete then
    update public.fin_manual_journals
       set updated_at = now()
     where id = v_row.id
    returning * into v_row;

    perform public.log_platform_event('fin.manual_journal.level_approved', v_tenant,
      'fin_manual_journal', v_row.id::text,
      format('round %s: level %s of %s approved; next is level %s (%s)',
             v_row.approval_round, v_sign_level, v_state.required_level, v_state.next_level,
             coalesce(v_state.next_role, 'finance')),
      null, to_jsonb(v_row));

    return v_row;
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

  v_je := public.post_journal_entry(
            v_tenant, 'manual', v_row.id, v_row.entry_date,
            v_row.purpose || ' [' || v_row.reference || ']', v_lines);

  update public.fin_manual_journals
     set status = 'posted', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         journal_entry_id = v_je.id, posted_at = now(),
         journal_no = public.next_doc_number(v_tenant, 'fin_manual_journal', 'MJ'),
         updated_at = now()
   where id = v_row.id
  returning * into v_row;

  perform public.log_platform_event('fin.manual_journal.posted_after_chain', v_tenant,
    'fin_manual_journal', v_row.id::text,
    format('round %s: all %s approval levels signed; journal posted',
           v_row.approval_round, v_state.required_level),
    null, to_jsonb(v_row));

  return v_row;
end $$;

revoke all on function public.fin_decide_manual_journal(uuid, text, text) from public, anon;
grant execute on function public.fin_decide_manual_journal(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Reopening a rejected journal
-- ---------------------------------------------------------------------
create or replace function public.fin_reopen_manual_journal(
  p_journal_id uuid,
  p_reason text
) returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row public.fin_manual_journals%rowtype;
begin
  select * into v_row from public.fin_manual_journals
   where id = p_journal_id and tenant_id = public.get_my_tenant_id() for update;
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;

  -- Only a rejection can be reopened. A posted journal is corrected by reversal, a withdrawn
  -- one was deliberately abandoned, and a live one is not rejected in the first place.
  if v_row.status <> 'rejected' then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: only a rejected journal can be reopened for correction (this one is %)', v_row.status;
  end if;
  if v_row.requested_by <> auth.uid() and not public.is_tenant_admin() then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: only the person who raised it can reopen it for correction' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'FIN_MANUAL_JOURNAL_REASON: say what is being corrected';
  end if;

  -- A new round. The approvals from the rejected round stay in the table, permanently, and are
  -- not counted again -- see the hazard at the top of this file.
  update public.fin_manual_journals
     set status = 'draft',
         approval_round = v_row.approval_round + 1,
         rejection_reason = btrim(p_reason),
         submitted_by = null, submitted_at = null,
         decided_by = null, decided_at = null, decision_note = null,
         updated_at = now()
   where id = v_row.id
  returning * into v_row;

  perform public.log_platform_event('fin.manual_journal.reopened', v_row.tenant_id,
    'fin_manual_journal', v_row.id::text,
    format('reopened for correction; now round %s. Reason: %s',
           v_row.approval_round, btrim(p_reason)),
    null, to_jsonb(v_row));

  return v_row;
end $$;

revoke all on function public.fin_reopen_manual_journal(uuid, text) from public, anon;
grant execute on function public.fin_reopen_manual_journal(uuid, text) to authenticated;

comment on function public.fin_reopen_manual_journal(uuid, text) is
  'Returns a rejected manual journal to draft for correction, opening a new approval round so no approval given for the rejected figures can be counted towards the corrected ones. Only the raiser or a company administrator, only from rejected, and only with a reason.';

-- ---------------------------------------------------------------------
-- 5. The table guard must permit the new transition
-- ---------------------------------------------------------------------
-- The existing guard refuses ANY update to a journal whose OLD status is posted, withdrawn or
-- rejected, which is what made rejection terminal at the table level as well as in the function.
-- Re-issued from 20261124011100: the only change is that rejected -> draft is the one permitted
-- movement out of 'rejected'. Everything else about it is reproduced.
create or replace function public.fin_manual_journal_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  new.updated_at := now();

  if tg_op = 'UPDATE' then
    -- The correction route: a rejected journal may go back to draft, and only to draft.
    if old.status = 'rejected' then
      if new.status = 'draft' then
        return new;
      end if;
      raise exception 'FIN_MANUAL_JOURNAL_IMMUTABLE: this manual journal is rejected; it can be reopened for correction but not changed directly';
    end if;

    if old.status in ('posted', 'withdrawn') then
      raise exception 'FIN_MANUAL_JOURNAL_IMMUTABLE: this manual journal is % and cannot be changed', old.status;
    end if;

    -- The figures are decided at submission and reviewed before approval. A journal whose lines
    -- change after approval is not the journal that was approved.
    if old.status = 'approved'
       and (new.total_debit is distinct from old.total_debit
            or new.total_credit is distinct from old.total_credit
            or new.entry_date is distinct from old.entry_date) then
      raise exception 'FIN_MANUAL_JOURNAL_APPROVED: this journal is approved; its amounts and date cannot change. Withdraw it and raise a new one.';
    end if;
  end if;

  return new;
end $$;

revoke all on function public.fin_manual_journal_guard() from public, anon, authenticated;

drop trigger if exists fin_manual_journal_guard on public.fin_manual_journals;
create trigger fin_manual_journal_guard
  before insert or update on public.fin_manual_journals
  for each row execute function public.fin_manual_journal_guard();
