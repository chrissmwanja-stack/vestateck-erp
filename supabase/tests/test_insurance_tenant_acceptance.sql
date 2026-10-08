-- Phase 1, step 7 acceptance test for the Insurance Brokerage vertical:
-- create a tenant FROM the 'insurance' template, the same way the
-- create-tenant edge function does (service-role insert of the tenant row, then
-- seed_tenant_defaults() called as a platform admin), and prove what that
-- tenant actually gets and, just as important, what it is denied.
--
-- test_insurance_template_v0.sql checks the template ROWS. This file checks the
-- TENANT that results, and the access boundary around it.
--
-- Verifies, against a fully-migrated fresh stack:
--   1. Seeding gives the tenant exactly the template: modules hr, insurance, it,
--      legal (and nothing else); the 8 template departments and no others (so no
--      construction departments); no workflow stages; no feature-flag overrides;
--      18 GL accounts and 18 posting rules that match the template, with client
--      money on the balance sheet (1020 asset, 2010 liability).
--   2. tenants.industry_template is 'insurance'.
--   3. Seeding twice adds nothing (seed_tenant_defaults is retry-safe).
--   4. Denial: a user of this tenant -- including one holding stale staff_roles
--      rows for pmo, machine_operation, sustainability, bd and procurement --
--      fails has_module_role() for each, reads zero rows from those modules'
--      tables, and cannot write to them. The same probe DOES succeed in a control
--      tenant that owns the pmo module, so the probe itself is not vacuous.
--   5. Access: an insurance member/admin reaches the client master; an hr-only
--      user does not; a company admin gets insurance admin but nothing else.
--   6. Seam 7: finance staff in an insurance tenant are finance team members
--      without PO access (has_po_access() is false), and read the chart of accounts.
--   7. Tenant isolation: an insurance user sees none of the control tenant's rows.
--
-- Run against a fresh local stack only -- never against a linked project.
-- Same conventions as test_template_kinds_and_apply_template.sql and
-- test_client_master_access.sql.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures (as the table owner, before impersonation)
-- ---------------------------------------------------------------------
do $$
declare
  v_home  uuid := gen_random_uuid();  -- platform operator's own tenant
  t_ins   uuid := gen_random_uuid();  -- the tenant under test
  t_ctl   uuid := gen_random_uuid();  -- control: owns pmo, proves the probe works
  u_admin uuid := gen_random_uuid();  -- platform admin
  u_cadm  uuid := gen_random_uuid();  -- insurance company admin
  u_im    uuid := gen_random_uuid();  -- insurance member
  u_fin   uuid := gen_random_uuid();  -- finance team member, no module roles
  u_hr    uuid := gen_random_uuid();  -- hr member only
  u_rogue uuid := gen_random_uuid();  -- stale roles on modules the tenant lacks
  u_ctl   uuid := gen_random_uuid();  -- pmo member in the control tenant
