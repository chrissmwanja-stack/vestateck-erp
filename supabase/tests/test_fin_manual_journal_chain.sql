-- =====================================================================
-- Multi-level approval for manual journals
-- Accountant pack v2, B6; pack sections 10.2 and 11
-- =====================================================================
-- What this proves, and what it does not.
--
--   §1 a company with no stages configured is unaffected: one second person approves, it posts
--   §2 a three-level chain requires three signatures, in order, before anything posts
--   §3 a journal does not leave pending_approval until the last level signs
--   §4 nothing is posted until the last level signs -- the ledger is checked, not assumed
--   §5 the raiser cannot sign any level of their own journal
--   §6 one person cannot take two levels: a two-level chain needs two people
--   §7 a level requires the role it names, and a wrong-role user is refused
--   §8 a role nobody holds is reported as unconfigured, not as "you are the wrong person"
--   §9 a gap in the stage sequence is refused rather than signed by anyone
--  §10 a rejection at any level rejects the journal and posts nothing
--  §11 the queue shows only journals the caller can actually sign
--  §12 the approvals table cannot be written around the function
--
-- This is a database-level test. It proves the controls decide correctly and that the posting
-- lands on the real ledger via post_journal_entry. It does NOT prove the UI completes the
-- workflow, and it is not user acceptance testing. Those are recorded separately in
-- docs/insurance-brokerage/signoff-register.json (AE3, AE4) and are still outstanding.
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

-- A journal reaches the decider only after a control-line check and a balance check, so the
-- fixtures use plain expense and revenue accounts with no control roles: this test is about the
-- chain, not about the subledger rule, which test_fin_manual_journals.sql already covers.
do $$
declare
  ta       uuid := gen_random_uuid();
  maker    uuid := gen_random_uuid();
  fin1     uuid := gen_random_uuid();
  fin2     uuid := gen_random_uuid();
  mgr      uuid := gen_random_uuid();
  cc       uuid := gen_random_uuid();
  admin1   uuid := gen_random_uuid();
  nobody   uuid := gen_random_uuid();
  finmaker uuid := gen_random_uuid();
  exp_gl   uuid;
  rev_gl   uuid;
begin
  insert into tenants(id, name) values (ta, 'Journal chain test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'jc-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[maker, fin1, fin2, mgr, cc, admin1, nobody, finmaker]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Chain actor', 'jc-' || u || '@test.local'
    from unnest(array[maker, fin1, fin2, mgr, cc, admin1, nobody, finmaker]) u;
  update app_users set is_company_admin = true where id = admin1;

  -- The raiser IS on the finance team, because fin_create_manual_journal refuses anyone who is
  -- not finance or a company admin -- an accountant's assistant cannot open a journal at all.
  -- This test originally made the raiser a non-finance 'maker' to model that assistant, and the
  -- very first call was refused with FIN_MANUAL_JOURNAL_FORBIDDEN: the fixture described a
  -- product that does not exist. Separation of duties here is separation of PERSON, not of
  -- team: the maker holds finance and still may not sign their own journal (§5, §6).
  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, maker, 'finance'), (ta, fin1, 'finance'), (ta, fin2, 'finance'),
           (ta, cc, 'cost_control'), (ta, finmaker, 'finance');
  -- staff_roles.module is a foreign key to platform_modules.key, and the role check allows only
  -- admin, manager and member. It CANNOT be 'finance': platform_modules.finance is registered
  -- with tenant_entitled = false, because finance is a platform-owned role surface rather than
  -- a module a tenant is entitled to, and enforce_tenant_entitled_module() refuses the write
  -- with 23514. That is a property of the product, not of this test -- every one of these rows
  -- was impossible to create, so nothing downstream of it had ever run.
  --
  -- 'insurance' is used only because it is tenant-entitled. It does not scope the role: the
  -- entitlement check that decides a manual journal calls platform_user_holds_role(), which
  -- reads staff_roles by (tenant, user, role) with no module predicate. A manager is a manager.
  insert into staff_roles(tenant_id, user_id, module, role)
    values (ta, mgr, 'insurance', 'manager');

  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '5000', 'Expenses', 'expense') returning id into exp_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '4100', 'Other revenue', 'revenue') returning id into rev_gl;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values
    ('tenant', ta), ('maker', maker), ('fin1', fin1), ('fin2', fin2),
    ('mgr', mgr), ('cc', cc), ('admin1', admin1), ('nobody', nobody),
    ('finmaker', finmaker),
    ('exp', exp_gl), ('rev', rev_gl);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- A journal of a chosen size, raised by the maker, with one debit and one credit line. Returns
