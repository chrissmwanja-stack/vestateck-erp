-- =====================================================================
-- Correcting and resubmitting a rejected manual journal
-- Accountant pack v2, B15; conditions C5 and C8 of AE5
-- =====================================================================
--   §1 a rejected journal can be reopened, and only from rejected
--   §2 reopen opens a NEW ROUND: no approval from the rejected round counts
--   §3 the rejected round's approvals are preserved, not deleted
--   §4 the same people may sign the corrected round
--   §5 the raiser still cannot approve, in any round
--   §6 a reopened journal is an ordinary draft: lines editable, resubmittable
--   §7 the round travels with each decision, so the audit trail is complete
--
-- §2 is the whole reason this feature is not three lines. Without it, reopening a journal that
-- was approved at level 1 and rejected at level 2 would let the corrected journal post having
-- collected only the level-2 signature -- on figures the level-1 approver never saw.
--
-- One transaction, rolled back. Disposable database only.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.expect_error(p_sql text, p_code text, p_what text)
returns void language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_code || '%' then
      v_ok := true;
    else
      raise exception 'FAIL: % should be refused as %, but was refused as: %', p_what, p_code, sqlerrm;
    end if;
  end;
  if not v_ok then
    raise exception 'FAIL: % should have been refused as % and was not refused at all', p_what, p_code;
  end if;
end $$;

do $$
declare
  ta     uuid := gen_random_uuid();
  maker  uuid := gen_random_uuid();
  fin1   uuid := gen_random_uuid();
  fin2   uuid := gen_random_uuid();
  mgr    uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  exp_gl uuid;
  rev_gl uuid;
begin
  insert into tenants(id, name) values (ta, 'Journal resubmit test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'jr-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[maker, fin1, fin2, mgr, admin1]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Resubmit actor', 'jr-' || u || '@test.local'
    from unnest(array[maker, fin1, fin2, mgr, admin1]) u;
  update app_users set is_company_admin = true where id = admin1;

  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, fin1, 'finance'), (ta, fin2, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '5000', 'Expenses', 'expense') returning id into exp_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '4100', 'Other revenue', 'revenue') returning id into rev_gl;

  -- A two-level chain, so a rejection can happen at level 2 after level 1 has approved.
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role,
                               threshold_amount, applies_to, is_active)
  values (ta, 'L1', 1, 'finance', 0, 'manual_journals', true),
         (ta, 'L2', 2, 'finance', 0, 'manual_journals', true);

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values
    ('tenant', ta), ('maker', maker), ('fin1', fin1), ('fin2', fin2),
    ('mgr', mgr), ('admin1', admin1), ('exp', exp_gl), ('rev', rev_gl);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

create function pg_temp.new_journal(p_amount numeric, p_label text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_id := (select id from public.fin_create_manual_journal(
    current_date, 'correction test ' || p_label, 'REF-' || p_label,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', p_amount),
      jsonb_build_object('gl_account_id', pg_temp.id('rev'), 'credit', p_amount))));
  reset role;
  return v_id;
end $$;

-- =====================================================================
-- §1 only a rejected journal can be reopened
-- =====================================================================
do $$
declare v_id uuid;
begin
  v_id := pg_temp.new_journal(1000, 'draft');

  -- A draft has not been rejected, so it cannot be "reopened".
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_reopen_manual_journal(%L, 'not rejected yet')$q$, v_id),
    'FIN_MANUAL_JOURNAL_STATE',
    '§1 reopening a journal that is still a draft');
  reset role;
  raise notice 'PASS: §1 reopening is only available from rejected';
end $$;

-- =====================================================================
-- §2 a reopen opens a new round and voids the old approvals' effect
-- =====================================================================
do $$
declare
  v_id uuid; v_row record; v_state record; v_round integer;
begin
  v_id := pg_temp.new_journal(1000000, 'rounds');
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  perform public.fin_submit_manual_journal(v_id);
  reset role;

  -- Level 1 approves.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'level one fine');
  reset role;

  -- Level 2 rejects.
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'reject', 'the cost centre is wrong');
  reset role;

  select approval_round into v_round from public.fin_manual_journals where id = v_id;
  perform pg_temp.assert(v_round = 1, '§2 a journal starts in round 1');

  -- Reopen.
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_row := public.fin_reopen_manual_journal(v_id, 'fixing the cost centre');
  reset role;

  perform pg_temp.assert(v_row.status = 'draft', '§2 a reopened journal must be a draft');
  perform pg_temp.assert(v_row.approval_round = 2, '§2 reopening must open round 2');

  -- THE assertion this whole feature turns on: the level-1 approval from round 1 must not be
  -- counted in round 2.
  select * into v_state from public.platform_manual_journal_chain_state(pg_temp.id('tenant'), v_id);
  perform pg_temp.assert(v_state.approved_levels = 0,
    format('§2 a reopened journal must start with no approvals counted, got %s', v_state.approved_levels));
  perform pg_temp.assert(v_state.next_level = 1,
    '§2 the corrected round must start again at level 1');
  perform pg_temp.assert(not v_state.complete, '§2 the corrected round must not be complete');
  raise notice 'PASS: §2 reopening opens a new round, and no earlier approval counts towards it';
end $$;