begin
  create temp table test_ids (k text primary key, v uuid) on commit drop;
  insert into test_ids values
    ('home', v_home), ('t_ins', t_ins), ('t_ctl', t_ctl),
    ('admin', u_admin), ('cadm', u_cadm), ('im', u_im), ('fin', u_fin),
    ('hr', u_hr), ('rogue', u_rogue), ('ctl', u_ctl);
  grant select on test_ids to authenticated, anon, service_role;

  -- Counts snapshot, so the second seeding can be compared with the first.
  create temp table snap (k text primary key, v jsonb) on commit drop;
  grant select, insert on snap to authenticated;

  insert into tenants (id, name, status, created_at, plan, subscription_status, industry_template) values
    (v_home, 'Ins Accept Platform Home', 'active',  now() - interval '300 days', 'internal', 'active', 'general'),
    -- Mirrors what create-tenant inserts: pending, standard, active, template key set.
    (t_ins,  'Ins Accept Brokerage',     'pending', now(),                      'standard', 'active', 'insurance'),
    (t_ctl,  'Ins Accept Control',       'active',  now() - interval '30 days', 'trial',    'trialing', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', now()
  from (values
    (u_admin, 'ia-admin'), (u_cadm, 'ia-cadm'), (u_im, 'ia-im'), (u_fin, 'ia-fin'),
    (u_hr, 'ia-hr'), (u_rogue, 'ia-rogue'), (u_ctl, 'ia-ctl')
  ) as u(id, handle);

  -- Platform-admin operations require MFA (see test_console_reads_require_mfa.sql).
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
  values (gen_random_uuid(), u_admin, 'test', 'totp', 'verified', now(), now());

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (u_admin, v_home, 'IA Admin',  'ia-admin@test.local', true,  false, now() - interval '300 days'),
    (u_cadm,  t_ins,  'IA CAdmin', 'ia-cadm@test.local',  false, true,  now()),
    (u_im,    t_ins,  'IA Member', 'ia-im@test.local',    false, false, now()),
    (u_fin,   t_ins,  'IA Finance','ia-fin@test.local',   false, false, now()),
    (u_hr,    t_ins,  'IA HR',     'ia-hr@test.local',    false, false, now()),
    (u_rogue, t_ins,  'IA Rogue',  'ia-rogue@test.local', false, false, now()),
    (u_ctl,   t_ctl,  'IA Control','ia-ctl@test.local',   false, false, now());

  -- Control tenant: owns pmo and has a pmo member and a project. If the denial
  -- probes below returned zero here too, they would prove nothing.
  insert into tenant_modules (tenant_id, module) values (t_ctl, 'pmo');
  insert into staff_roles (tenant_id, user_id, module, role) values (t_ctl, u_ctl, 'pmo', 'member');
  insert into pmo_projects (tenant_id, project_no, name) values (t_ctl, 'CTL-001', 'Control Project');
end $$;

create or replace function pg_temp.become(p_key text, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', p_aal)::text, true);
end $$;

create or replace function pg_temp.tid(p_key text) returns uuid
language sql as $$ select v from test_ids where k = p_key $$;

create or replace function pg_temp.assert(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

-- Row counts for the tenant, as one jsonb, so two seedings can be compared.
create or replace function pg_temp.counts(p_tenant uuid) returns jsonb
language sql as $$
  select jsonb_build_object(
    'modules',  (select count(*) from tenant_modules where tenant_id = p_tenant),
    'depts',    (select count(*) from departments where tenant_id = p_tenant),
    'stages',   (select count(*) from workflow_stages where tenant_id = p_tenant),
    'flags',    (select count(*) from tenant_feature_flags where tenant_id = p_tenant),
    'accounts', (select count(*) from gl_accounts where tenant_id = p_tenant),
    'rules',    (select count(*) from gl_posting_rules where tenant_id = p_tenant))
$$;

-- Statement must fail with insufficient_privilege (RLS WITH CHECK / USING denial).
create or replace function pg_temp.expect_denied(p_label text, p_sql text) returns void
language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    execute p_sql;
    v_ok := true;
  exception when insufficient_privilege then null;
  end;
  if v_ok then raise exception 'FAIL (%): write was allowed', p_label; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Create the tenant from the template, as create-tenant does:
--    seed_tenant_defaults() called through the platform admin's own JWT.
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('admin');
select seed_tenant_defaults(pg_temp.tid('t_ins'), 'insurance');
reset role;

insert into snap values ('first', pg_temp.counts(pg_temp.tid('t_ins')));

do $$
declare
  t_ins uuid := pg_temp.tid('t_ins');
  v_bad text;
begin
  -- 2. Template label.
  perform pg_temp.assert((select industry_template from tenants where id = t_ins) = 'insurance',
    'tenants.industry_template is not insurance after seeding');

  -- 1a. Modules: exactly the four, nothing else (in particular no pmo, machine_operation,
  --     sustainability, bd or procurement).
  perform pg_temp.assert(
    (select array_agg(module order by module) from tenant_modules where tenant_id = t_ins)
      is not distinct from array['hr', 'insurance', 'it', 'legal'],
    'tenant modules are not exactly hr, insurance, it, legal: '
      || coalesce((select string_agg(module, ',' order by module) from tenant_modules where tenant_id = t_ins), '(none)'));

  -- 1b. Departments: exactly the template's 8, no extras (so no construction departments).
  perform pg_temp.assert((select count(*) from departments where tenant_id = t_ins) = 8,
    'expected 8 departments, got ' || (select count(*) from departments where tenant_id = t_ins));
  select string_agg(i.name, ', ') into v_bad from industry_template_items i
   where i.template_key = 'insurance' and i.kind = 'department'
     and not exists (select 1 from departments d where d.tenant_id = t_ins and d.name = i.name);
  perform pg_temp.assert(v_bad is null, 'template departments missing from the tenant: ' || coalesce(v_bad, ''));
  select string_agg(d.name, ', ') into v_bad from departments d
   where d.tenant_id = t_ins
     and not exists (select 1 from industry_template_items i
                      where i.template_key = 'insurance' and i.kind = 'department' and i.name = d.name);
  perform pg_temp.assert(v_bad is null, 'departments not in the template (construction leftovers?): ' || coalesce(v_bad, ''));

  -- 1c. No workflow, no flag overrides.
  perform pg_temp.assert((select count(*) from workflow_stages where tenant_id = t_ins) = 0,
    'an insurance tenant must have no workflow stages');
  perform pg_temp.assert((select count(*) from tenant_feature_flags where tenant_id = t_ins) = 0,
    'v0 ships no feature-flag overrides');

  -- 1d. Chart of accounts and posting rules match the template item for item.
  perform pg_temp.assert((select count(*) from gl_accounts where tenant_id = t_ins) = 18, 'expected 18 gl_accounts');
  perform pg_temp.assert((select count(*) from gl_posting_rules where tenant_id = t_ins) = 18, 'expected 18 gl_posting_rules');

  select string_agg(i.name, ', ') into v_bad from industry_template_items i
   where i.template_key = 'insurance' and i.kind = 'gl_account'
     and not exists (select 1 from gl_accounts a
                      where a.tenant_id = t_ins and a.account_code = i.name
                        and a.name = i.payload ->> 'name'
                        and a.account_type = i.payload ->> 'account_type'
                        and a.is_control_account = coalesce((i.payload ->> 'is_control_account')::boolean, false));
  perform pg_temp.assert(v_bad is null, 'accounts differing from the template: ' || coalesce(v_bad, ''));

  select string_agg(i.name, ', ') into v_bad from industry_template_items i
   where i.template_key = 'insurance' and i.kind = 'posting_rule'
     and not exists (select 1 from gl_posting_rules r join gl_accounts a on a.id = r.gl_account_id
                      where r.tenant_id = t_ins and r.account_role = i.name
                        and a.account_code = i.payload ->> 'account_code');
  perform pg_temp.assert(v_bad is null, 'posting rules differing from the template: ' || coalesce(v_bad, ''));

  perform pg_temp.assert(
    (select array_agg(account_role order by account_role) from gl_posting_rules where tenant_id = t_ins)
      is not distinct from (select array_agg(r order by r) from unnest(platform_gl_posting_roles()) r),
    'the tenant does not have a rule for every platform posting role');

  -- 1e. Client money stays on the balance sheet, off income.
  perform pg_temp.assert(
    (select account_type from gl_accounts where tenant_id = t_ins and account_code = '1020') = 'asset'
    and (select account_type from gl_accounts where tenant_id = t_ins and account_code = '2010') = 'liability',
    'client money must be asset 1020 / liability 2010');
  perform pg_temp.assert(
    (select a.account_code from gl_posting_rules r join gl_accounts a on a.id = r.gl_account_id
      where r.tenant_id = t_ins and r.account_role = 'commission_income') = '4000'
    and (select count(*) from gl_posting_rules r join gl_accounts a on a.id = r.gl_account_id
          where r.tenant_id = t_ins and a.account_type = 'revenue') = 2,
    'only commission income (4000) and brokerage fees (4100) may be revenue accounts');
end $$;

-- ---------------------------------------------------------------------
-- 3. Seeding again adds nothing
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('admin');
select seed_tenant_defaults(pg_temp.tid('t_ins'), 'insurance');
reset role;

do $$
begin
  perform pg_temp.assert(pg_temp.counts(pg_temp.tid('t_ins')) = (select v from snap where k = 'first'),
    'a second seed_tenant_defaults changed the tenant: '
      || pg_temp.counts(pg_temp.tid('t_ins'))::text || ' vs ' || (select v from snap where k = 'first')::text);
end $$;

-- ---------------------------------------------------------------------
-- Users and data for the access checks (as owner; the tenant now exists)
-- ---------------------------------------------------------------------
do $$
declare
  t_ins uuid := pg_temp.tid('t_ins');
  v_mod text;
begin
  insert into staff_roles (tenant_id, user_id, module, role) values
    (t_ins, pg_temp.tid('cadm'), 'insurance', 'admin'),
    (t_ins, pg_temp.tid('im'),   'insurance', 'member'),
    (t_ins, pg_temp.tid('hr'),   'hr',        'member');

  insert into finance_team_members (tenant_id, user_id, role) values (t_ins, pg_temp.tid('fin'), 'finance');

  -- Stale or mis-granted roles on modules this tenant does not own. has_module_role()
  -- must still say no, because tenant_modules is the first gate.
  foreach v_mod in array array['pmo', 'machine_operation', 'sustainability', 'bd', 'procurement'] loop
    insert into staff_roles (tenant_id, user_id, module, role) values (t_ins, pg_temp.tid('rogue'), v_mod, 'admin');
  end loop;

  -- Rows in the denied modules, inside the insurance tenant itself.
  insert into pmo_projects (tenant_id, project_no, name) values (t_ins, 'INS-001', 'Hidden Project');
  insert into machines (tenant_id, machine_no, name) values (t_ins, 'INS-M1', 'Hidden Machine');
  insert into sustainability_certifications (tenant_id, name) values (t_ins, 'Hidden Certification');
  -- bd_opportunities.stage defaults to 'identification' and has a composite FK to
  -- bd_opportunity_stages(tenant_id, stage). An insurance tenant does not own the bd
  -- module, so seeding gives it no stage rows; add the default one here (as owner)
  -- so the hidden row can exist for the denial checks below.
  insert into bd_opportunity_stages (tenant_id, stage, label, probability_default, order_index) values
    (t_ins, 'identification', 'Identification', 10, 1);
  insert into bd_opportunities (tenant_id, title) values (t_ins, 'Hidden Opportunity');
end $$;

-- ---------------------------------------------------------------------
-- 4. Denial: the user with stale roles on modules the tenant does not own
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('rogue');
do $$
declare
  t_ins uuid := pg_temp.tid('t_ins');
  v_mod text;
begin
  foreach v_mod in array array['pmo', 'machine_operation', 'sustainability', 'bd', 'procurement'] loop
    perform pg_temp.assert(not has_module_role(v_mod, array['admin', 'manager', 'member']),
      format('has_module_role(%s) is true in an insurance tenant', v_mod));
  end loop;

  perform pg_temp.assert((select count(*) from pmo_projects) = 0, 'insurance user reads pmo_projects');
  perform pg_temp.assert((select count(*) from machines) = 0, 'insurance user reads machines');
  perform pg_temp.assert((select count(*) from sustainability_certifications) = 0, 'insurance user reads sustainability_certifications');
  perform pg_temp.assert((select count(*) from bd_opportunities) = 0, 'insurance user reads bd_opportunities');

  perform pg_temp.expect_denied('pmo write',
    format('insert into pmo_projects (tenant_id, project_no, name) values (%L, %L, %L)', t_ins, 'INS-002', 'Nope'));
  perform pg_temp.expect_denied('machines write',
    format('insert into machines (tenant_id, machine_no, name) values (%L, %L, %L)', t_ins, 'INS-M2', 'Nope'));
  perform pg_temp.expect_denied('sustainability write',
    format('insert into sustainability_certifications (tenant_id, name) values (%L, %L)', t_ins, 'Nope'));
  perform pg_temp.expect_denied('bd write',
    format('insert into bd_opportunities (tenant_id, title) values (%L, %L)', t_ins, 'Nope'));
end $$;
reset role;

-- Control: the same probe succeeds where the module IS owned.
set local role authenticated;
select pg_temp.become('ctl');
do $$
begin
  perform pg_temp.assert(has_module_role('pmo', array['member']), 'control: pmo member should pass has_module_role');
  perform pg_temp.assert((select count(*) from pmo_projects) = 1,
    'control: pmo member should see exactly their own tenant''s project (probe would be vacuous otherwise)');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 5. Access: who reaches what inside the insurance tenant
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('cadm');
do $$
begin
  perform pg_temp.assert(has_module_role('insurance', array['admin']), 'company admin should hold insurance admin');
  perform pg_temp.assert(can_access_client_master() and can_manage_client_master(), 'insurance admin should reach and manage the client master');
  perform pg_temp.assert(not has_module_role('pmo', array['admin', 'manager', 'member']), 'company admin must not get pmo');
  perform pg_temp.assert(not has_module_role('bd', array['admin', 'manager', 'member']), 'company admin must not get bd');
end $$;
reset role;

set local role authenticated;
select pg_temp.become('im');
do $$
begin
  perform pg_temp.assert(can_access_client_master(), 'insurance member should reach the client master');
  perform pg_temp.assert(not can_manage_client_master(), 'insurance member must not manage client master lookups');
end $$;
reset role;

set local role authenticated;
select pg_temp.become('hr');
do $$
begin
  perform pg_temp.assert(has_module_role('hr', array['member']), 'hr member should hold hr');
  perform pg_temp.assert(not can_access_client_master(), 'an hr-only user must not reach the client master');
  perform pg_temp.assert(not has_module_role('insurance', array['admin', 'manager', 'member']), 'hr-only user must not hold insurance');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 6. Seam 7: finance staff do not need the PO workflow
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('fin');
do $$
begin
  perform pg_temp.assert(is_finance_team_member(), 'finance user should be a finance team member');
  perform pg_temp.assert(not has_po_access(), 'finance user in an insurance tenant must not need or hold PO access');
  perform pg_temp.assert((select count(*) from gl_accounts) = 18, 'finance user should read the 18-account chart');
  perform pg_temp.assert((select count(*) from gl_posting_rules) = 18, 'finance user should read the 18 posting rules');
  perform pg_temp.assert(not can_access_client_master(), 'finance-only user must not reach the client master');
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 7. Tenant isolation: an insurance user sees none of the control tenant's data
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('im');
do $$
begin
  perform pg_temp.assert((select count(*) from pmo_projects where tenant_id = pg_temp.tid('t_ctl')) = 0,
    'insurance user sees the control tenant''s pmo project');
  perform pg_temp.assert((select count(*) from gl_accounts where tenant_id = pg_temp.tid('t_ctl')) = 0,
    'insurance user sees the control tenant''s chart');
end $$;
reset role;

rollback;