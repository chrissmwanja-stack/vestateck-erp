-- Functional test for the Law & Compliance workflow migrations:
--   20260921100000_law_contract_approval_flow.sql   (decisions audit,
--     submit/decide RPCs, 'rejected' status, notification wording)
--   20260921103000_law_filing_transitions.sql        (filing state machine,
--     events audit, due_date)
--
-- Covers:
--   * submit draft -> pending_approval records a 'submitted' decision row
--   * legal admin/manager approves (status -> active) and the creator is
--     notified with approval wording
--   * rejection REQUIRES notes; body of the notification carries them
--   * separation of duties: the creator can never decide their own
--     contract, even when they hold an approver role
--   * members (non-approver tier) cannot decide at all
--   * invalid transitions are refused (decide a draft; decide twice;
--     approve a pending filing directly; move an approved filing)
--   * filing transitions audit rows accumulate and filing_date auto-sets
--   * the audit tables are invisible to users outside the legal module
--
-- Run against a fresh local stack only (psql -f), never a linked project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures (as table owner, pre-impersonation)
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant      uuid := gen_random_uuid();
  v_creator     uuid := gen_random_uuid();  -- legal member
  v_approver    uuid := gen_random_uuid();  -- legal manager
  v_plain       uuid := gen_random_uuid();  -- no roles at all
begin
  insert into tenants (id, name) values (v_tenant, 'Law Flow Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values
    (v_creator,  'law-creator'),
    (v_approver, 'law-approver'),
    (v_plain,    'law-plain')
  ) as u(id, handle);

  insert into app_users (id, tenant_id, name, email)
  select u.id, v_tenant, u.name, u.email
  from (values
    (v_creator,  'Legal Member',   'law-creator@test.local'),
    (v_approver, 'Legal Manager',  'law-approver@test.local'),
    (v_plain,    'Plain User',     'law-plain@test.local')
  ) as u(id, name, email);

  insert into tenant_modules (tenant_id, module) values (v_tenant, 'legal');

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_creator,  'legal', 'member'),
    (v_tenant, v_approver, 'legal', 'manager');

  -- Contract A: draft by the legal member (to be submitted + approved)
  insert into law_contracts (tenant_id, contract_no, title, party_name, status, created_by)
  values (v_tenant, 'LAW-T-0001', 'Office lease', 'City Properties Ltd', 'draft', v_creator);

  -- Contract B: draft by the approver themselves (self-approval probe)
  insert into law_contracts (tenant_id, contract_no, title, party_name, status, created_by)
  values (v_tenant, 'LAW-T-0002', 'Counsel retainer', 'Advocates LLP', 'draft', v_approver);

  -- Filing F: pending, to walk the state machine
  insert into law_regulatory_filings (tenant_id, title, status)
  values (v_tenant, 'Annual Returns 2026', 'pending');
end $$;

set local role authenticated;

-- Helper view of fixture ids under our impersonations
-- (kept inline via subselects below; test.local emails make them stable).

-- ---------------------------------------------------------------------
-- 1. Creator (legal member) submits contract A
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from app_users where email = 'law-creator@test.local'))::text, true);

do $$
declare
  v_contract_id uuid := (select id from law_contracts where contract_no = 'LAW-T-0001');
begin
  perform submit_contract_for_approval(v_contract_id);

  if (select status from law_contracts where id = v_contract_id) <> 'pending_approval' then
    raise exception 'FAIL: submit did not move contract to pending_approval';
  end if;
  if (select count(*) from law_contract_decisions
      where contract_id = v_contract_id and decision = 'submitted') <> 1 then
    raise exception 'FAIL: no submitted decision row written';
  end if;
  raise notice 'PASS: submit_contract_for_approval -> pending_approval + submitted audit row';
end $$;

-- ---------------------------------------------------------------------
-- 2. Member tier cannot decide (needs admin/manager)
-- ---------------------------------------------------------------------
do $$
declare
  v_contract_id uuid := (select id from law_contracts where contract_no = 'LAW-T-0001');
