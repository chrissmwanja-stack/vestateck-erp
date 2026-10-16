-- Insurance authorisation invariants (P0-6).
--
--   Part 1 (catalog, every ins_ / platform_ins_ object):
--     a. No insurance function is executable by anon or PUBLIC.
--     b. No platform_ins_ implementation is executable by authenticated.
--     c. Every SECURITY DEFINER ins_ function pins its search_path.
--     d. Every ins_ table has row-level security enabled and no anon/PUBLIC privileges.
--   Part 2 (behaviour, two tenants):
--     e. ins_commission_bank_accounts() returns only the caller's tenant's accounts.
--     f. A user without an insurance role is refused.
--     g. ins_withdraw_policy_cancellation() cannot touch another tenant's cancellation,
--        and the proposer in their own tenant can still withdraw it.
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
-- Part 1. Catalog invariants
-- ---------------------------------------------------------------------
do $$
declare n integer;
begin
  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and (p.proname like 'ins\_%' or p.proname like 'platform\_ins\_%')
    and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    where a.grantee = 0 and a.privilege_type = 'EXECUTE'));
  perform pg_temp.assert(n = 0, format('a: %s insurance function(s) executable by anon or PUBLIC', n));

  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname like 'platform\_ins\_%'
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  perform pg_temp.assert(n = 0, format('b: %s platform_ins_ implementation(s) executable by authenticated', n));

  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname like 'ins\_%' and p.prosecdef
    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
  perform pg_temp.assert(n = 0, format('c: %s SECURITY DEFINER ins_ function(s) without a pinned search_path', n));

  select count(*) into n
  from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'public' and c.relkind in ('r', 'p') and c.relname like 'ins\_%'
    and (not c.relrowsecurity
         or exists (select 1 from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                    where a.grantee = 0 or a.grantee = 'anon'::regrole));
  perform pg_temp.assert(n = 0, format('d: %s ins_ table(s) without RLS or with anon/PUBLIC privileges', n));
end $$;

-- ---------------------------------------------------------------------
-- Part 2. Behaviour across two tenants
-- ---------------------------------------------------------------------
do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  mgr_a uuid := gen_random_uuid();
  mgr_b uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
  gl_a uuid; gl_b uuid;
  line_id uuid; insurer uuid;
  c ins_clients%rowtype; p ins_policies%rowtype;
  cx_id uuid := gen_random_uuid();
  n integer; names text;
  status_after text;
begin
  insert into tenants(id, name) values (ta, 'Authz catalog A'), (tb, 'Authz catalog B');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'authz-'||u||'@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[mgr_a, mgr_b, outsider]) u;
  insert into app_users(id, tenant_id, name, email)
    values (mgr_a, ta, 'Authz manager A', 'authz-'||mgr_a||'@test.local'),
           (mgr_b, tb, 'Authz manager B', 'authz-'||mgr_b||'@test.local'),
           (outsider, ta, 'Authz outsider', 'authz-'||outsider||'@test.local');
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr_a, 'insurance', 'manager'), (tb, mgr_b, 'insurance', 'manager');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating A', 'asset') returning id into gl_a;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (tb, '1000', 'Operating B', 'asset') returning id into gl_b;
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id) values (ta, 'AUTHZ-A-OPERATING', 'operating', 'UGX', gl_a);
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id) values (tb, 'AUTHZ-B-OPERATING', 'operating', 'UGX', gl_b);

  -- Tenant A policy and an open cancellation, created as the tenant A manager.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into line_id;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha') returning id into insurer;
  c := ins_register_client('Authz catalog client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, insurer, line_id, current_date, current_date + 365, 50000, 'UGX', 1000, 10, null, null);
  reset role;

  insert into ins_policy_cancellations(
    id, tenant_id, policy_id, request_key, reason, effective_date, insurer_terms, charge_refunds,
    proposed_by, status, calculation)
  values (cx_id, ta, p.id, gen_random_uuid(), 'Authz fixture cancellation', current_date,
          '[]'::jsonb, '[]'::jsonb, mgr_a, 'proposed', '{}'::jsonb);

  -- e. Tenant B manager sees only tenant B's bank accounts.
  perform pg_temp.jwt(mgr_b); set local role authenticated;
  select count(*), coalesce(string_agg(name, ','), '') into n, names from ins_commission_bank_accounts();
  reset role;
  perform pg_temp.assert(n = 1 and names = 'AUTHZ-B-OPERATING',
    format('e: tenant B manager saw %s bank account(s): [%s]', n, names));

  -- Tenant A manager sees only tenant A's bank accounts.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  select count(*), coalesce(string_agg(name, ','), '') into n, names from ins_commission_bank_accounts();
  reset role;
  perform pg_temp.assert(n = 1 and names = 'AUTHZ-A-OPERATING',
    format('e: tenant A manager saw %s bank account(s): [%s]', n, names));

  -- f. A user with no insurance role is refused.
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_state('select * from ins_commission_bank_accounts()', '42501',
    'f: outsider listing commission bank accounts');
  reset role;

  -- g. Tenant B manager cannot withdraw tenant A's cancellation.
  perform pg_temp.jwt(mgr_b); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_withdraw_policy_cancellation(%L, %L)', cx_id, 'Cross-tenant withdraw attempt'),
    'INS_NOT_FOUND', 'g: tenant B withdrawing tenant A cancellation');
  reset role;
  select status into status_after from ins_policy_cancellations where id = cx_id;
  perform pg_temp.assert(status_after = 'proposed', format('g: cross-tenant withdraw changed status to %s', status_after));

  -- g. The proposer in tenant A can withdraw it.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  perform ins_withdraw_policy_cancellation(cx_id, 'Withdrawn by the proposer in test');
  reset role;
  select status into status_after from ins_policy_cancellations where id = cx_id;
  perform pg_temp.assert(status_after = 'withdrawn', format('g: proposer withdraw left status %s', status_after));

  raise notice 'PASS: insurance authorisation catalog and cross-tenant checks';
end $$;

rollback;
