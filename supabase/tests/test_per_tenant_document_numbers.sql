-- Per-tenant uniqueness of asset tags, problem numbers and MR numbers.
--
-- Guards 20261001160000_per_tenant_document_numbers.sql.
--   1. Catalog: the old global unique constraints/index are gone and the
--      (tenant_id, number) ones exist.
--   2. Behaviour (assets, problems): two tenants can hold the same number,
--      one tenant cannot hold it twice.
--   requests.mr_number is checked at catalog level only: inserting a request
--      needs a requester and department and the defaults triggers rewrite
--      tenant_id from the caller's session.
--
-- Local/CI database only (see test_gl_posting_and_period_close.sql header).
-- Everything runs in one transaction that ROLLBACKs.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_n int;
  v_caught text;
begin
  -- 1. Catalog ---------------------------------------------------------
  if exists (select 1 from pg_constraint where conname in ('assets_asset_tag_key', 'problems_problem_number_key')) then
    raise exception 'FAIL 1a: a global unique constraint on asset_tag/problem_number still exists';
  end if;
  if to_regclass('public.requests_mr_number_key') is not null then
    raise exception 'FAIL 1b: global unique index requests_mr_number_key still exists';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'assets_tenant_id_asset_tag_key' and contype = 'u'
                   and pg_get_constraintdef(oid) ~ '\(tenant_id, asset_tag\)') then
    raise exception 'FAIL 1c: missing UNIQUE (tenant_id, asset_tag) on assets';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'problems_tenant_id_problem_number_key' and contype = 'u'
                   and pg_get_constraintdef(oid) ~ '\(tenant_id, problem_number\)') then
    raise exception 'FAIL 1d: missing UNIQUE (tenant_id, problem_number) on problems';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'requests_tenant_id_mr_number_key'
                   and indexdef ~* 'unique' and indexdef ~ '\(tenant_id, mr_number\)') then
    raise exception 'FAIL 1e: missing unique index (tenant_id, mr_number) on requests';
  end if;

  -- 2. Behaviour -------------------------------------------------------
  insert into tenants (id, name) values (v_a, 'PerTenantNo Tenant A'), (v_b, 'PerTenantNo Tenant B');

  insert into assets (tenant_id, type, name, asset_tag) values (v_a, 'hardware', 'A1', 'AST-00001');
  insert into assets (tenant_id, type, name, asset_tag) values (v_b, 'hardware', 'B1', 'AST-00001');
  select count(distinct tenant_id) into v_n from assets where asset_tag = 'AST-00001' and tenant_id in (v_a, v_b);
  if v_n <> 2 then raise exception 'FAIL 2a: expected the same asset tag in 2 tenants, got %', v_n; end if;

  begin
    insert into assets (tenant_id, type, name, asset_tag) values (v_a, 'hardware', 'A2', 'AST-00001');
    raise exception 'FAIL 2b: duplicate asset tag inside one tenant was accepted';
  exception when unique_violation then v_caught := 'ok';
  end;

  insert into problems (tenant_id, title, problem_number) values (v_a, 'A1', 'PRB-00001');
  insert into problems (tenant_id, title, problem_number) values (v_b, 'B1', 'PRB-00001');
  select count(distinct tenant_id) into v_n from problems where problem_number = 'PRB-00001' and tenant_id in (v_a, v_b);
  if v_n <> 2 then raise exception 'FAIL 2c: expected the same problem number in 2 tenants, got %', v_n; end if;

  begin
    insert into problems (tenant_id, title, problem_number) values (v_a, 'A2', 'PRB-00001');
    raise exception 'FAIL 2d: duplicate problem number inside one tenant was accepted';
  exception when unique_violation then v_caught := 'ok';
  end;

  raise notice 'PASS: document numbers are unique per tenant';
end $$;

rollback;
