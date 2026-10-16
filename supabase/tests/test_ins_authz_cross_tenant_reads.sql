-- P0-6 third pass: cross-tenant READS of insurance list and statement RPCs.
--
-- A read that is scoped to the caller's tenant never raises an error for another
-- tenant's data; it just returns nothing. So each check here looks for tenant A's
-- records in tenant B's results, and each has a positive control: tenant A's own
-- user must see the record, so an empty result cannot pass by accident.
--
--   ins_policy_cash_policies()            policy lookup for premium cash
--   ins_policy_charge_income_accounts()   revenue accounts for charge lines
--   ins_insurer_commission_statement_data statement for one insurer (errors: not found)
--   ins_broker_fee_tax_rows()             broker-fee tax report. This file checks only
--                                         that no tenant A rows appear, because its fixture
--                                         has no financial snapshot. The strong check, with a
--                                         real bound snapshot, is in
--                                         test_ins_authz_cross_tenant_views.sql.
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
  mgr_a uuid := gen_random_uuid();
  mgr_b uuid := gen_random_uuid();
  line_id uuid; insurer uuid; rev_a uuid;
  c ins_clients%rowtype; p ins_policies%rowtype;
  n integer;
  v jsonb;
begin
  insert into tenants(id, name) values (ta, 'Cross-read A'), (tb, 'Cross-read B');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'xr-'||u||'@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[mgr_a, mgr_b]) u;
  insert into app_users(id, tenant_id, name, email) values
    (mgr_a, ta, 'Cross-read manager A', 'xr-'||mgr_a||'@test.local'),
    (mgr_b, tb, 'Cross-read manager B', 'xr-'||mgr_b||'@test.local');
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values
    (ta, mgr_a, 'insurance', 'manager'), (tb, mgr_b, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values
    (ta, mgr_a, 'finance'), (tb, mgr_b, 'finance');

  -- Tenant A: a revenue account, a policy created through the app RPCs.
  insert into gl_accounts(tenant_id, account_code, name, account_type)
  values (ta, '4900', 'Cross-read revenue A', 'revenue') returning id into rev_a;

  perform pg_temp.jwt(mgr_a); set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into line_id;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha') returning id into insurer;
  c := ins_register_client('Cross-read client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, insurer, line_id, current_date, current_date + 365, 50000, 'UGX', 1000, 10, null, null);
  reset role;

  -- Policy lists skip drafts, and claims/cash need a bound policy. Mark it active the
  -- way the write-test fixture does; binding itself is covered elsewhere.
  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies
     set status = 'active', bound_at = now(),
         commission_amount = round(gross_premium * 10 / 100, 2),
         net_premium_to_insurer = gross_premium - round(gross_premium * 10 / 100, 2)
   where id = p.id;
  perform set_config('ins.via_rpc', 'off', true);

  -- Positive controls: tenant A's own user sees every record.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  select count(*) into n from ins_policy_cash_policies() where id = p.id;
  perform pg_temp.assert(n = 1, 'control: tenant A cannot see its own policy in the cash policy list');
  select count(*) into n from ins_policy_charge_income_accounts() where id = rev_a;
  perform pg_temp.assert(n = 1, 'control: tenant A cannot see its own revenue account');
  v := ins_insurer_commission_statement_data(insurer);
  perform pg_temp.assert(jsonb_typeof(v) = 'object', 'control: tenant A statement did not return an object');
  reset role;

  -- Tenant B must see none of tenant A's records.
  perform pg_temp.jwt(mgr_b); set local role authenticated;
  select count(*) into n from ins_policy_cash_policies() where id = p.id;
  perform pg_temp.assert(n = 0, 'tenant B sees tenant A''s policy in ins_policy_cash_policies');

  select count(*) into n from ins_policy_charge_income_accounts() where id = rev_a;
  perform pg_temp.assert(n = 0, 'tenant B sees tenant A''s revenue account in ins_policy_charge_income_accounts');

  perform pg_temp.expect_error(format('select ins_insurer_commission_statement_data(%L)', insurer),
    'INS_NOT_FOUND', 'commission statement for another tenant''s insurer');

  select count(*) into n from ins_broker_fee_tax_rows() where policy_id = p.id;
  perform pg_temp.assert(n = 0, 'tenant B sees tenant A''s rows in ins_broker_fee_tax_rows');
  reset role;

  raise notice 'PASS: cross-tenant reads for policy cash list, revenue accounts, commission statement and fee tax report';
end $$;

rollback;