begin
  begin
    perform decide_contract(v_contract_id, 'approved', null);
    raise exception 'FAIL: a legal member was allowed to decide a contract';
  exception
    when raise_exception then
      if sqlerrm not like '%requires a legal admin or manager%' then raise; end if;
  end;
  raise notice 'PASS: member-tier decide refused (approver tier required)';
end $$;

-- ---------------------------------------------------------------------
-- 3. Approver approves contract A -> active + creator notified
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from app_users where email = 'law-approver@test.local'))::text, true);

do $$
declare
  v_contract_id uuid := (select id from law_contracts where contract_no = 'LAW-T-0001');
  v_creator_id  uuid := (select id from app_users where email = 'law-creator@test.local');
begin
  perform decide_contract(v_contract_id, 'approved', 'Terms reviewed');

  if (select status from law_contracts where id = v_contract_id) <> 'active' then
    raise exception 'FAIL: approved contract did not become active';
  end if;
  if (select count(*) from law_contract_decisions
      where contract_id = v_contract_id and decision = 'approved' and notes = 'Terms reviewed') <> 1 then
    raise exception 'FAIL: approved decision row missing or notes lost';
  end if;
  if (select count(*) from notifications
      where recipient_id = v_creator_id and type = 'contract_active'
        and title like 'Contract approved:%') <> 1 then
    raise exception 'FAIL: creator was not notified of approval';
  end if;
  raise notice 'PASS: approve -> active, audit row with notes, creator notified';
end $$;

-- ---------------------------------------------------------------------
-- 4. Deciding an already-decided contract is refused
-- ---------------------------------------------------------------------
do $$
declare
  v_contract_id uuid := (select id from law_contracts where contract_no = 'LAW-T-0001');
begin
  begin
    perform decide_contract(v_contract_id, 'approved', null);
    raise exception 'FAIL: a decided contract could be decided a second time';
  exception
    when raise_exception then
      if sqlerrm not like '%only contracts pending approval%' then raise; end if;
  end;
  raise notice 'PASS: double decision refused';
end $$;

-- ---------------------------------------------------------------------
-- 5. Separation of duties: approver cannot decide their OWN contract.
--    Submit it as the approver first (submit tier includes them), then
--    try to decide it.
-- ---------------------------------------------------------------------
do $$
declare
  v_contract_id uuid := (select id from law_contracts where contract_no = 'LAW-T-0002');
begin
  perform submit_contract_for_approval(v_contract_id);

  begin
    perform decide_contract(v_contract_id, 'approved', null);
    raise exception 'FAIL: creator was allowed to self-approve their contract';
  exception
    when raise_exception then
      if sqlerrm not like '%cannot decide a contract you created%' then raise; end if;
  end;
  raise notice 'PASS: creator self-approval refused (separation of duties)';
end $$;

-- ---------------------------------------------------------------------
-- 6. Rejection requires notes; with notes the creator is told the reason
-- ---------------------------------------------------------------------
do $$
declare
  v_contract_id uuid := (select id from law_contracts where contract_no = 'LAW-T-0002');
  v_approver_id uuid := (select id from app_users where email = 'law-approver@test.local');
begin
  begin
    perform decide_contract(v_contract_id, 'rejected', null);
    raise exception 'FAIL: rejection without notes was accepted';
  exception
    when raise_exception then
      if sqlerrm not like '%rejection requires notes%' then raise; end if;
  end;

  -- Approver is the creator here and CANNOT reject their own contract, so
  -- have the contract "re-created" under the other user to keep testing
  -- the rejection path. Re-point created_by to the other legal user is the
  -- realistic shape (a colleague picks it up) -- but update via RLS as
  -- manager is allowed on law_contracts.
  update law_contracts set created_by = (select id from app_users where email = 'law-creator@test.local')
  where id = v_contract_id;

  perform decide_contract(v_contract_id, 'rejected', 'Missing indemnity clause');

  if (select status from law_contracts where id = v_contract_id) <> 'rejected' then
    raise exception 'FAIL: rejected contract did not become rejected';
  end if;
  if (select count(*) from law_contract_decisions
      where contract_id = v_contract_id and decision = 'rejected'
        and decided_by = v_approver_id and notes = 'Missing indemnity clause') <> 1 then
    raise exception 'FAIL: rejection audit row missing';
  end if;
  if (select count(*) from notifications
      where type = 'contract_rejected'
        and title like 'Contract rejected:%'
        and body like '%Missing indemnity clause%') <> 1 then
    raise exception 'FAIL: rejection notification missing or reason not carried';
  end if;
  raise notice 'PASS: rejection requires notes and the reason reaches the creator notification';