-- the journal id.
create function pg_temp.new_journal(p_amount numeric, p_label text, p_raiser text default 'maker')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform pg_temp.jwt(pg_temp.id(p_raiser));
  set local role authenticated;
  v_id := (select id from public.fin_create_manual_journal(
    current_date, p_label, 'REF-' || p_label,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', p_amount),
      jsonb_build_object('gl_account_id', pg_temp.id('rev'), 'credit', p_amount))));
  reset role;
  return v_id;
end $$;

create function pg_temp.submit(p_id uuid, p_raiser text default 'maker')
returns void language plpgsql as $$
begin
  perform pg_temp.jwt(pg_temp.id(p_raiser));
  set local role authenticated;
  perform public.fin_submit_manual_journal(p_id);
  reset role;
end $$;

-- Which stage positions are configured for manual journals.
create function pg_temp.add_stage(p_seq integer, p_role text, p_threshold numeric)
returns void language sql as $$
  insert into public.workflow_stages(tenant_id, name, sequence_order, approver_role,
                                     threshold_amount, applies_to, is_active)
  values (pg_temp.id('tenant'), 'Chain L' || p_seq, p_seq, p_role, p_threshold,
          'manual_journals', true);
$$;

-- =====================================================================
-- §1 no stages configured: behaviour is exactly what it was before this migration
-- =====================================================================
do $$
declare v_id uuid; v_row record;
begin
  v_id := pg_temp.new_journal(1000, 'unconfigured');
  perform pg_temp.submit(v_id);

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'checked to the invoice');
  reset role;

  perform pg_temp.assert(v_row.status = 'posted',
    '§1 with no stages configured, one finance approval must still post, exactly as before this migration');
  perform pg_temp.assert(v_row.journal_entry_id is not null,
    '§1 the posting must have landed on a real journal entry');
  perform pg_temp.assert((select count(*) from public.fin_manual_journal_approvals where journal_id = v_id) = 1,
    '§1 a single-approval journal records exactly one approval row');
  raise notice 'PASS: §1 a company with no stages configured keeps single-checker approval';
end $$;

-- =====================================================================
-- §1b the ordinary case: a finance user raises, a different finance user approves
-- =====================================================================
-- This is what actually happens in a company with no approval chain configured -- the finance
-- user who keeps the books writes the journal and a colleague approves it. It must be allowed:
-- the raiser being entitled to raise does not disqualify them from the cycle, only from
-- approving their own journal.
do $$
declare v_id uuid; v_row record;
begin
  v_id := pg_temp.new_journal(1000, 'finance raiser', 'finmaker');
  perform pg_temp.submit(v_id, 'finmaker');

  -- The raiser cannot approve it.
  perform pg_temp.jwt(pg_temp.id('finmaker'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'my own')$q$, v_id),
    'FIN_MANUAL_JOURNAL_SELF_APPROVAL',
    '§1b a finance user approving the journal they raised');
  reset role;

  -- A different finance user can.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'colleague checked it');
  reset role;
  perform pg_temp.assert(v_row.status = 'posted',
    '§1b a second finance user must be able to approve a journal raised by finance');
  raise notice 'PASS: §1b a finance user can raise a journal that another finance user approves';
