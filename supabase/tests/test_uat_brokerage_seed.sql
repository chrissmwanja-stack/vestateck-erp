-- Guards the UAT tenant built by supabase/seed.sql section 6
-- (Pearl Risk Brokers Ltd, 00000000-0000-0000-0000-00000000b001).
--
-- Read-only against the seeded database. Fails if a seed change leaves the
-- tenant incomplete: template not applied, wrong shape, or a tester login
-- that cannot see its own insurance data.
-- Skips (with a notice) when the seed skipped the tenant, e.g. no platform admin.

\set ON_ERROR_STOP on
begin;

do $$
declare
  v_t uuid := '00000000-0000-0000-0000-00000000b001';
  n integer;
begin
  if not exists (select 1 from tenants where id = v_t) then
    raise notice 'SKIP: UAT tenant not seeded in this database';
    return;
  end if;

  perform 1 from tenants where id = v_t and industry_template = 'insurance';
  if not found then raise exception 'FAIL: UAT tenant industry_template is not insurance'; end if;

  select count(*) into n from tenant_modules where tenant_id = v_t and module in ('insurance','hr','it','legal');
  if n <> 4 then raise exception 'FAIL: UAT tenant modules: expected insurance, hr, it, legal (got %)', n; end if;

  select count(*) into n from departments where tenant_id = v_t;
  if n <> 8 then raise exception 'FAIL: UAT tenant departments: expected 8, got %', n; end if;

  select count(*) into n from gl_accounts where tenant_id = v_t;
  if n <> 21 then raise exception 'FAIL: UAT tenant GL accounts: expected 21, got %', n; end if;

  select count(*) into n from app_users where tenant_id = v_t;
  if n <> 6 then raise exception 'FAIL: UAT tenant users: expected 6, got %', n; end if;

  -- Three distinct Finance users are needed for the third-person rule
  -- (INS_CASH_THIRD_PERSON / INS_CXL_CASH_THIRD_PERSON): maker, checker, reconciler.
  select count(distinct user_id) into n from finance_team_members
  where tenant_id = v_t and role = 'finance'
    and user_id in ('00000000-0000-0000-0000-00000000b104',
                    '00000000-0000-0000-0000-00000000b105',
                    '00000000-0000-0000-0000-00000000b106');
  if n <> 3 then raise exception 'FAIL: UAT Finance maker/checker/reconciler: expected 3 distinct, got %', n; end if;

  select count(*) into n from ins_policies where tenant_id = v_t and status = 'active';
  if n <> 3 then raise exception 'FAIL: UAT tenant active policies: expected 3, got %', n; end if;

  select count(*) into n from ins_policies where tenant_id = v_t and status = 'draft';
  if n <> 1 then raise exception 'FAIL: UAT tenant draft policies: expected 1, got %', n; end if;

  select count(*) into n from ins_claims where tenant_id = v_t;
  if n <> 1 then raise exception 'FAIL: UAT tenant claims: expected 1, got %', n; end if;

  -- Every bound policy must have posted (bind creates journals).
  select count(*) into n from ins_policies p
  where p.tenant_id = v_t and p.status = 'active'
    and not exists (select 1 from journal_entries j where j.tenant_id = v_t and j.source_id = p.id);
  if n <> 0 then raise exception 'FAIL: % active UAT policies have no journal entry', n; end if;

  -- The account manager login must see the tenant's insurance data through RLS.
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000b102', 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from ins_policies;
  reset role;
  if n <> 4 then raise exception 'FAIL: UAT account manager sees % policies, expected 4', n; end if;

  -- Regulatory values are drafts only: marked UNVERIFIED, never approved by the seed.
  select count(*) into n from regulatory_parameters where tenant_id = v_t and status = 'draft';
  if n <> 4 then raise exception 'FAIL: UAT regulatory drafts: expected 4, got %', n; end if;
  select count(*) into n from regulatory_parameters
   where tenant_id = v_t and (status <> 'draft' or source_ref not like 'UNVERIFIED:%');
  if n <> 0 then raise exception 'FAIL: UAT regulatory seed rows must be unverified drafts (found %)', n; end if;

  raise notice 'PASS: UAT brokerage seed is complete';
end $$;

rollback;