end $$;

-- ---------------------------------------------------------------------
-- 7. Filing state machine: invalid skips refused, valid path audited,
--    filing_date auto-set, approved is terminal.
-- ---------------------------------------------------------------------
do $$
declare
  v_filing_id uuid := (select id from law_regulatory_filings where title = 'Annual Returns 2026');
begin
  -- cannot approve straight from pending
  begin
    perform transition_filing(v_filing_id, 'approved', null);
    raise exception 'FAIL: pending -> approved was allowed';
  exception
    when raise_exception then
      if sqlerrm not like '%invalid filing transition%' then raise; end if;
  end;

  perform transition_filing(v_filing_id, 'filed', 'Filed with URSB');
  if (select status from law_regulatory_filings where id = v_filing_id) <> 'filed' then
    raise exception 'FAIL: pending -> filed did not apply';
  end if;
  if (select filing_date from law_regulatory_filings where id = v_filing_id) <> current_date then
    raise exception 'FAIL: filing_date was not auto-set on -> filed';
  end if;

  perform transition_filing(v_filing_id, 'approved', null);
  if (select status from law_regulatory_filings where id = v_filing_id) <> 'approved' then
    raise exception 'FAIL: filed -> approved did not apply';
  end if;

  if (select count(*) from law_filing_events where filing_id = v_filing_id) <> 2 then
    raise exception 'FAIL: expected exactly 2 filing event rows';
  end if;

  -- approved is terminal
  begin
    perform transition_filing(v_filing_id, 'rejected', null);
    raise exception 'FAIL: approved filing could still be transitioned';
  exception
    when raise_exception then
      if sqlerrm not like '%invalid filing transition%' then raise; end if;
  end;

  raise notice 'PASS: filing state machine enforced, events audited, filing_date auto-set';
end $$;

-- ---------------------------------------------------------------------
-- 8. Member tier cannot transition filings; outsiders see nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_filing_id uuid := (select id from law_regulatory_filings where title = 'Annual Returns 2026');
begin
  -- still impersonating the approver above; switch to the member
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from app_users where email = 'law-creator@test.local'))::text, true);

  begin
    perform transition_filing(v_filing_id, 'filed', null);
    raise exception 'FAIL: a legal member was allowed to transition a filing';
  exception
    when raise_exception then
      if sqlerrm not like '%requires a legal admin or manager%' then raise; end if;
  end;

  -- audit tables ARE readable to legal members
  if (select count(*) from law_filing_events) < 2 then
    raise exception 'FAIL: legal member cannot read filing history';
  end if;
  if (select count(*) from law_contract_decisions) < 3 then
    raise exception 'FAIL: legal member cannot read contract decision history';
  end if;

  -- plain user with no roles: nothing visible at all
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from app_users where email = 'law-plain@test.local'))::text, true);

  if (select count(*) from law_contract_decisions) > 0
  or (select count(*) from law_filing_events) > 0 then
    raise exception 'FAIL: non-legal user can read law audit tables';
  end if;
  if (select count(*) from law_contracts) > 0
  or (select count(*) from law_regulatory_filings) > 0 then
    raise exception 'FAIL: non-legal user can read law tables (select tightening regression)';
  end if;

  raise notice 'PASS: member cannot transition; legal members read audit; outsiders read nothing';

  raise notice 'ALL LAW CONTRACT APPROVAL FLOW TESTS PASSED';
end $$;

rollback;