end $$;

-- =====================================================================
-- §2 three signatures in order, before anything posts
-- =====================================================================
-- Levels 1, 2 and 3, all with a zero threshold, so a 1,000,000 journal routes to level 3.
do $$
declare v_id uuid; v_row record; v_state record;
begin
  perform pg_temp.add_stage(1, 'finance', 0);
  perform pg_temp.add_stage(2, 'cost_control', 0);
  perform pg_temp.add_stage(3, 'manager', 0);

  v_id := pg_temp.new_journal(1000000, 'three level');
  perform pg_temp.submit(v_id);

  select * into v_state from public.platform_manual_journal_chain_state(pg_temp.id('tenant'), v_id);
  perform pg_temp.assert(v_state.required_level = 3, '§2 a 1,000,000 journal must route to level 3');
  perform pg_temp.assert(v_state.next_level = 1, '§2 the chain starts at level 1');
  perform pg_temp.assert(v_state.next_role = 'finance', '§2 level 1 asks for finance');
  perform pg_temp.assert(not v_state.complete, '§2 the chain is not complete before anyone signs');

  -- level 1: finance
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'level one checked');
  reset role;
  perform pg_temp.assert(v_row.status = 'pending_approval',
    '§2 after one of three levels the journal must still be pending_approval, not posted');
  perform pg_temp.assert(v_row.journal_entry_id is null,
    '§2 one approval of three must not have produced a journal entry');

  select * into v_state from public.platform_manual_journal_chain_state(pg_temp.id('tenant'), v_id);
  perform pg_temp.assert(v_state.approved_levels = 1 and v_state.next_level = 2,
    '§2 after level 1 the next level is 2');
  perform pg_temp.assert(v_state.next_role = 'cost_control', '§2 level 2 asks for cost_control');

  -- level 2: cost control
  perform pg_temp.jwt(pg_temp.id('cc'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'level two checked');
  reset role;
  perform pg_temp.assert(v_row.status = 'pending_approval',
    '§2 after two of three levels the journal must still be pending_approval');
  perform pg_temp.assert(v_row.journal_entry_id is null,
    '§2 two approvals of three must not have produced a journal entry');

  -- level 3: manager
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'level three checked');
  reset role;
  perform pg_temp.assert(v_row.status = 'posted',
    '§2 the third and last level must post the journal');
  perform pg_temp.assert(v_row.journal_entry_id is not null,
    '§2 the completed chain must produce a journal entry');

  perform pg_temp.assert((select count(*) from public.fin_manual_journal_approvals where journal_id = v_id) = 3,
    '§2 three levels means three recorded approvals');
  perform pg_temp.assert(
    (select array_agg(level order by level) from public.fin_manual_journal_approvals where journal_id = v_id) = array[1,2,3],
    '§2 the approvals must be recorded at levels 1, 2 and 3');
  raise notice 'PASS: §2 a three-level chain takes three signatures, in order, and posts on the third';
end $$;

-- =====================================================================
-- §3/§4 the ledger is untouched until the last signature
-- =====================================================================
do $$
declare v_id uuid; v_entries integer; v_state record;
begin
  v_id := pg_temp.new_journal(1000000, 'ledger quiet');
  perform pg_temp.submit(v_id);

  perform pg_temp.assert(
    (select count(*) from public.journal_entries where source_id = v_id and source_type = 'manual') = 0,
    '§4 nothing must be posted while the journal is awaiting approval');

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'first level');
  reset role;

  perform pg_temp.assert(
    (select count(*) from public.journal_entries where source_id = v_id and source_type = 'manual') = 0,
    '§4 one approval of three must leave the ledger untouched');

  perform pg_temp.jwt(pg_temp.id('cc'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'second level');
  reset role;

  perform pg_temp.assert(
    (select count(*) from public.journal_entries where source_id = v_id and source_type = 'manual') = 0,
    '§4 two approvals of three must leave the ledger untouched');

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'third level');
  reset role;

  -- Exactly one, and it balances. A double post here would be the worst outcome in the pack.
  select count(*) into v_entries from public.journal_entries where source_id = v_id and source_type = 'manual';
  perform pg_temp.assert(v_entries = 1, '§4 the completed chain must post exactly one journal entry, found ' || v_entries);
  perform pg_temp.assert(
    (select sum(debit) = sum(credit) and sum(debit) = 1000000 from public.journal_entry_lines
      where journal_entry_id = (select id from public.journal_entries where source_id = v_id and source_type = 'manual')),
    '§4 the posted entry must balance at the journal total');
  raise notice 'PASS: §4 the ledger stays untouched until the last level signs, then receives one balanced entry';
