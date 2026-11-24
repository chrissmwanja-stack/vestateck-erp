-- =====================================================================
-- Multi-level approval for manual journals
-- Accountant pack v2, B6; pack sections 10.2 and 11
-- =====================================================================
-- Section 11 asks for "limits by transaction type, amount, currency, role, approval level and
-- branch, with multi-level approval, escalation, effective dates and audit history".
--
-- B7 and B6 built the amount dimension: a company can say that a journal above a figure needs
-- a higher authority. What they could not do is then APPROVE it. Until this migration, a
-- journal routed to a level above 1 was refused at submission with FIN_MANUAL_JOURNAL_LEVEL,
-- because deciding it would have posted it on one signature. Refusing was the honest failure,
-- and it was still a wall: the company could configure a rule it could not use.
--
-- This builds the chain. A journal reaching level N needs an approved decision at every level
-- 1..N, by distinct people, none of them the raiser, before it posts. Each level names the
-- role that may sign it.
--
-- What this does NOT add, and says so rather than leaving it to be discovered:
--
--   * No escalation timers. A level that nobody signs sits there. Section 11 asks for
--     escalation; a timer needs a decision about what happens when it fires -- post anyway,
--     refuse, reassign -- and that is policy, not software. The daily job infrastructure
--     exists (B9) if a company asks for it.
--   * No effective dates on stages. A stage applies from the moment it is active.
--   * No branch, department or currency dimension. Amount and role only.
--   * No chain for refunds, remittances, claim payments or commission transfers. Those remain
--     single-approval at a routed level, as B7 left them. Retrofitting a chain onto refunds
--     would change behaviour for companies already using them, which is a migration with its
--     own approval, not a side effect of this one.
--
-- The behaviour change to be clear about: a company that has configured a level-2 threshold
-- but whose staff hold no role at level 2 is now stopped by a different error. Before, the
-- journal could not be submitted at all; now it can be submitted and then cannot be approved,
-- which is what a real approval queue looks like. The error names the role and the level.

-- ---------------------------------------------------------------------
-- 1. The chain
-- ---------------------------------------------------------------------
-- One row per decision. Append-only in practice: the RLS policies below refuse every write to
-- `authenticated`, so the only way in is through fin_decide_manual_journal.
create table if not exists fin_manual_journal_approvals (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  journal_id    uuid not null references fin_manual_journals(id) on delete cascade,
  level         integer not null check (level > 0),
  stage_id      uuid references workflow_stages(id),
  -- The role the stage required when this decision was made. Stored rather than joined at
  -- read time, because a stage's approver_role can be edited later and the audit trail must
  -- say what was required on the day, not what is required now.
  required_role text,
  approver_id   uuid not null references auth.users(id),
  decision      text not null check (decision in ('approved', 'rejected')),
  comment       text not null check (length(btrim(comment)) >= 3),
  decided_at    timestamptz not null default now(),
  -- One decision per person per level. Two people are still required across two levels; what
  -- this stops is the same person signing twice at one level.
  constraint fin_manual_journal_approvals_once unique (journal_id, level, approver_id)
);

create index if not exists fin_manual_journal_approvals_journal_idx
  on fin_manual_journal_approvals (tenant_id, journal_id);

comment on table fin_manual_journal_approvals is
  'One row per approval level per manual journal. A journal routed to level N needs an approved decision at every level 1..N, by distinct people, none of them the raiser, before it posts. Append-only: written only by fin_decide_manual_journal.';

alter table fin_manual_journal_approvals enable row level security;

drop policy if exists fin_manual_journal_approvals_select on fin_manual_journal_approvals;
create policy fin_manual_journal_approvals_select on fin_manual_journal_approvals
  for select to authenticated
  using (tenant_id = get_my_tenant_id());

-- Written only by the deciding function. A client that could insert here could approve its
-- own journal without any of the checks in fin_decide_manual_journal, which is the whole
-- control. Same posture as fin_manual_journals itself.
drop policy if exists fin_manual_journal_approvals_insert on fin_manual_journal_approvals;
create policy fin_manual_journal_approvals_insert on fin_manual_journal_approvals
  for insert to authenticated with check (tenant_id = public.get_my_tenant_id() and false);

drop policy if exists fin_manual_journal_approvals_update on fin_manual_journal_approvals;
create policy fin_manual_journal_approvals_update on fin_manual_journal_approvals
  for update to authenticated using (tenant_id = public.get_my_tenant_id() and false) with check (tenant_id = public.get_my_tenant_id() and false);