-- =====================================================================
-- §3 the rejected round's decisions are preserved
-- =====================================================================
do $$
declare v_id uuid; n integer;
begin
  select id into v_id from public.fin_manual_journals
   where tenant_id = pg_temp.id('tenant') and approval_round = 2 and status = 'draft'
   order by created_at limit 1;

  select count(*) into n from public.fin_manual_journal_approvals where journal_id = v_id;
  perform pg_temp.assert(n = 2,
    format('§3 both round-1 decisions must still be on record, found %s', n));

  perform pg_temp.assert(
    exists (select 1 from public.fin_manual_journal_approvals
             where journal_id = v_id and round = 1 and decision = 'approved'),
    '§3 the round-1 approval must be preserved');
  perform pg_temp.assert(
    exists (select 1 from public.fin_manual_journal_approvals
             where journal_id = v_id and round = 1 and decision = 'rejected'),
    '§3 the round-1 rejection must be preserved');
  raise notice 'PASS: §3 the rejected round''s approvals and rejection are kept, not deleted';
end $$;

-- =====================================================================
-- §4 the same people may sign the corrected round
-- =====================================================================
do $$
declare v_id uuid; v_row record; v_state record;
begin
  select id into v_id from public.fin_manual_journals
   where tenant_id = pg_temp.id('tenant') and approval_round = 2 and status = 'draft'
   order by created_at limit 1;

  -- Change the figures, which is the point of reopening.
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  update public.fin_manual_journal_lines
     set debit = 900000
   where journal_id = v_id and debit > 0;
  update public.fin_manual_journal_lines
     set credit = 900000
   where journal_id = v_id and credit > 0;
  update public.fin_manual_journals set total_debit = 900000, total_credit = 900000 where id = v_id;
  perform public.fin_submit_manual_journal(v_id);
  reset role;

  -- fin1 signed round 1 at level 1. Signing round 2 at level 1 must be allowed: it is a
  -- different decision about different figures. This is the assertion that would fail if the
  -- distinct-person rule had not been scoped to the round.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'round two level one, new figures');
  reset role;
  perform pg_temp.assert(v_row.status = 'pending_approval',
    '§4 the same approver must be able to sign the corrected round');

  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'round two level two, new figures');
  reset role;

  perform pg_temp.assert(v_row.status = 'posted',
    '§4 the corrected journal must post once both levels of the new round have signed');

  select * into v_state from public.platform_manual_journal_chain_state(pg_temp.id('tenant'), v_id);
  perform pg_temp.assert(v_state.complete, '§4 the round-2 chain must be complete');
  raise notice 'PASS: §4 a corrected round can be signed by the same people who saw the rejected one';
end $$;

-- =====================================================================
-- §5 the raiser still cannot approve, in any round
-- =====================================================================
do $$
declare v_id uuid;
begin
  v_id := pg_temp.new_journal(2000, 'maker tries');
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  perform public.fin_submit_manual_journal(v_id);
  reset role;

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'reject', 'not this one, resubmit please');
  reset role;

  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  perform public.fin_reopen_manual_journal(v_id, 'correcting and resubmitting');
  perform public.fin_submit_manual_journal(v_id);
  -- The maker is not on the finance team either, but the self-approval rule must fire first and
  -- by name, not as a generic role refusal.
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'my own journal')$q$, v_id),
    'FIN_MANUAL_JOURNAL_SELF_APPROVAL',
    '§5 the raiser approving their own journal after a reopen');
  reset role;
  raise notice 'PASS: §5 reopening does not let the raiser approve their own journal';
end $$;

-- =====================================================================
-- §6 only the raiser or an administrator may reopen
-- =====================================================================
do $$
declare v_id uuid;
begin
  v_id := pg_temp.new_journal(3000, 'someone else reopens');
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  perform public.fin_submit_manual_journal(v_id);
  reset role;

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'reject', 'rejected for the test');
  reset role;

  -- A finance user who is not the raiser and not an admin.
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_reopen_manual_journal(%L, 'let me fix it')$q$, v_id),
    'FIN_MANUAL_JOURNAL_FORBIDDEN',
    '§6 a user who did not raise the journal reopening it');
  reset role;
  raise notice 'PASS: §6 reopening is limited to the raiser or a company administrator';
end $$;

-- =====================================================================
-- §7 the round is recorded on every decision
-- =====================================================================
do $$
declare v_id uuid; n1 integer; n2 integer;
begin
  select id into v_id from public.fin_manual_journals
   where tenant_id = pg_temp.id('tenant') and status = 'posted' and approval_round = 2
   order by created_at limit 1;

  select count(*) into n1 from public.fin_manual_journal_approvals where journal_id = v_id and round = 1;
  select count(*) into n2 from public.fin_manual_journal_approvals where journal_id = v_id and round = 2;
  perform pg_temp.assert(n1 = 2, format('§7 round 1 should hold 2 decisions, found %s', n1));
  perform pg_temp.assert(n2 = 2, format('§7 round 2 should hold 2 decisions, found %s', n2));

  -- And the events trail names the round, so a reader can reconstruct the correction.
  perform pg_temp.assert(
    exists (select 1 from public.platform_audit_events
             where target_id = v_id::text and action = 'fin.manual_journal.reopened'),
    '§7 the reopen must be recorded as an event');
  raise notice 'PASS: §7 every decision carries its round and the correction is in the audit trail';
end $$;

do $$ begin
  raise notice 'ALL PASS: a rejected journal can be corrected and resubmitted, and the corrected round needs fresh signatures because no earlier approval is carried forward';
end $$;

rollback;