end $$;

-- =====================================================================
-- §5 the raiser cannot sign any level of their own journal
-- =====================================================================
do $$
declare v_id uuid;
begin
  -- The maker is not on the finance team, but a company admin who raises a journal must still
  -- not be able to approve it. Use the admin as raiser.
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  v_id := (select id from public.fin_create_manual_journal(
    current_date, 'admin raised', 'REF-admin',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 1000000),
      jsonb_build_object('gl_account_id', pg_temp.id('rev'), 'credit', 1000000))));
  perform public.fin_submit_manual_journal(v_id);
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'my own journal')$q$, v_id),
    'FIN_MANUAL_JOURNAL_SELF_APPROVAL',
    '§5 a company administrator approving the journal they raised themselves');
  reset role;
  raise notice 'PASS: §5 the person who raised a journal cannot approve it, even as a company admin';
end $$;

-- =====================================================================
-- §6 one person cannot take two levels
-- =====================================================================
do $$
declare v_id uuid;
begin
  v_id := pg_temp.new_journal(1000000, 'same person twice');
  perform pg_temp.submit(v_id);

  -- fin1 signs level 1.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'level one');
  -- fin1 also holds no cost_control role, but the finance role is accepted at every level, so
  -- without the distinct-person rule the same person could sign level 2 as well.
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'level two as well')$q$, v_id),
    'FIN_MANUAL_JOURNAL_DISTINCT',
    '§6 the same person signing a second level of the same journal');
  reset role;
  raise notice 'PASS: §6 a two-level chain cannot be satisfied by one person signing twice';
end $$;

-- =====================================================================
-- §7 a level requires the role it names
-- =====================================================================
do $$
declare v_id uuid;
begin
  v_id := pg_temp.new_journal(1000000, 'wrong role');
  perform pg_temp.submit(v_id);

  -- fin2 holds finance and may sign level 1.
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'level one');
  reset role;

  -- nobody holds no workflow role at all and is not on the finance team: refused at level 2.
  perform pg_temp.jwt(pg_temp.id('nobody'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'trying it on')$q$, v_id),
    'FIN_MANUAL_JOURNAL_ROLE',
    '§7 a user holding neither the level role nor finance');
  reset role;
  raise notice 'PASS: §7 a level refuses a user who does not hold the role that level names';
end $$;

-- =====================================================================
-- §7b company administration is accepted at a level that names another role
-- =====================================================================
-- The documented way out of a configuration that names a role nobody holds is a company
-- administrator. That must work at a level asking for something else, or the escape hatch
-- closes exactly when it is needed.
do $$
declare v_id uuid;
begin
  update public.workflow_stages set is_active = false where tenant_id = pg_temp.id('tenant');
  perform pg_temp.add_stage(1, 'finance', 0);
  perform pg_temp.add_stage(2, 'manager', 0);

  v_id := pg_temp.new_journal(1000000, 'admin at manager level');
  perform pg_temp.submit(v_id);

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'level one');
  reset role;

  -- admin1 is a company administrator and holds neither manager nor finance.
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'admin signs level two');
  reset role;

  perform pg_temp.assert(
    (select status from public.fin_manual_journals where id = v_id) = 'posted',
    '§7b a company administrator must be able to sign a level that names the manager role');
  raise notice 'PASS: §7b a company administrator can sign any level, which is the way out of a stranded configuration';