drop policy if exists fin_manual_journal_approvals_delete on fin_manual_journal_approvals;
create policy fin_manual_journal_approvals_delete on fin_manual_journal_approvals
  for delete to authenticated using (tenant_id = public.get_my_tenant_id() and false);

revoke all on table fin_manual_journal_approvals from anon;

-- ---------------------------------------------------------------------
-- 2. Where in the chain a journal is, and who may sign next
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
  v_req      record;
  v_next     integer;
  v_stage_id uuid;
  v_role     text;
  v_gaps     integer;
begin
  select j.total_debit into v_amount
    from public.fin_manual_journals j
   where j.id = p_journal_id and j.tenant_id = p_tenant_id;
  if not found then
    -- No such journal in this company. Return nothing rather than a zero row, so a caller
    -- cannot mistake "not yours" for "no chain needed".
    return;
  end if;

  select * into v_req
    from public.platform_approval_required_level(p_tenant_id, v_amount, 'manual_journals');

  -- No stage configured: there is no chain, and one second person is the whole requirement,
  -- which fin_decide_manual_journal already enforces. `complete = true` here means "the chain
  -- imposes nothing further", NOT "this journal is approved". The caller must not conflate them;
  -- it still has to run its own self-approval and role checks.
  if not found then
    return query select 0, 0, 0, null::uuid, null::text, true, 0;
    return;
  end if;

  -- The lowest level from 1..required_level with no approval on it.
  select min(g) into v_next
    from generate_series(1, v_req.level) g
   where g not in (select a.level
                     from public.fin_manual_journal_approvals a
                    where a.journal_id = p_journal_id
                      and a.tenant_id = p_tenant_id
                      and a.decision = 'approved');
  -- Null means every level is signed; the value is then only used for labelling.
  v_next := coalesce(v_next, v_req.level);

  -- The stage and role for THAT level. Not the stage the amount routes to: those differ
  -- whenever the journal is routed above level 1. A 100,000,000 journal in a three-level chain
  -- begins at level 1 and needs the level-1 role. Returning the top stage's role here was the
  -- first bug in this function, confirmed against a live database before this migration was
  -- written; it would have told every level-1 approver they held the wrong role.
  select s.id, s.approver_role into v_stage_id, v_role
    from public.workflow_stages s
   where s.tenant_id = p_tenant_id
     and s.applies_to = 'manual_journals'
     and s.is_active
     and s.sequence_order = v_next
   limit 1;

  -- A hole in the sequence -- stages 1 and 3 active, nothing at 2 -- would otherwise leave
  -- v_role null at level 2, and a null role is "anyone may sign". That silently turns a
  -- three-level chain into a two-level chain with a free signature in the middle. Counted here
  -- so the decider can refuse rather than let it through.
  select count(*)::integer into v_gaps
    from generate_series(1, v_req.level) g
   where not exists (select 1
                       from public.workflow_stages s
                      where s.tenant_id = p_tenant_id
                        and s.applies_to = 'manual_journals'
                        and s.is_active
                        and s.sequence_order = g);

  return query
  with done as (
    select a.level
      from public.fin_manual_journal_approvals a
     where a.journal_id = p_journal_id
       and a.tenant_id = p_tenant_id
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
  'How far through its approval chain a manual journal is: the level it routes to, how many levels are approved, which level is next, the stage id and role that level requires, whether the chain is satisfied, and how many sequence positions in 1..required_level have no active stage (gap_levels > 0 means the chain has a hole and must not be signed). complete = true with required_level = 0 means no chain applies, not that the journal is approved.';

-- ---------------------------------------------------------------------
-- 3. Does a user hold a role, in either of the two vocabularies
-- ---------------------------------------------------------------------
-- workflow_stages.approver_role is free text. The two role tables use different words:
-- finance_team_members holds finance and cost_control, staff_roles holds admin, manager and
-- member. A company that configures a stage with a role from one vocabulary must not silently
-- end up with a level nobody can sign, so the check looks in both and the caller distinguishes
-- "you are the wrong person" from "nobody holds this role".
create or replace function public.platform_user_holds_role(
  p_tenant_id uuid,
  p_user_id uuid,
  p_role text
) returns boolean
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select p_role is null
      or exists (select 1
                   from public.finance_team_members f
                  where f.tenant_id = p_tenant_id
                    and f.user_id = p_user_id
                    and f.role = p_role)
      or exists (select 1
                   from public.staff_roles s
                  where s.tenant_id = p_tenant_id
                    and s.user_id = p_user_id
                    and s.role = p_role)
$$;

revoke all on function public.platform_user_holds_role(uuid, uuid, text) from public, anon;
grant execute on function public.platform_user_holds_role(uuid, uuid, text) to authenticated;

comment on function public.platform_user_holds_role(uuid, uuid, text) is
  'Whether a user holds a workflow role on a company, checking both role vocabularies (finance_team_members: finance, cost_control; staff_roles: admin, manager, member). A null role is satisfied by anyone, which is what "no role required" means.';

-- ---------------------------------------------------------------------
-- 4. Submission opens the chain instead of refusing it
-- ---------------------------------------------------------------------
-- Re-issued from 20261124011500. The amount gate no longer refuses; it records that a chain is
-- required by leaving the journal in pending_approval. Every other rule is reproduced: the
-- raiser-or-admin submit right, the control-line recheck, the balance check, and the freeze.
create or replace function public.fin_submit_manual_journal(p_journal_id uuid)
returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.fin_manual_journals%rowtype;
  v_state  record;
begin
  select * into v_row from public.fin_manual_journals
   where id = p_journal_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: only a draft can be submitted (this one is %)', v_row.status;
  end if;
  -- The raiser, or a company administrator on their behalf. Without the admin arm a draft is
  -- stranded when the person who raised it leaves or is unavailable.
  if v_row.requested_by <> auth.uid() and not public.is_tenant_admin() then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: only the person who raised it can submit it' using errcode = '42501';
  end if;

  -- Checked again here because a line can be added after creation and before submission.
  perform public.fin_manual_journal_check_control_lines(v_row.id);

  if v_row.total_debit <> v_row.total_credit or v_row.total_debit = 0 then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %', v_row.total_debit, v_row.total_credit;
  end if;

  -- Replaces 011500's refusal. A journal the company routes above level 1 is now submittable;
  -- what it cannot do is post until every level has signed. The refusal that used to happen
  -- here was correct while the chain did not exist, and is wrong now.
  select * into v_state from public.platform_manual_journal_chain_state(v_tenant, v_row.id);
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: could not read the approval chain for this journal';
  end if;

  update public.fin_manual_journals
     set status = 'pending_approval', submitted_by = auth.uid(), submitted_at = now(),
         updated_at = now()
   where id = v_row.id
  returning * into v_row;

  -- Written in the same transaction as the status change, so the queue an approver sees and
  -- the state of the journal cannot disagree.
  if v_state.required_level > 0 then
    perform public.log_platform_event('fin.manual_journal.submitted_for_chain', v_tenant,
      'fin_manual_journal', v_row.id::text,
      format('%s submitted for %s approval level(s); level 1 requires the %s role',
             coalesce(v_row.journal_no, v_row.id::text), v_state.required_level,
             coalesce(v_state.next_role, 'finance')),
      null, to_jsonb(v_row));
  end if;

  return v_row;
end $$;

revoke all on function public.fin_submit_manual_journal(uuid) from public, anon;
grant execute on function public.fin_submit_manual_journal(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. A decision is one level, not the whole journal
-- ---------------------------------------------------------------------
-- Re-issued from 20261124011500 with three changes, each deliberate:
--
--   1. A rejection at any level rejects the journal, and the chain stops. A rejection is a
--      refusal to post, wherever in the chain it happens.
--   2. An approval records its level and returns while levels remain. It does NOT post.
--   3. Posting happens only when the last required level is approved, still inside this
--      function, still in one transaction, so there remains no window where a journal is
--      approved but unposted.
--
-- The per-user ceiling from 011500 is kept and applies to the deciding user at their level.
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

  -- A manual journal must be approved by someone other than the person who wrote it. Applies
  -- at every level: the raiser cannot be the approver at level 1 just because they are also a
  -- manager.
  if v_row.requested_by = auth.uid() then
    raise exception 'FIN_MANUAL_JOURNAL_SELF_APPROVAL: a manual journal must be approved by someone other than the person who wrote it';
  end if;

  select * into v_state from public.platform_manual_journal_chain_state(v_tenant, v_row.id);
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: could not read the approval chain for this journal';
  end if;

  -- Who may decide this journal -- approve OR reject. The authority is the same either way.
  -- Being entitled to sign a level and not entitled to refuse it would be absurd, and it would
  -- strand a journal at a level whose holder disagrees with it. Two cases, and the difference
  -- matters:
  --
  --   required_level > 0 -- the company configured a chain. The authority comes from the role
  --     the CURRENT LEVEL requires, not from the finance team. Holding the finance role is not
  --     enough to sign a level that asks for a manager, and a level asking for cost_control
  --     must be signable by cost control. The finance role is still accepted at every level,
  --     because the finance function has to be able to unblock a journal the configuration
  --     has stranded; company administration likewise.
  --
  --   required_level = 0 -- no stages configured. The single-checker rule from 011500 applies
  --     unchanged: finance role or company administration. Refusing here instead would block
  --     every manual journal for every company that has configured nothing, which is most of
  --     them, and would be a far worse regression than the one this migration is fixing.
  if v_state.required_level = 0 then
    if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
      raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: deciding a manual journal needs the finance role or company administration' using errcode = '42501';
    end if;
    v_sign_level := 1;
  else
    if v_state.complete then
      raise exception 'FIN_MANUAL_JOURNAL_STATE: every required approval is already on this journal';
    end if;

    -- A chain with a hole cannot be decided at the hole: a missing stage has no role, and "no
    -- role" means anyone, which would turn a three-level chain into a two-level one with a
    -- free signature in the middle. Refuse and name the problem. A company admin is not
    -- exempted, because this is a configuration fault rather than a matter of authority.
    if v_state.gap_levels > 0 then
      raise exception 'FIN_MANUAL_JOURNAL_CHAIN_GAP: one of levels 1..% of this journal has no active workflow stage, so that level could be signed by anyone. Add a stage at every sequence position before this journal is decided.', v_state.required_level;
    end if;

    -- Belt and braces: a level with no role in a gapless chain should be impossible, but if it
    -- happens the safe reading is "nobody configured this", not "anybody may sign".
    if v_state.next_role is null then
      raise exception 'FIN_MANUAL_JOURNAL_ROLE_UNCONFIGURED: level % of this journal has no approver_role set, so no one can be shown to be entitled to decide it. Set the stage approver_role, or have a company administrator sign it.',
        v_state.next_level;
    end if;

    if not (public.is_tenant_admin()
            or public.is_finance_team_member('finance')
            or public.platform_user_holds_role(v_tenant, auth.uid(), v_state.next_role)) then
      -- Tell the difference between "you are the wrong person" and "nobody can sign this",
      -- which is what a misconfigured role produces and what an operator needs to be told.
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

  -- A rejection ends the journal wherever in the chain it happens. Recorded at the level it was
  -- refused from, so the audit trail says which level said no.
  if p_decision = 'reject' then
    insert into public.fin_manual_journal_approvals
      (tenant_id, journal_id, level, stage_id, required_role, approver_id, decision, comment)
    values
      (v_tenant, v_row.id, v_sign_level, v_state.next_stage_id, v_state.next_role,
       auth.uid(), 'rejected', btrim(p_note));

    update public.fin_manual_journals
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(),
           decision_note = btrim(p_note), updated_at = now()
     where id = v_row.id
    returning * into v_row;

    perform public.log_platform_event('fin.manual_journal.rejected', v_tenant,
      'fin_manual_journal', v_row.id::text,
      format('rejected at level %s of %s', v_sign_level, v_state.required_level),
      null, to_jsonb(v_row));

    return v_row;
  end if;

  -- The per-user ceiling from approval_assignments, carried over from 011500 and applied to the
  -- deciding user. Null means nobody has assigned this user a maximum, which is not the same as
  -- a maximum of zero: an unassigned approver is limited by the stage alone. Applied after the
  -- chain checks so a user who may not sign at all is told that, rather than being told about a
  -- ceiling on a signature they could not have given.
  v_my_limit := public.platform_approval_user_limit(v_tenant, auth.uid(), 'manual_journals');
  if v_my_limit is not null and v_row.total_debit > v_my_limit then
    raise exception 'FIN_MANUAL_JOURNAL_LIMIT: this journal totals % % but your approval limit is %; it must be approved by someone with a higher limit',
      v_row.currency, v_row.total_debit, v_my_limit;
  end if;

  -- One signature per person per journal, not merely per level. The unique constraint
  -- (journal_id, level, approver_id) allows the same person to sign level 1 and level 2; this
  -- refuses that, because a two-level chain signed twice by one person is a single signature
  -- wearing two hats. Only checked for chains: with no chain there is one level and one row, so
  -- this can never fire, and saying so avoids an unnecessary query on the common path.
  if v_state.required_level > 0
     and exists (select 1 from public.fin_manual_journal_approvals a
                  where a.journal_id = v_row.id
                    and a.approver_id = auth.uid()
                    and a.decision = 'approved') then
    raise exception 'FIN_MANUAL_JOURNAL_DISTINCT: you have already approved this journal at an earlier level; each level needs a different person';
  end if;

  -- The same belt-and-braces checks as before: the rule was checked at submission, the check is
  -- cheap and the failure it prevents is expensive.
  perform public.fin_manual_journal_check_control_lines(v_row.id);
  if v_row.total_debit <> v_row.total_credit or v_row.total_debit = 0 then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %', v_row.total_debit, v_row.total_credit;
  end if;

  insert into public.fin_manual_journal_approvals
    (tenant_id, journal_id, level, stage_id, required_role, approver_id, decision, comment)
  values
    (v_tenant, v_row.id, v_sign_level, v_state.next_stage_id, v_state.next_role,
     auth.uid(), 'approved', btrim(coalesce(p_note, 'approved')));

  -- Re-read: the level just signed may or may not have been the last one.
  select * into v_state from public.platform_manual_journal_chain_state(v_tenant, v_row.id);
  if not v_state.complete then
    -- Not the last level. Leave the journal pending and post nothing. The caller is told which
    -- level signed and what is next, because "it worked" would be misleading: nothing posted.
    update public.fin_manual_journals
       set updated_at = now()
     where id = v_row.id
    returning * into v_row;

    perform public.log_platform_event('fin.manual_journal.level_approved', v_tenant,
      'fin_manual_journal', v_row.id::text,
      format('level %s of %s approved; next is level %s (%s)',
             v_sign_level, v_state.required_level, v_state.next_level,
             coalesce(v_state.next_role, 'finance')),
      null, to_jsonb(v_row));

    return v_row;
  end if;

  -- Every level signed. Post, exactly as the single-approval path did.
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
    format('all %s approval levels signed; journal posted', v_state.required_level),
    null, to_jsonb(v_row));

  return v_row;
end $$;

revoke all on function public.fin_decide_manual_journal(uuid, text, text) from public, anon;
grant execute on function public.fin_decide_manual_journal(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Reading the queue
-- ---------------------------------------------------------------------
-- The reviewer needs to see what is waiting on them, not only act on an id they were handed.
-- Tenant-scoped and role-aware: a row appears when the caller could actually sign it.
create or replace function public.fin_manual_journals_awaiting_me()
returns table (
  journal_id     uuid,
  journal_no     text,
  purpose        text,
  entry_date     date,
  currency       text,
  amount         numeric,
  required_level integer,
  approved_levels integer,
  next_level     integer,
  next_role      text,
  already_signed boolean
)
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null then
    return;
  end if;

  return query
  select j.id, j.journal_no, j.purpose, j.entry_date, j.currency, j.total_debit,
         s.required_level, s.approved_levels, s.next_level, s.next_role,
         exists (select 1 from public.fin_manual_journal_approvals a
                  where a.journal_id = j.id and a.approver_id = auth.uid()
                    and a.decision = 'approved')
    from public.fin_manual_journals j
    cross join lateral public.platform_manual_journal_chain_state(v_tenant, j.id) s
   where j.tenant_id = v_tenant
     and j.status = 'pending_approval'
     and s.required_level > 0
     and not s.complete
     -- A journal whose chain has a hole cannot be signed by anyone until the configuration is
     -- fixed. Showing it would be a queue entry that always fails when clicked.
     and s.gap_levels = 0
     -- Not the raiser, and nobody who has already signed a level: those two rules are what
     -- make the queue honest. A journal the caller cannot sign is not in their queue.
     and j.requested_by <> auth.uid()
     and (public.is_tenant_admin()
          or public.platform_user_holds_role(v_tenant, auth.uid(), s.next_role))
     and not exists (select 1 from public.fin_manual_journal_approvals a
                      where a.journal_id = j.id and a.approver_id = auth.uid()
                        and a.decision = 'approved')
   order by j.submitted_at nulls last, j.id;
end $$;

revoke all on function public.fin_manual_journals_awaiting_me() from public, anon;
grant execute on function public.fin_manual_journals_awaiting_me() to authenticated;

select public.apply_tenant_read_only_guard();

comment on function public.fin_manual_journals_awaiting_me() is
  'Manual journals this user could sign right now: pending, in a chain, not complete, not theirs, at a level whose role they hold (or any level for a company admin), and not already signed by them.';

-- ---------------------------------------------------------------------
-- 7. No proof block here, deliberately
-- ---------------------------------------------------------------------
-- get_my_tenant_id() is null at migration time, so a behavioural proof written here would take
-- its "no tenant" branch every time and read, in review, like a checked control. The behaviour
-- is proved in supabase/tests/test_fin_manual_journal_chain.sql, and the chain-state function
-- was additionally exercised against a live database while this migration was written.
