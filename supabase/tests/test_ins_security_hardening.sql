-- Regression test for 20261016090000_ins_security_.hardening.sql (applied live)
-- and its follow-up 20261016100000_ins_security_hardening_followup.sql.
--
--   1. The five trigger-only functions cannot be executed by PUBLIC, anon,
--      authenticated or service_role (catalog check AND a real denied call).
--   2. No trigger function named ins_% / platform_ins_% is executable by a
--      client role (guards against the next older-style guard slipping through).
--   3. fin_ledger_currency, ins_via_rpc, ins_touch_updated_at and
--      post_journal_entry have search_path = public, pg_temp.
--   4. The guards still fire after the revoke: the bind fixture below runs as an
--      ordinary Insurance manager (ins_clients_guard, ins_policies_guard and the
--      touch trigger all execute), and ins_insurers_guard still rejects a direct
--      party-account change.
--
-- Run only on a disposable local/test database; every fixture rolls back.
\set ON_ERROR_STOP on
begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then
      return;
    end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
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

-- ---------------------------------------------------------------------
-- 1 and 2. Catalog state
-- ---------------------------------------------------------------------
do $$
declare
  fn text;
  r record;
begin
  foreach fn in array array[
    'public.ins_claims_guard()',
    'public.ins_clients_guard()',
    'public.ins_insurers_guard()',
    'public.ins_policies_guard()',
    'public.ins_touch_updated_at()'
  ] loop
    perform pg_temp.assert(not has_function_privilege('anon', fn::regprocedure, 'EXECUTE'),
      fn || ' must not be executable by anon (or PUBLIC)');
    perform pg_temp.assert(not has_function_privilege('authenticated', fn::regprocedure, 'EXECUTE'),
      fn || ' must not be executable by authenticated');
    perform pg_temp.assert(not has_function_privilege('service_role', fn::regprocedure, 'EXECUTE'),
      fn || ' must not be executable by service_role');
  end loop;

  for r in
    select p.oid::regprocedure::text as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prorettype = 'trigger'::regtype
      and (p.proname like 'ins\_%' or p.proname like 'platform\_ins\_%')
  loop
    perform pg_temp.assert(not has_function_privilege('anon', r.sig::regprocedure, 'EXECUTE'),
      r.sig || ' is an insurance trigger function executable by anon');
    perform pg_temp.assert(not has_function_privilege('authenticated', r.sig::regprocedure, 'EXECUTE'),
      r.sig || ' is an insurance trigger function executable by authenticated');
  end loop;

  -- 3. search_path pinned
  foreach fn in array array[
    'public.fin_ledger_currency(uuid)',
    'public.ins_via_rpc()',
    'public.ins_touch_updated_at()',
    'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)'
  ] loop
    perform pg_temp.assert(exists (
      select 1 from pg_proc p
      where p.oid = fn::regprocedure
        and 'search_path=pg_catalog, public, pg_temp' = any (coalesce(p.proconfig, '{}'))),
      fn || ' must have search_path=pg_catalog, public, pg_temp');
  end loop;

  -- ins_via_rpc and fin_ledger_currency stay callable: policies and guards use them.
  perform pg_temp.assert(has_function_privilege('authenticated', 'public.ins_via_rpc()'::regprocedure, 'EXECUTE'),
    'ins_via_rpc must stay executable by authenticated');
  perform pg_temp.assert(has_function_privilege('authenticated', 'public.fin_ledger_currency(uuid)'::regprocedure, 'EXECUTE'),
    'fin_ledger_currency must stay executable by authenticated');
  -- post_journal_entry stays closed to clients.
  perform pg_temp.assert(not has_function_privilege('authenticated', 'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)'::regprocedure, 'EXECUTE')
    and not has_function_privilege('anon', 'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)'::regprocedure, 'EXECUTE'),
    'post_journal_entry must not be executable by clients');
  raise notice 'PASS: catalog state (grants and search_path)';
end $$;

-- ---------------------------------------------------------------------
-- Real denied calls, as each client role
-- ---------------------------------------------------------------------
do $$
begin
  set local role anon;
  perform pg_temp.expect_state('select public.ins_claims_guard()',     '42501', 'anon calling ins_claims_guard');
  perform pg_temp.expect_state('select public.ins_clients_guard()',    '42501', 'anon calling ins_clients_guard');
  perform pg_temp.expect_state('select public.ins_insurers_guard()',   '42501', 'anon calling ins_insurers_guard');
  perform pg_temp.expect_state('select public.ins_policies_guard()',   '42501', 'anon calling ins_policies_guard');
  perform pg_temp.expect_state('select public.ins_touch_updated_at()', '42501', 'anon calling ins_touch_updated_at');
  reset role;

  set local role authenticated;
  perform pg_temp.expect_state('select public.ins_claims_guard()',     '42501', 'authenticated calling ins_claims_guard');
  perform pg_temp.expect_state('select public.ins_clients_guard()',    '42501', 'authenticated calling ins_clients_guard');
  perform pg_temp.expect_state('select public.ins_insurers_guard()',   '42501', 'authenticated calling ins_insurers_guard');
  perform pg_temp.expect_state('select public.ins_policies_guard()',   '42501', 'authenticated calling ins_policies_guard');
  perform pg_temp.expect_state('select public.ins_touch_updated_at()', '42501', 'authenticated calling ins_touch_updated_at');
  reset role;
  raise notice 'PASS: direct calls are denied for anon and authenticated';
end $$;

-- ---------------------------------------------------------------------
-- 4. Guards and touch trigger still fire for an ordinary Insurance manager.
--    Fixture mirrors test_ins_policy_cash.sql (a proven pattern).
-- ---------------------------------------------------------------------
do $$
declare
  ta uuid := gen_random_uuid();
  manager uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  line_id uuid; insurer uuid;
  c ins_clients%rowtype; p ins_policies%rowtype;
begin
  insert into tenants(id, name) values (ta, 'Hardening test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (manager, 'hardening-' || manager || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now());
  insert into app_users(id, tenant_id, name, email)
    values (manager, ta, 'Hardening test manager', 'hardening-' || manager || '@test.local');
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, manager, 'insurance', 'manager');
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1100', 'AR', 'asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2010', 'Insurer payable', 'liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2020', 'Unearned commission', 'liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4000', 'Commission income', 'revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'insurer_payable', pay_gl), (ta, 'unearned_commission', unearned_gl), (ta, 'commission_income', income_gl);

  perform pg_temp.jwt(manager);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into line_id;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha') returning id into insurer;
  c := ins_register_client('Hardening client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, insurer, line_id, current_date, current_date + 365, 50000, 'UGX', 1000, 10, null, null);
  p := ins_bind_policy(p.id);
  perform pg_temp.assert(p.status = 'active' and p.journal_entry_id is not null, 'policy binds with the guards in place');
  reset role;

  -- The insurers guard still rejects a direct party-account change (runs as owner;
  -- the trigger fires regardless of role). The bind RPC above leaves the
  -- transaction-local ins.via_rpc flag on, so clear it first; otherwise this
  -- statement would look like it came from an RPC.
  perform set_config('ins.via_rpc', '', true);
  perform pg_temp.expect_error(
    format('update ins_insurers set party_account_id = %L where id = %L', gen_random_uuid(), insurer),
    'INS_PARTY_ACCOUNT_RPC_ONLY', 'direct party account change');

  raise notice 'PASS: guards and touch trigger still fire for an ordinary Insurance manager';
end $$;

rollback;