end $$;

-- =====================================================================
-- §8 a role nobody holds is reported as unconfigured
-- =====================================================================
do $$
declare v_id uuid; tb uuid := pg_temp.id('tenant');
begin
  -- A fresh company state: retire the configured stages so the sequence has a single level
  -- whose role no user on this company holds.
  update public.workflow_stages set is_active = false where tenant_id = tb;
  perform pg_temp.add_stage(1, 'treasury', 0);

  v_id := pg_temp.new_journal(5000, 'unconfigured role');
  perform pg_temp.submit(v_id);

  perform pg_temp.jwt(pg_temp.id('nobody'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'no such role')$q$, v_id),
    'FIN_MANUAL_JOURNAL_ROLE_UNCONFIGURED',
    '§8 a chain level whose role no user on the company holds');
  reset role;

  -- A company administrator can still sign it, which is the documented way out of a
  -- configuration that names a role nobody holds.
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'admin unblocks');
  reset role;
  perform pg_temp.assert(
    (select status from public.fin_manual_journals where id = v_id) = 'posted',
    '§8 a company administrator must be able to sign a level whose role nobody holds');
  raise notice 'PASS: §8 an unheld role is reported as unconfigured, and a company admin can unblock it';
end $$;

-- =====================================================================
-- §9 a gap in the chain is refused, not signed by anyone
-- =====================================================================
do $$
declare v_id uuid; tb uuid := pg_temp.id('tenant'); v_state record;
begin
  update public.workflow_stages set is_active = false where tenant_id = tb;
  perform pg_temp.add_stage(1, 'finance', 0);
  -- level 2 deliberately absent
  perform pg_temp.add_stage(3, 'manager', 0);

  v_id := pg_temp.new_journal(1000000, 'gap in chain');
  perform pg_temp.submit(v_id);

  select * into v_state from public.platform_manual_journal_chain_state(tb, v_id);
  perform pg_temp.assert(v_state.required_level = 3, '§9 the journal still routes to level 3');
  perform pg_temp.assert(v_state.gap_levels = 1, '§9 the missing level 2 must be counted as one gap');

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'level one');
  reset role;

  -- At level 2 there is no stage, hence no role. Without the gap check this signature would be
  -- allowed for anyone at all, silently making a three-level chain into a two-level one.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'signing the hole')$q$, v_id),
    'FIN_MANUAL_JOURNAL_CHAIN_GAP',
    '§9 signing a chain position that has no configured stage');
  reset role;
  raise notice 'PASS: §9 a missing stage is refused rather than becoming a level anyone may sign';
end $$;

-- =====================================================================
-- §10 a rejection at any level rejects and posts nothing
-- =====================================================================
do $$
declare v_id uuid; v_row record;
begin
  update public.workflow_stages set is_active = false where tenant_id = pg_temp.id('tenant');
  perform pg_temp.add_stage(1, 'finance', 0);
  perform pg_temp.add_stage(2, 'cost_control', 0);

  v_id := pg_temp.new_journal(1000000, 'rejected at level 2');
  perform pg_temp.submit(v_id);

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'level one fine');
  reset role;

  perform pg_temp.jwt(pg_temp.id('cc'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'reject', 'wrong cost centre on this one');
  reset role;

  perform pg_temp.assert(v_row.status = 'rejected',
    '§10 a rejection at level 2 must reject the journal, not leave it pending');
  perform pg_temp.assert(v_row.journal_entry_id is null, '§10 a rejected journal must not be posted');
  perform pg_temp.assert(
    (select count(*) from public.journal_entries where source_id = v_id and source_type = 'manual') = 0,
    '§10 a rejected journal must leave the ledger untouched');

  -- And it cannot then be approved: it is out of the queue.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'reversing the rejection')$q$, v_id),
    'FIN_MANUAL_JOURNAL_STATE',
    '§10 approving a journal that has already been rejected');
  reset role;
  raise notice 'PASS: §10 a rejection at any level rejects the journal, posts nothing, and closes it';
