-- Intermediary register, slice 1 (20261017140000_ins_intermediaries.sql).
-- Run inside a transaction that is rolled back, so it leaves no data behind.
-- Any RAISE EXCEPTION is a real assertion failure and makes psql exit non-zero.

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_needle in sqlerrm) > 0 then
      return;
    end if;
    raise exception 'FAIL: % raised "%", expected "%"', p_label, sqlerrm, p_needle;
  end;
  raise exception 'FAIL: % succeeded but should have failed with "%"', p_label, p_needle;
end $$;

create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      return;
    end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
end $$;

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

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  mgr  uuid := gen_random_uuid();   -- tenant A manager, registers records
  appr uuid := gen_random_uuid();   -- tenant A manager, verifies them
  mem  uuid := gen_random_uuid();   -- tenant A member (read only)
  mgr_b uuid := gen_random_uuid();  -- tenant B manager
  v_broker uuid; v_agent uuid; v_sub uuid; v_ref uuid; v_parent_sub uuid; v_n integer; r ins_intermediaries%rowtype;
  v_status text;
begin
  insert into tenants (id, name) values (ta, 'Intermediaries A'), (tb, 'Intermediaries B');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'interm-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{}', '{}', now(), now(), '', ''
    from (values (mgr), (appr), (mem), (mgr_b)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,   ta, 'Interm manager',  'interm-' || mgr   || '@test.local'),
    (appr,  ta, 'Interm approver', 'interm-' || appr  || '@test.local'),
    (mem,   ta, 'Interm member',   'interm-' || mem   || '@test.local'),
    (mgr_b, tb, 'Interm manager B', 'interm-' || mgr_b || '@test.local');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (ta, mgr, 'insurance', 'manager'), (ta, appr, 'insurance', 'manager'),
    (ta, mem, 'insurance', 'member'), (tb, mgr_b, 'insurance', 'manager');

  -------------------------------------------------------------------
  -- 1. Who may maintain the register
  -------------------------------------------------------------------
  perform pg_temp.jwt(mem);
  set local role authenticated;
  perform pg_temp.expect_error(
    $q$select ins_save_intermediary(null, 'IB-M', 'business', 'Member tries', 'independent_broker', null, null, null,
       'LIC-M', 'IRA', current_date - 30, current_date + 365)$q$,
    'INS_FORBIDDEN', 'a member registering an intermediary');
  reset role;

  -------------------------------------------------------------------
  -- 2. Credentials by category
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    $q$select ins_save_intermediary(null, 'IB-1', 'business', 'No licence', 'independent_broker', null, null, null,
       null, null, null, null)$q$,
    'INS_REQUIRED', 'a broker with no licence');
  perform pg_temp.expect_error(
    $q$select ins_save_intermediary(null, 'IB-2', 'business', 'Old licence', 'independent_broker', null, null, null,
       'LIC-2', 'IRA', current_date - 400, current_date - 1)$q$,
    'INS_LICENCE_EXPIRED', 'a broker whose licence has expired');
  perform pg_temp.expect_error(
    $q$select ins_save_intermediary(null, 'AG-1', 'business', 'Agent no appointment', 'insurer_appointed_agent', null, null, null,
       'LIC-A1', 'IRA', current_date - 30, current_date + 365, null)$q$,
    'INS_REQUIRED', 'an insurer-appointed agent with no appointment reference');
  -- A referral partner needs no licence.
  r := ins_save_intermediary(null, 'REF-1', 'individual', 'Referral person', 'referral_partner');
  perform pg_temp.assert(r.status = 'pending_verification' and r.licence_ref is null, 'a referral partner is saved without a licence');
  raise notice 'PASS: a member cannot register; licence and appointment rules hold; a referral partner needs no licence';

  -- A valid broker, and an insurer-appointed agent with both a licence and an appointment.
  v_broker := (ins_save_intermediary(null, 'IB-100', 'business', 'Alpha Brokers', 'independent_broker', 'a@alpha.test', '0700', null,
     'LIC-100', 'IRA', current_date - 30, current_date + 365, null)).id;
  v_agent := (ins_save_intermediary(null, 'AG-100', 'individual', 'Jane Agent', 'insurer_appointed_agent', null, null, null,
     'LIC-200', 'IRA', current_date - 30, current_date + 365, 'APPT-200')).id;

  -------------------------------------------------------------------
  -- 3. Verification: a different manager, and not while the licence is expired
  -------------------------------------------------------------------
  perform pg_temp.expect_error(format('select ins_verify_intermediary(%L)', v_broker),
    'INS_SEGREGATION', 'the person who registered a broker verifying it');
  reset role;
  perform pg_temp.jwt(appr);
  set local role authenticated;
  r := ins_verify_intermediary(v_broker, 'Licence checked on the register');
  perform pg_temp.assert(r.status = 'active' and r.verified_by = appr, 'a second manager verifies the broker');
  perform pg_temp.expect_error(format('select ins_verify_intermediary(%L)', v_broker),
    'INS_STATE', 'verifying an active intermediary again');
  reset role;
  raise notice 'PASS: verification needs a different manager and a pending record';

  -------------------------------------------------------------------
  -- 4. Sub-agents: parent must be active, not a referral partner, and the link must be evidenced
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    $q$select ins_save_intermediary(null, 'SA-0', 'individual', 'No parent', 'sub_agent', null, null, null,
       'LIC-S0', 'IRA', current_date - 30, current_date + 365)$q$,
    'INS_PARENT_REQUIRED', 'a sub-agent with no parent');
  -- v_agent is still pending verification here, so it is not an active parent.
  perform pg_temp.expect_error(
    format($q$select ins_save_intermediary(null, 'SA-1', 'individual', 'Parent not active', 'sub_agent', null, null, %L,
       'LIC-S1', 'IRA', current_date - 30, current_date + 365, null, 'Written appointment', 'AUTH-1')$q$, v_agent),
    'INS_PARENT_NOT_ACTIVE', 'linking under a parent that is not active');
  reset role;

  -- An active parent that is a referral partner cannot appoint anyone.
  v_ref := (ins_save_intermediary(null, 'REF-2', 'business', 'Referral firm', 'referral_partner')).id;
  perform pg_temp.jwt(appr);
  set local role authenticated;
  perform ins_verify_intermediary(v_ref);
  reset role;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select ins_save_intermediary(null, 'SA-2', 'individual', 'Under referral', 'sub_agent', null, null, %L,
       'LIC-S2', 'IRA', current_date - 30, current_date + 365, null, 'Written appointment', 'AUTH-2')$q$, v_ref),
    'INS_PARENT_CATEGORY', 'a referral partner used as a parent');
  perform pg_temp.expect_error(
    format($q$select ins_save_intermediary(null, 'SA-3', 'individual', 'No basis', 'sub_agent', null, null, %L,
       'LIC-S3', 'IRA', current_date - 30, current_date + 365, null, null, null)$q$, v_broker),
    'INS_AUTHORISATION_REQUIRED', 'a sub-agent with no authorisation evidence');

  v_sub := (ins_save_intermediary(null, 'SA-100', 'individual', 'Sam Sub', 'sub_agent', null, null, v_broker,
     'LIC-S100', 'IRA', current_date - 30, current_date + 365, null, 'Written appointment by Alpha Brokers', 'AUTH-100')).id;
  reset role;
  perform pg_temp.jwt(appr);
  set local role authenticated;
  r := ins_verify_intermediary(v_sub);
  perform pg_temp.assert(r.status = 'active' and r.parent_id = v_broker, 'a sub-agent with a verified parent verifies');
  reset role;
  raise notice 'PASS: sub-agents need an active parent, a non-referral parent and recorded authorisation';

  -------------------------------------------------------------------
  -- 5. Loops are refused
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select ins_save_intermediary(%L, 'IB-100', 'business', 'Alpha Brokers', 'independent_broker', null, null, %L,
       'LIC-100', 'IRA', current_date - 30, current_date + 365, null)$q$, v_broker, v_sub),
    'INS_CYCLE', 'making a broker the child of its own sub-agent');
  reset role;

  -------------------------------------------------------------------
  -- 6. A change to credentials sends the record back for verification; its own editor cannot verify it
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  r := ins_save_intermediary(v_broker, 'IB-100', 'business', 'Alpha Brokers Ltd', 'independent_broker', 'a@alpha.test', '0700', null,
     'LIC-100-R', 'IRA', current_date - 10, current_date + 365, null);
  perform pg_temp.assert(r.status = 'pending_verification' and r.verified_by is null,
                         'changing a licence reference sends the broker back for verification');
  perform pg_temp.expect_error(format('select ins_verify_intermediary(%L)', v_broker),
    'INS_SEGREGATION', 'the manager who changed the licence verifying the change');
  reset role;
  perform pg_temp.assert(exists (select 1 from ins_intermediary_events
                                  where intermediary_id = v_broker and action = 'changed'
                                    and to_status = 'pending_verification'),
                         'the change is recorded in the history');
  -- The second manager verifies the change.
  perform pg_temp.jwt(appr);
  set local role authenticated;
  r := ins_verify_intermediary(v_broker, 'Revised licence checked');
  perform pg_temp.assert(r.status = 'active', 'the second manager re-verifies the changed broker');
  reset role;

  -- A details-only edit (name, no credential change) keeps the status.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  r := ins_save_intermediary(v_broker, 'IB-100', 'business', 'Alpha Brokers Limited', 'independent_broker', 'a@alpha.test', '0700', null,
     'LIC-100-R', 'IRA', current_date - 10, current_date + 365, null);
  perform pg_temp.assert(r.status = 'active', 'a name-only edit does not send the broker back for verification');
  reset role;
  raise notice 'PASS: credential changes need re-verification by someone other than the editor; details-only edits do not';

  -------------------------------------------------------------------
  -- 7. Status moves
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  -- A pending agent cannot be activated by hand; verification is required.
  perform pg_temp.expect_error(format('select ins_set_intermediary_status(%L, ''active'', null)', v_agent),
    'INS_STATE', 'activating a pending agent by hand (verification is required)');
  reset role;
  perform pg_temp.jwt(appr);
  set local role authenticated;
  perform ins_verify_intermediary(v_agent, 'Appointment checked');
  reset role;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_set_intermediary_status(%L, ''suspended'', null)', v_agent),
    'INS_NOTE_REQUIRED', 'suspending with no reason');
  perform pg_temp.expect_error(format('select ins_set_intermediary_status(%L, ''expired'', null)', v_agent),
    'INS_NOT_EXPIRED', 'expiring a licence that has not expired');
  -- A suspension is allowed and reversible.
  r := ins_set_intermediary_status(v_agent, 'suspended', 'Complaint under review');
  perform pg_temp.assert(r.status = 'suspended', 'an active agent can be suspended with a reason');
  r := ins_set_intermediary_status(v_agent, 'active', 'Complaint closed');
  perform pg_temp.assert(r.status = 'active', 'a suspended agent can be reinstated with a reason');
  reset role;

  -- Termination is blocked while sub-agents still sit under the broker.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_set_intermediary_status(%L, ''terminated'', ''Ending relationship'')', v_broker),
    'INS_HAS_SUBAGENTS', 'terminating a broker that still has sub-agents');
  reset role;
  raise notice 'PASS: status moves follow the rules; termination waits for sub-agents to be moved';

  -------------------------------------------------------------------
  -- 8. Writes are RPC-only; the register is isolated by company
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_state(format('insert into ins_intermediaries (tenant_id, code, kind, name, category) values (%L, %L, %L, %L, %L)',
    ta, 'DIRECT', 'business', 'Direct write', 'referral_partner'), '42501', 'inserting a register row directly');
  perform pg_temp.expect_state(format('update ins_intermediaries set name = %L where id = %L', 'Renamed', v_broker),
    '42501', 'editing a register row directly');
  reset role;

  perform pg_temp.jwt(mgr_b);
  set local role authenticated;
  select count(*) into v_n from ins_intermediaries;
  perform pg_temp.assert(v_n = 0, format('company B manager sees %s of company A intermediaries', v_n));
  reset role;
  perform pg_temp.jwt(mem);
  set local role authenticated;
  select count(*) into v_n from ins_intermediaries where tenant_id = ta;
  perform pg_temp.assert(v_n > 0, 'a company A member cannot read its own register');
  reset role;

  -- The audit trail records who did what.
  select count(*) into v_n from ins_intermediary_events where intermediary_id = v_broker;
  perform pg_temp.assert(v_n >= 4, format('expected at least 4 history rows for the broker, found %s', v_n));
  raise notice 'PASS: writes go through the RPCs only; company B sees none of company A; history is recorded';
end $$;

rollback;
