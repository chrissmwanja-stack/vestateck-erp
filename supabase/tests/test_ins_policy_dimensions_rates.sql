-- Phase C item 1 (20261020210000_ins_policy_dimensions_and_rates.sql):
-- reporting dimensions on policies (branch, agent, transaction type) and the
-- commission rate matrix.
--
-- Run inside a transaction that is rolled back, so it leaves no data behind.
-- Any RAISE EXCEPTION is a real assertion failure and makes psql exit non-zero.
-- Binding a policy's ledger behaviour is covered by test_ins_core.sql; here an
-- active policy is produced through the same RPC channel the bind uses, so the
-- renewal stamping can be tested without the GL harness.

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

create function pg_temp.via_on() returns void language sql as $$
  select set_config('ins.via_rpc', 'on', true);
$$;

create function pg_temp.via_off() returns void language sql as $$
  select set_config('ins.via_rpc', 'off', true);
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  mgr   uuid := gen_random_uuid();   -- tenant A insurance manager, enters rates
  appr  uuid := gen_random_uuid();   -- tenant A insurance manager, approves them
  mem   uuid := gen_random_uuid();   -- tenant A member (reads, no rate rights)
  mgr_b uuid := gen_random_uuid();   -- tenant B manager
  v_line uuid; v_insr uuid; v_line_b uuid; v_insr_b uuid;
  v_branch uuid; v_branch_off uuid; v_branch_b uuid;
  v_agent uuid; v_agent_off uuid; v_agent_b uuid;
  c1 ins_clients%rowtype;
  p1 ins_policies%rowtype; p2 ins_policies%rowtype; p_ren ins_policies%rowtype;
  r1 ins_insurer_product_rates%rowtype; r2 ins_insurer_product_rates%rowtype;
  r3 ins_insurer_product_rates%rowtype;
  v_n integer;