end $$;

-- =====================================================================
-- §11 the queue shows only what the caller can sign
-- =====================================================================
do $$
declare v_id uuid; tb uuid := pg_temp.id('tenant'); v_n integer;
begin
  update public.workflow_stages set is_active = false where tenant_id = tb;
  perform pg_temp.add_stage(1, 'finance', 0);
  perform pg_temp.add_stage(2, 'manager', 0);

  -- 'queue' was a two-word purpose and fin_manual_journals_purpose_check requires at least ten
  -- characters. That constraint is older than this pack, so the sentence has to be a sentence.
  v_id := pg_temp.new_journal(1000000, 'queue routing check');
  perform pg_temp.submit(v_id);

  -- Level 1 is finance: fin2 sees it, the maker does not (it is theirs), a random
  -- non-holder does not.
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  select count(*) into v_n from public.fin_manual_journals_awaiting_me() q where q.journal_id = v_id;
  perform pg_temp.assert(v_n = 1, '§11 a finance user must see a level-1 finance journal in their queue');
  reset role;

  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  select count(*) into v_n from public.fin_manual_journals_awaiting_me() q where q.journal_id = v_id;
  perform pg_temp.assert(v_n = 0, '§11 the raiser must not see their own journal in the approval queue');
  reset role;

  -- The manager holds the level-2 role but the journal is at level 1, so it is not yet theirs.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  select count(*) into v_n from public.fin_manual_journals_awaiting_me() q where q.journal_id = v_id;
  perform pg_temp.assert(v_n = 0, '§11 a user must not see a journal whose current level is not theirs');
  reset role;

  -- fin2 signs level 1; the manager's queue now holds it and fin2's does not.
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'approve', 'level one');
  select count(*) into v_n from public.fin_manual_journals_awaiting_me() q where q.journal_id = v_id;
  perform pg_temp.assert(v_n = 0, '§11 a journal you have already signed must leave your queue');
  reset role;

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  select count(*) into v_n from public.fin_manual_journals_awaiting_me() q where q.journal_id = v_id;
  perform pg_temp.assert(v_n = 1, '§11 the journal must move into the next level''s queue');
  reset role;
  raise notice 'PASS: §11 the queue shows a journal only to someone who can sign it now';
end $$;

-- =====================================================================
-- §12 the approvals table cannot be written around the function
-- =====================================================================
do $$
declare v_id uuid;
begin
  v_id := pg_temp.new_journal(1000000, 'direct write');
  perform pg_temp.submit(v_id);

  perform pg_temp.jwt(pg_temp.id('nobody'));
  set local role authenticated;
  -- An approval row written directly would satisfy the chain without any of the checks.
  begin
    insert into public.fin_manual_journal_approvals
      (tenant_id, journal_id, level, approver_id, decision, comment)
    values (pg_temp.id('tenant'), v_id, 1, pg_temp.id('nobody'), 'approved', 'walked straight in');
    raise exception 'FAIL: §12 a direct insert into fin_manual_journal_approvals was allowed';
  exception
    when insufficient_privilege or check_violation then null;
  end;
  reset role;

  perform pg_temp.assert(
    (select count(*) from public.fin_manual_journal_approvals where journal_id = v_id) = 0,
    '§12 no approval row may appear except through fin_decide_manual_journal');
  raise notice 'PASS: §12 the approvals table is not writable by an ordinary authenticated user';
end $$;

do $$ begin
  raise notice 'ALL PASS: multi-level approval routes a journal through every configured level, in order, by distinct entitled people, posts nothing until the last signature, and refuses gaps, wrong roles and self-approval';
end $$;

rollback;
