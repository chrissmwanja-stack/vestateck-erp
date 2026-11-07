-- Insurance brokerage: in-force import, step 2 (policy commit + version-1 override)
-- (20261107160000_ins_import_commit_policies.sql).
--
-- Covers: manager-only and state checks (not validated, already committed,
-- cross-tenant); a happy-path commit creating active policies flagged with the
-- batch, no bind journal, no open items, no commission entries, no snapshot;
-- co-insurance share allocation that reconciles exactly to the legacy premium
-- and commission with one lead; atomic rollback when a policy's insurer is not
-- among its shares; the version-1 override on a tenant already on version 2
-- (and that a fake or foreign batch id does not trigger it); import flag
-- immutability and RPC-only creation; share rows locked again after commit;
-- anon EXECUTE denial.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction,
-- ROLLBACK at the end; any RAISE EXCEPTION fails the run.

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then return; end if;
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

create function pg_temp.scalar(p_sql text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text;
begin
  execute p_sql into v;
  return v;
end $$;

---------------------------------------------------------------------
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.c_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as mgr_b, gen_random_uuid() as adm;

insert into tenants (id, name)
select ta, 'Commit Brokerage A' from pg_temp.c_ids
union all
select tb, 'Commit Brokerage B' from pg_temp.c_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'impc-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.c_ids union all select mem from pg_temp.c_ids
      union all select mgr_b from pg_temp.c_ids union all select adm from pg_temp.c_ids) u;

insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Commit Manager A', 'impc-' || i.mgr || '@test.local', false from pg_temp.c_ids i
union all select i.mem, i.ta, 'Commit Member A', 'impc-' || i.mem || '@test.local', false from pg_temp.c_ids i
union all select i.adm, i.ta, 'Commit Admin A', 'impc-' || i.adm || '@test.local', true from pg_temp.c_ids i
union all select i.mgr_b, i.tb, 'Commit Manager B', 'impc-' || i.mgr_b || '@test.local', false from pg_temp.c_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.c_ids union all select tb, 'insurance' from pg_temp.c_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.c_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.c_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.c_ids;

-- master data for tenant A: two insurers, one product line, one client
select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.c_master as
with ins1 as (
  insert into ins_insurers (tenant_id, code, name, is_active)
  select ta, 'CMTINS1', 'Commit Insurer One', true from pg_temp.c_ids returning id
), ins2 as (
  insert into ins_insurers (tenant_id, code, name, is_active)
  select ta, 'CMTINS2', 'Commit Insurer Two', true from pg_temp.c_ids returning id
), line as (
  insert into ins_product_lines (tenant_id, code, name, class, is_active)
  select ta, 'GEN', 'General', 'general', true from pg_temp.c_ids returning id
), bdc as (
  insert into bd_clients (tenant_id, name)
  select ta, 'Commit Client' from pg_temp.c_ids returning id, tenant_id
), cli as (
  insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
  select tenant_id, id, 'corporate', 'verified' from bdc returning id
)
select i1.id as insurer1, i2.id as insurer2, l.id as product_line_id, c.id as client_id
  from ins1 i1, ins2 i2, line l, cli c;
select set_config('ins.via_rpc', 'off', true);

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  i   pg_temp.c_ids;
  m   pg_temp.c_master;
  b1  uuid;
  b2  uuid;
  b3  uuid;
  rep jsonb;
  v_n integer;
  v_p uuid;
  v_ver integer;
  v_pol_id uuid;