begin
  insert into tenants (id, name) values (ta, 'Dimensions A'), (tb, 'Dimensions B');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'dims-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{}', '{}', now(), now(), '', ''
    from (values (mgr), (appr), (mem), (mgr_b)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,   ta, 'Dims manager',   'dims-' || mgr   || '@test.local'),
    (appr,  ta, 'Dims approver',  'dims-' || appr  || '@test.local'),
    (mem,   ta, 'Dims member',    'dims-' || mem   || '@test.local'),
    (mgr_b, tb, 'Dims manager B', 'dims-' || mgr_b || '@test.local');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (ta, mgr, 'insurance', 'manager'), (ta, appr, 'insurance', 'manager'),
    (ta, mem, 'insurance', 'member'), (tb, mgr_b, 'insurance', 'manager');

  -- Masters: both tenants. Insurers and product lines are written as their
  -- managers the way the screens do; organisations sit behind another module's
  -- RLS and a trigger that derives the tenant from the session, so their fixture
  -- rows go in as the test's superuser with the right tenant's claims set.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name, class) values (ta, 'MOTOR', 'Motor', 'general') returning id into v_line;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (ta, 'ALPHA', 'Alpha Assurance', 12.5) returning id into v_insr;
  reset role;

  perform pg_temp.jwt(mgr);
  insert into organizations (tenant_id, company_code, site_name) values (ta, 'KLA', 'Kampala') returning id into v_branch;
  insert into organizations (tenant_id, company_code, site_name, is_active) values (ta, 'ENT', 'Entebbe (closed)', false) returning id into v_branch_off;
  perform pg_temp.jwt(mgr_b);
  insert into organizations (tenant_id, company_code, site_name) values (tb, 'NBA', 'Nairobi') returning id into v_branch_b;
  reset role;

  perform pg_temp.jwt(mgr_b);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name, class) values (tb, 'MOTOR', 'Motor B', 'general') returning id into v_line_b;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (tb, 'BETA', 'Beta Assurance', 10) returning id into v_insr_b;
  reset role;

  -- Intermediaries: an active agent and a suspended one in A, an active agent in B.
  insert into ins_intermediaries (tenant_id, code, name, category, status) values
    (ta, 'AG-001', 'Kampala Agent', 'independent_broker', 'active') returning id into v_agent;
  insert into ins_intermediaries (tenant_id, code, name, category, status) values
    (ta, 'AG-002', 'Suspended Agent', 'independent_broker', 'suspended') returning id into v_agent_off;
  insert into ins_intermediaries (tenant_id, code, name, category, status) values
    (tb, 'AG-B1', 'Nairobi Agent', 'independent_broker', 'active') returning id into v_agent_b;

  -------------------------------------------------------------------
  -- 1. Dimensions on create
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  c1 := ins_register_client('Dimension Client', 'corporate', null, null, null, 'low');

  p1 := ins_create_policy(c1.id, v_insr, v_line, current_date, current_date + 365,
                          5000000, 'UGX', 250000, 12.5, v_branch, v_agent, 'Fleet', null);
  perform pg_temp.assert(p1.transaction_type = 'new_business', 'a created policy is new business');
  perform pg_temp.assert(p1.branch_id = v_branch and p1.agent_id = v_agent, 'create carries branch and agent');

  -- An agent or branch from another tenant is refused. The create RPC says
  -- "not found" (it does not hint at other tenants); the guard's cross-tenant
  -- message is exercised by the direct draft edit further down.
  perform pg_temp.expect_error(
    format('select ins_create_policy(%L, %L, %L, current_date, current_date + 365, 1, ''UGX'', 1, 10, null, %L, null, null)',
           c1.id, v_insr, v_line, v_agent_b),
    'INS_NOT_FOUND: active intermediary', 'create with another tenant''s agent');
  perform pg_temp.expect_error(
    format('select ins_create_policy(%L, %L, %L, current_date, current_date + 365, 1, ''UGX'', 1, 10, %L, null, null, null)',
           c1.id, v_insr, v_line, v_branch_b),
    'INS_NOT_FOUND: active organisation', 'create with another tenant''s branch');
  -- A suspended agent cannot take new business.
  perform pg_temp.expect_error(
    format('select ins_create_policy(%L, %L, %L, current_date, current_date + 365, 1, ''UGX'', 1, 10, null, %L, null, null)',
           c1.id, v_insr, v_line, v_agent_off),
    'INS_NOT_FOUND: active intermediary', 'create with a suspended agent');
  -- A closed branch cannot take new business.
  perform pg_temp.expect_error(
    format('select ins_create_policy(%L, %L, %L, current_date, current_date + 365, 1, ''UGX'', 1, 10, %L, null, null, null)',
           c1.id, v_insr, v_line, v_branch_off),
    'INS_NOT_FOUND: active organisation', 'create with a closed branch');

  -- The old 11-argument call still works and leaves the dimensions empty.
  p2 := ins_create_policy(c1.id, v_insr, v_line, current_date, current_date + 365,
                          1000000, 'UGX', 50000, 10, null, null);
  perform pg_temp.assert(p2.agent_id is null and p2.branch_id is null and p2.transaction_type = 'new_business',
                         'the legacy call creates a plain new-business draft');
  reset role;
  raise notice 'PASS: dimensions on create';

  -------------------------------------------------------------------
  -- 2. Draft edits and the guard
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  -- A member or manager edits the draft directly: moving to an active agent works.
  update ins_policies set agent_id = v_agent where id = p2.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 1, 'a draft can be moved to an active agent');
  -- Moving to a suspended agent is refused.
  perform pg_temp.expect_state(
    format('update ins_policies set agent_id = %L where id = %L', v_agent_off, p2.id),
    'P0001', 'draft moved to a suspended agent');
  perform pg_temp.assert((select agent_id from ins_policies where id = p2.id) = v_agent,
                         'the refused update left the agent unchanged');
  -- A closed branch is refused on change; an open one works.
  perform pg_temp.expect_state(
    format('update ins_policies set branch_id = %L where id = %L', v_branch_off, p2.id),
    'P0001', 'draft moved to a closed branch');
  update ins_policies set branch_id = v_branch where id = p2.id;
  -- The other tenant's agent is refused even though the row exists: the guard's cross-tenant check.
  perform pg_temp.expect_error(
    format('update ins_policies set agent_id = %L where id = %L', v_agent_b, p2.id),
    'INS_CROSS_TENANT: agent', 'draft moved to another tenant''s agent');
  reset role;
  raise notice 'PASS: draft edits guard the dimensions';

  -------------------------------------------------------------------
  -- 3. Renewal: stamped 'renewal', dimensions copied
  -------------------------------------------------------------------
  -- An active policy through the same channel bind uses (the bind's ledger
  -- behaviour is test_ins_core's subject; the stamps satisfy ins_policies_bound_check).
  perform pg_temp.via_on();
  update ins_policies
     set status = 'active', commission_amount = 31250, net_premium_to_insurer = 218750, bound_at = now()
   where id = p1.id;
  perform pg_temp.via_off();
  perform pg_temp.assert((select status from ins_policies where id = p1.id) = 'active', 'p1 is active for renewal');

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p_ren := ins_create_renewal_draft(p1.id);
  perform pg_temp.assert(p_ren.transaction_type = 'renewal', 'a renewal draft is stamped renewal');
  perform pg_temp.assert(p_ren.agent_id = v_agent and p_ren.branch_id = v_branch, 'renewal copies branch and agent');
  perform pg_temp.assert(p_ren.renewal_of_id = p1.id, 'renewal links back');
  reset role;
  raise notice 'PASS: renewal stamping and dimension copy';

  -------------------------------------------------------------------
  -- 4. A bound policy cannot have its dimensions changed
  -------------------------------------------------------------------
  -- The user path never even sees the row: the update RLS policy filters on
  -- status = 'draft', so the change affects nothing.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  update ins_policies set agent_id = v_agent_off where id = p1.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'a bound policy is not updatable through the table');
  reset role;
  -- The guard is the backstop for paths that bypass RLS: any non-status field
  -- change on a non-draft policy raises even through the RPC channel.
  perform pg_temp.via_on();
  perform pg_temp.expect_error(
    format('update ins_policies set agent_id = %L where id = %L', v_agent_off, p1.id),
    'INS_POLICY_LOCKED', 'bound policy dimension change through the RPC channel');
  perform pg_temp.via_off();
  perform pg_temp.assert((select agent_id from ins_policies where id = p1.id) = v_agent,
                         'the bound policy kept its agent');
  raise notice 'PASS: bound policies stay locked';

  -------------------------------------------------------------------
  -- 5. Rate matrix: entry, approval, overlap, withdrawal
  -------------------------------------------------------------------
  perform pg_temp.jwt(mem);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_set_insurer_product_rate(%L, %L, 15, current_date, null, ''Agency agreement 2026'')', v_insr, v_line),
    'INS_FORBIDDEN', 'a member entering a rate');
  -- Direct writes are RPC-only.
  perform pg_temp.expect_state(
    format('insert into ins_insurer_product_rates (tenant_id, insurer_id, product_line_id, rate, effective_from, source_ref) values (%L, %L, %L, 15, current_date, ''x'')', ta, v_insr, v_line),
    '42501', 'direct insert into the rate table');
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  r1 := ins_set_insurer_product_rate(v_insr, v_line, 15, current_date - 30, null, 'Agency agreement 2026');
  perform pg_temp.assert(r1.status = 'draft' and r1.entered_by = mgr, 'a manager enters a draft rate');
  perform pg_temp.expect_error(
    format('select ins_set_insurer_product_rate(%L, %L, 15, current_date, null, null)', v_insr, v_line),
    'INS_RATE_SOURCE', 'a rate without a source reference');
  perform pg_temp.expect_error(
    format('select ins_set_insurer_product_rate(%L, %L, 100, current_date, null, ''x'')', v_insr, v_line),
    'INS_RATE_VALUE', 'a rate of 100');
  perform pg_temp.expect_error(
    format('select ins_set_insurer_product_rate(%L, %L, 15, current_date, current_date - 1, ''x'')', v_insr, v_line),
    'INS_RATE_WINDOW', 'a window ending before it starts');
  -- Self-approval is refused; the other manager approves.
  perform pg_temp.expect_error(
    format('select ins_approve_insurer_product_rate(%L)', r1.id),
    'INS_RATE_SELF_APPROVAL', 'self-approval of a rate');
  reset role;

  perform pg_temp.jwt(appr);
  set local role authenticated;
  r1 := ins_approve_insurer_product_rate(r1.id);
  perform pg_temp.assert(r1.status = 'approved' and r1.approved_by = appr, 'the second manager approves the rate');
  -- An overlapping approval is refused: r1 runs open-ended, so anything later overlaps.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  r2 := ins_set_insurer_product_rate(v_insr, v_line, 17.5, current_date - 10, null, 'Side letter 2026');
  reset role;
  perform pg_temp.jwt(appr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_approve_insurer_product_rate(%L)', r2.id),
    'INS_RATE_OVERLAP', 'approving an overlapping rate');
  reset role;
  -- A future window overlaps the open-ended r1 too; first end-date r1, then the
  -- promotion window approves.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  r2 := ins_set_insurer_product_rate(v_insr, v_line, 17.5, current_date + 30, current_date + 60, 'Promotion window');
  perform pg_temp.expect_error(
    format('select ins_end_insurer_product_rate(%L, current_date + 29)', r2.id),
    'INS_RATE_NOT_APPROVED', 'end-dating a draft');
  reset role;
  perform pg_temp.jwt(appr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_end_insurer_product_rate(%L, current_date - 60)', r1.id),
    'INS_RATE_WINDOW', 'end-dating before the rate starts');
  -- Direct edits never even reach the guard: the table grants SELECT only, so a
  -- direct update is permission denied; the guard backs up the RPC paths.
  perform pg_temp.expect_state(
    format('update ins_insurer_product_rates set effective_to = current_date + 29 where id = %L', r1.id),
    '42501', 'end-dating an approved rate directly');
  r1 := ins_end_insurer_product_rate(r1.id, current_date + 29);
  perform pg_temp.assert(r1.effective_to = current_date + 29, 'the approved rate is end-dated');
  perform pg_temp.expect_state(
    format('update ins_insurer_product_rates set rate = 20 where id = %L', r1.id),
    '42501', 'editing an approved rate');
  reset role;
  perform pg_temp.jwt(appr);
  set local role authenticated;
  r2 := ins_approve_insurer_product_rate(r2.id);
  perform pg_temp.assert(r2.status = 'approved', 'a non-overlapping later window approves after the end date');
  reset role;

  -- Withdrawal: needs a real reason; the entrant can withdraw their own draft.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  r3 := ins_set_insurer_product_rate(v_insr, v_line, 20, current_date + 61, null, 'Draft proposal');
  perform pg_temp.expect_error(
    format('select ins_withdraw_insurer_product_rate(%L, ''no'')', r3.id),
    'INS_RATE_REASON', 'withdrawing with a short reason');
  r3 := ins_withdraw_insurer_product_rate(r3.id, 'Superseded by the signed agreement');
  perform pg_temp.assert(r3.status = 'withdrawn', 'the entrant withdraws their own draft');
  perform pg_temp.expect_error(
    format('select ins_withdraw_insurer_product_rate(%L, ''changed my mind'')', r3.id),
    'INS_RATE_NOT_DRAFT', 'withdrawing a withdrawn rate');
  reset role;
  raise notice 'PASS: rate matrix lifecycle';

  -------------------------------------------------------------------
  -- 6. Rate matrix isolation and reads
  -------------------------------------------------------------------
  perform pg_temp.jwt(mem);
  set local role authenticated;
  select count(*) into v_n from ins_insurer_product_rates;
  perform pg_temp.assert(v_n = 4, 'a member reads their tenant''s rates (two approved, one draft, one withdrawn)');
  perform pg_temp.expect_error(
    format('select ins_approve_insurer_product_rate(%L)', r1.id),
    'INS_FORBIDDEN', 'a member approving');
  reset role;

  perform pg_temp.jwt(mgr_b);
  set local role authenticated;
  select count(*) into v_n from ins_insurer_product_rates;
  perform pg_temp.assert(v_n = 0, 'another tenant reads no rates');
  perform pg_temp.expect_error(
    format('select ins_approve_insurer_product_rate(%L)', r1.id),
    'INS_RATE_NOT_FOUND', 'another tenant approving our rate');
  perform pg_temp.expect_error(
    format('select ins_withdraw_insurer_product_rate(%L, ''not mine'')', r1.id),
    'INS_RATE_NOT_FOUND', 'another tenant withdrawing our rate');
  reset role;
  raise notice 'PASS: rate matrix isolation';

  raise notice 'ALL PASS: policy dimensions and commission rate matrix';
end $$;

rollback;