begin
  select * into i from pg_temp.c_ids;
  select * into m from pg_temp.c_master;

  -------------------------------------------------------------------
  -- 1. Access and state
  -------------------------------------------------------------------
  perform pg_temp.jwt(i.mgr);
  select id into b1 from public.ins_import_create_batch('Commit load 1', current_date - 7);

  perform pg_temp.jwt(i.mem);
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b1),
    'INS_ACCESS_DENIED', 'non-manager commit');

  perform pg_temp.jwt(i.mgr);
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b1),
    'INS_IMPORT_NOT_VALIDATED', 'commit a staged batch');

  perform pg_temp.jwt(i.mgr_b);
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b1),
    'INS_IMPORT_BATCH_NOT_FOUND', 'cross-tenant commit');
  raise notice 'PASS: access and state checks';

  -------------------------------------------------------------------
  -- 2. Happy path: one single-insurer policy, one co-insured policy
  -------------------------------------------------------------------
  perform pg_temp.jwt(i.mgr);
  perform public.ins_import_stage_rows(b1, 'policies', $j$[
    {"legacy_policy_no":"MIG-1","client_name":"commit client","insurer":"CMTINS1","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"1000000","commission_rate_pct":"10","sum_insured":"50000000","risk_description":"Warehouse"},
    {"legacy_policy_no":"MIG-2","client_name":"Commit Client","insurer":"CMTINS1","product_line":"GEN","inception_date":"2026-02-01","expiry_date":"2027-01-31","currency":"UGX","gross_premium":"100.01","commission_amount":"10.01"}
  ]$j$::jsonb);
  perform public.ins_import_stage_rows(b1, 'shares', $j$[
    {"legacy_policy_no":"MIG-2","insurer":"CMTINS1","share_pct":"50"},
    {"legacy_policy_no":"MIG-2","insurer":"CMTINS2","share_pct":"50"}
  ]$j$::jsonb);
  perform public.ins_import_stage_rows(b1, 'receipts', $j$[
    {"legacy_policy_no":"MIG-1","receipt_date":"2026-03-01","reference":"R1","amount":"400000"}
  ]$j$::jsonb);
  rep := public.ins_import_validate_batch(b1);
  perform pg_temp.assert((rep ->> 'error_count')::int = 0, 'happy batch validates clean: ' || rep::text);

  perform pg_temp.assert(
    (select count(*) from journal_entries where tenant_id = i.ta) = 0, 'precondition: tenant has no journals');

  rep := public.ins_import_commit_policies(b1);
  perform pg_temp.assert((rep ->> 'policies_created')::int = 2 and (rep ->> 'share_rows_created')::int = 2
                         and (rep ->> 'posted')::boolean = false, 'commit summary: ' || rep::text);
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_import_batches where id = %L', b1)) = 'committed',
    'batch is committed');
  perform pg_temp.assert(pg_temp.scalar(format('select committed_by::text from public.ins_import_batches where id = %L', b1)) = i.mgr::text,
    'commit attributed to the manager');

  perform pg_temp.assert((select count(*) from ins_policies
                           where import_batch_id = b1 and status = 'active' and migrated_at is not null
                             and bound_by = i.mgr and journal_entry_id is null) = 2,
    'both policies active, flagged, no bind journal');
  perform pg_temp.assert((select commission_amount = 100000 and net_premium_to_insurer = 900000
                                 and sum_insured = 50000000 and risk_description = 'Warehouse'
                            from ins_policies where tenant_id = i.ta and policy_no = 'MIG-1'),
    'single-insurer figures carried over');
  perform pg_temp.assert((select count(*) from ins_policy_insurer_shares s join ins_policies p on p.id = s.policy_id
                           where p.policy_no = 'MIG-1') = 0, 'single-insurer policy has no share rows (legacy bind path)');

  -- co-insured allocation reconciles exactly (100.01 / 10.01 split 50-50 needs the extra cent)
  perform pg_temp.assert((select sum(s.premium_amount) = 100.01 and sum(s.commission_amount) = 10.01
                                 and sum(s.payable_amount) = 90.00 and count(*) = 2
                                 and count(*) filter (where s.is_lead) = 1 and bool_and(s.reviewed)
                            from ins_policy_insurer_shares s join ins_policies p on p.id = s.policy_id
                           where p.policy_no = 'MIG-2'),
    'co-insured shares sum exactly to premium, commission and payable; one lead');
  perform pg_temp.assert((select s.is_lead from ins_policy_insurer_shares s join ins_policies p on p.id = s.policy_id
                           where p.policy_no = 'MIG-2' and s.insurer_id = m.insurer1),
    'the policy insurer is the lead');
  perform pg_temp.assert((select commission_amount = 10.01 and net_premium_to_insurer = 90.00
                            from ins_policies where tenant_id = i.ta and policy_no = 'MIG-2'),
    'co-insured policy header equals the legacy commission');

  -- nothing posted
  perform pg_temp.assert((select count(*) from journal_entries where tenant_id = i.ta) = 0, 'no journal entries posted');
  perform pg_temp.assert((select count(*) from fin_open_items where tenant_id = i.ta) = 0, 'no open items created');
  perform pg_temp.assert((select count(*) from ins_commission_entries where tenant_id = i.ta) = 0, 'no commission entries created');
  perform pg_temp.assert((select count(*) from ins_policy_financial_snapshots where tenant_id = i.ta) = 0, 'no bind snapshots created');

  -- the batch cannot be committed twice or edited after commit
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b1),
    'INS_IMPORT_ALREADY_COMMITTED', 'second commit');
  perform pg_temp.expect_error(format($q$select public.ins_import_stage_rows(%L, 'policies', '[]'::jsonb)$q$, b1),
    'INS_IMPORT_BATCH_LOCKED', 'stage after commit');
  raise notice 'PASS: happy path commits policies and shares and posts nothing';

  -------------------------------------------------------------------
  -- 3. Atomic rollback: policy insurer not among its shares
  -------------------------------------------------------------------
  select id into b2 from public.ins_import_create_batch('Commit load 2', current_date - 7);
  perform public.ins_import_stage_rows(b2, 'policies', $j$[
    {"legacy_policy_no":"GOOD-1","client_name":"Commit Client","insurer":"CMTINS1","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"1000","commission_rate_pct":"10"},
    {"legacy_policy_no":"BADLEAD-1","client_name":"Commit Client","insurer":"CMTINS1","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"1000","commission_rate_pct":"10"}
  ]$j$::jsonb);
  perform public.ins_import_stage_rows(b2, 'shares', $j$[
    {"legacy_policy_no":"BADLEAD-1","insurer":"CMTINS2","share_pct":"100"}
  ]$j$::jsonb);
  rep := public.ins_import_validate_batch(b2);
  perform pg_temp.assert((rep ->> 'error_count')::int = 0, 'rollback batch validates clean: ' || rep::text);
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b2),
    'INS_IMPORT_SHARE_LEAD_MISSING', 'lead missing from shares');
  perform pg_temp.assert((select count(*) from ins_policies where tenant_id = i.ta and policy_no in ('GOOD-1', 'BADLEAD-1')) = 0,
    'a failed commit leaves no policies behind (atomic)');
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_import_batches where id = %L', b2)) = 'validated',
    'a failed commit leaves the batch validated');
  raise notice 'PASS: failed commit rolls back completely';

  -------------------------------------------------------------------
  -- 4. Version-1 override on a tenant already on version 2
  -------------------------------------------------------------------
  -- approved version 2, effective before the dates used below (no journals yet in this tenant)
  insert into accounting_policies (tenant_id, version, name, description, effective_from, created_by)
  values (i.ta, 2, 'Later policy', 'test only', date '2026-01-01', i.adm) returning id into v_p;
  perform set_config('acct.via_rpc', 'on', true);
  update accounting_policies set status = 'approved', approved_by = i.mgr, approved_at = now() where id = v_p;
  perform set_config('acct.via_rpc', 'off', true);
  perform pg_temp.assert(public.platform_accounting_policy_version(i.ta, date '2026-06-01') = 2, 'tenant is on version 2');

  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (i.ta, date '2026-06-01', 'manual', 'no marker') returning accounting_policy_version into v_ver;
  perform pg_temp.assert(v_ver = 2, 'without the marker a posting is stamped 2');

  -- a fake batch id does nothing
  perform set_config('acct.import_batch', gen_random_uuid()::text, true);
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (i.ta, date '2026-06-02', 'manual', 'fake marker') returning accounting_policy_version into v_ver;
  perform pg_temp.assert(v_ver = 2, 'a fake batch id does not override the stamp');

  -- a batch that is still only staged does nothing
  select id into b3 from public.ins_import_create_batch('Staged only', current_date - 1);
  perform set_config('acct.import_batch', b3::text, true);
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (i.ta, date '2026-06-03', 'manual', 'staged marker') returning accounting_policy_version into v_ver;
  perform pg_temp.assert(v_ver = 2, 'a batch that is not validated or committed does not override the stamp');

  -- the committed batch of the same tenant does
  perform set_config('acct.import_batch', b1::text, true);
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (i.ta, date '2026-06-04', 'manual', 'committed marker') returning accounting_policy_version into v_ver;
  perform pg_temp.assert(v_ver = 1, 'a committed batch of the same tenant stamps version 1');

  -- a validated batch of ANOTHER tenant never does
  perform pg_temp.jwt(i.mgr_b);
  select id into v_p from public.ins_import_create_batch('Tenant B batch', current_date - 1);
  update ins_import_batches set status = 'validated' where id = v_p;   -- owner shortcut for the fixture
  perform pg_temp.jwt(i.mgr);
  perform set_config('acct.import_batch', v_p::text, true);
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (i.ta, date '2026-06-06', 'manual', 'foreign batch marker') returning accounting_policy_version into v_ver;
  perform pg_temp.assert(v_ver = 2, 'a validated batch of another tenant does not override the stamp');

  perform set_config('acct.import_batch', '', true);
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (i.ta, date '2026-06-05', 'manual', 'marker cleared') returning accounting_policy_version into v_ver;
  perform pg_temp.assert(v_ver = 2, 'clearing the marker restores normal stamping');
  raise notice 'PASS: version-1 override works only for a validated or committed batch of the same tenant';

  -------------------------------------------------------------------
  -- 5. Import flag: RPC-only, immutable; shares locked again
  -------------------------------------------------------------------
  select id into v_pol_id from ins_policies where tenant_id = i.ta and policy_no = 'MIG-1';
  -- a migrated (active) policy is locked like any bound policy, which also covers its flag
  perform pg_temp.expect_error(format('update ins_policies set import_batch_id = null, migrated_at = null where id = %L', v_pol_id),
    'INS_POLICY_LOCKED', 'clear the import flag of a migrated policy');
  -- the flag trigger on its own: a plain draft cannot be given an import flag
  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, inception_date, expiry_date, currency)
  values (i.ta, 'PLAIN-DRAFT', m.client_id, m.insurer1, m.product_line_id, date '2026-01-01', date '2026-12-31', 'UGX')
  returning id into v_p;
  perform set_config('ins.via_rpc', 'off', true);
  perform pg_temp.expect_error(format('update ins_policies set import_batch_id = %L, migrated_at = now() where id = %L', b1, v_p),
    'INS_IMPORT_IMMUTABLE', 'give a draft an import flag');
  perform pg_temp.expect_error(format($q$update ins_policies set risk_description = 'edited' where id = %L$q$, v_pol_id),
    'INS_POLICY_LOCKED', 'edit a migrated policy (locked like any bound policy)');

  perform set_config('ins.via_rpc', 'on', true);
  perform pg_temp.expect_error(format($q$
    insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, inception_date, expiry_date,
                              currency, import_batch_id, migrated_at)
    values (%L, 'SNEAK-1', %L, %L, %L, date '2026-01-01', date '2026-12-31', 'UGX', %L, now())$q$,
    i.ta, m.client_id, m.insurer1, m.product_line_id, b1),
    'INS_IMPORT_RPC_ONLY', 'create a flagged policy outside the commit');
  perform set_config('ins.via_rpc', 'off', true);

  select s.id into v_p from ins_policy_insurer_shares s join ins_policies p on p.id = s.policy_id where p.policy_no = 'MIG-2' limit 1;
  perform pg_temp.expect_error(format('update ins_policy_insurer_shares set premium_amount = 1 where id = %L', v_p),
    'INS_FINANCIAL_IMMUTABLE', 'edit a migrated policy share after commit');
  perform pg_temp.expect_error(format('delete from ins_policy_insurer_shares where id = %L', v_p),
    'INS_FINANCIAL_IMMUTABLE', 'delete a migrated policy share after commit');
  raise notice 'PASS: import flag is RPC-only and immutable; shares are locked after commit';
end $$;

-- anon EXECUTE check (catalog-level, runs as owner)
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_import_commit_policies', 'platform_ins_import_allocate')
     and grantee in ('anon', 'PUBLIC')),
  'anon / PUBLIC have no EXECUTE on the commit functions');
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'platform_ins_import_allocate' and grantee = 'authenticated'),
  'authenticated cannot execute the internal allocation helper');

rollback;