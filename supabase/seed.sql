-- Canonical local/dev test roster for the Test Construction Co tenant
-- (00000000-0000-0000-0000-000000000001).
--
-- *** LOCAL ONLY. NEVER apply this file to the linked/remote project ***
-- (`supabase db reset --linked`, or hand-running this against production
-- via psql/Studio). The password below is public (this repo is public),
-- and once a real tenant's data lives in this project, seeding these
-- accounts there hands out live logins. `supabase db reset` without
-- `--linked` only touches your local Postgres container -- that's the
-- only safe way to run this file.
--
-- Runs automatically after migrations on `supabase db reset`. Idempotent:
-- every insert is `on conflict do nothing` (or an equivalent existence
-- check), so it is safe to run against a database that already has some
-- or all of this roster.
--
-- Per Foundation Playbook Phase 0: this file is the target for *all new*
-- demo/seed data from now on. Nothing here should ever be duplicated into
-- a migration again (see MIGRATION_POLICY.md, rule 2).
--
-- Password for every account below: Tester123
--
-- Every auth.users insert below explicitly sets email_change,
-- email_change_token_new, email_change_token_current, phone_change,
-- phone_change_token, and reauthentication_token to '' (alongside the
-- pre-existing confirmation_token/recovery_token). GoTrue's Go code scans
-- these columns as non-nullable strings; leaving them at their actual
-- Postgres default (NULL) makes every login for a hand-seeded user fail
-- with a 500 ("error finding user: sql: Scan error ... converting NULL
-- to string is unsupported"), even though the user row itself looks
-- completely normal in the DB. This never surfaced before because
-- nothing exercised real GoTrue login end-to-end until the Playwright
-- e2e specs (everything else mocks supabase-js).
--
-- *** Why this file now creates the tenant/departments/workflow_stages
-- itself, instead of assuming they already exist ***
--
-- All of the following used to exist as migrations, but every one of
-- them ended up in supabase/migrations_archive/ (excluded from fresh
-- replay) rather than supabase/migrations/ -- either because they
-- predated the Aug 19, 2026 migration squash and their content never
-- made it into the squashed baseline (0001_init_core_schema.sql,
-- 20260815075105_tenant_module_entitlements.sql), or because the row
-- they inserted was created directly in the live project's Auth panel
-- and never captured by any migration at all
-- (20260806143936_seed_it_hr_test_auth_users.sql). The practical effect
-- was the same either way: on a truly fresh replay (CI's
-- db-shadow-replay job, local `supabase db reset`, or `create_branch`),
-- NONE of this existed -- not just the tenant itself, but every
-- department, workflow stage, module entitlement, and test account
-- below. seed.sql's own tenant-creation logic used to just check
-- `if not exists (select 1 from tenants where id = ...) then raise
-- notice ... return;` -- so the whole file quietly no-op'd on every
-- fresh replay, visible only as an easy-to-miss NOTICE in the log.
-- 9 of the (now) 11 documented test accounts were never actually
-- reachable in CI or on a fresh local reset until this fix.
--
-- IDs throughout are pinned to what is (or, for pmo@test.local and
-- machine.ops@test.local, newly assigned here since the original
-- migration used gen_random_uuid() and pinned nothing) live on the dev
-- project today, matching the existing pattern -- see the 20260730143728
-- migration's note on why pinned IDs matter for replay reproducibility,
-- in case anything is added later that references them.
--
-- Note on the workflow_stages names/flags below: the canonical tenant
-- does not currently exist on the live/linked project either, so there
-- was nothing to snapshot and cross-check this against directly.
-- 20260731124853_realign_workflow_stages_to_target_flow.sql (the last
-- migration found in the archive that touches these specific stage
-- IDs) is applied on top of the original 0001 shape below, but earlier
-- archived migrations were not individually re-traced beyond that --
-- if the live/intended workflow shape has moved further since, this
-- will need a follow-up correction.

-- ============================================================================
-- 1. Tenant, departments, and the procurement approval-chain workflow
--    stages. Ported verbatim (same pinned IDs) from the archived
--    0001_init_core_schema.sql, which is exactly what a fresh replay
--    was missing.
-- ============================================================================
insert into tenants (id, name, industry_template, created_at) values
  ('00000000-0000-0000-0000-000000000001', 'Test Construction Co', 'construction', '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

-- trg_set_department_defaults (BEFORE INSERT) unconditionally overwrites
-- NEW.tenant_id via get_my_tenant_id() and raises 'could not determine
-- tenant_id for current user' if that resolves to null -- and at this
-- point in the file no app_users row exists for ANY user in this tenant
-- yet (the tenant itself was only just created above), so there is no
-- auth context to impersonate our way out of, unlike organizations/
-- cost_centers below where a real tenant member already exists by the
-- time those fixtures run. Disable the trigger for this one insert only;
-- the explicit tenant_id values above are exactly what it would have
-- set anyway.
alter table departments disable trigger trg_set_department_defaults;

insert into departments (id, tenant_id, name, created_at) values
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'Cost Control', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'Procurement & Logistics', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', 'Finance & Financial Reporting', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', 'Project Management Office', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000001', 'IT Support', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000001', 'Human Resources', '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

alter table departments enable trigger trg_set_department_defaults;

-- Workflow stages, original shape. next_stage_low_id/next_stage_high_id are
-- backfilled via UPDATE afterward, same as the original, purely to
-- sidestep self-referencing forward-reference ordering.
insert into workflow_stages (id, tenant_id, name, sequence_order, approver_role, threshold_amount, created_at) values
  ('00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000001', 'Cost Control Engineer', 1, 'Cost Control Engineer', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000001', 'Cost Control Manager', 2, 'Cost Control Manager', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000001', 'Procurement: Offer Entry', 3, 'Procurement/Logistics Expert', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000033', '00000000-0000-0000-0000-000000000001', 'Control Chief/Manager', 4, 'Procurement & Logistics Chief', 5000000.00, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000034', '00000000-0000-0000-0000-000000000001', 'Finance', 5, 'Finance Officer', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-000000000001', 'Project Manager', 6, 'Project Manager', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000036', '00000000-0000-0000-0000-000000000001', 'Deputy General Manager', 7, 'Deputy General Manager', null, '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000031' where id = '00000000-0000-0000-0000-000000000030';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000032' where id = '00000000-0000-0000-0000-000000000031';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000033' where id = '00000000-0000-0000-0000-000000000032';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000034', next_stage_high_id = '00000000-0000-0000-0000-000000000035' where id = '00000000-0000-0000-0000-000000000033';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000036' where id = '00000000-0000-0000-0000-000000000035';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000034' where id = '00000000-0000-0000-0000-000000000036';

-- Post-creation realignment, ported from the archived
-- 20260731124853_realign_workflow_stages_to_target_flow.sql: two of
-- the seven stages were renamed and re-flagged after the original
-- 0001 creation, and this is the last such change found in the
-- archive that touches these specific stage IDs. Applied as an
-- UPDATE (matching how the original migration did it) rather than
-- folded into the INSERT above, so the provenance of each change
-- stays traceable to its source migration.
update workflow_stages set name = 'Budget Controller', blocks_offer_submitter_approval = true
where id = '00000000-0000-0000-0000-000000000033'; -- was "Control Chief/Manager"
update workflow_stages set name = 'General Manager'
where id = '00000000-0000-0000-0000-000000000036'; -- was "Deputy General Manager"
update workflow_stages set is_finance_terminal_stage = true
where id = '00000000-0000-0000-0000-000000000034'; -- Finance
-- Offer-flow behavior flags. Both default to false and both are load-bearing:
-- requires_offer_entry (...032) gates the /offers/entry queue filter and the
-- request_offers insert RLS; requires_offer_selection (...033) gates whether
-- OfferApprovalPO.tsx's winner-picker radio group renders at all -- without
-- it the Chief's approval dialog never shows offers to choose between.
update workflow_stages set requires_offer_entry = true
where id = '00000000-0000-0000-0000-000000000032'; -- Procurement: Offer Entry
update workflow_stages set requires_offer_selection = true
where id = '00000000-0000-0000-0000-000000000033'; -- Budget Controller

-- Module entitlements. Ported from the archived
-- 20260815075105_tenant_module_entitlements.sql's "every existing
-- tenant keeps full access to every module it already effectively
-- had" backfill -- scoped here to just this one tenant, since that
-- backfill (like everything else in this file) never runs on a fresh
-- replay. Needed for has_module_role() to grant access to the
-- non-platform-admin module accounts below (hr@test.local,
-- pmo@test.local, machine.ops@test.local).
insert into tenant_modules (tenant_id, module)
select '00000000-0000-0000-0000-000000000001', m.module
from (values ('hr'), ('legal'), ('bd'), ('it'), ('pmo'),
             ('machine_operation'), ('sustainability'), ('procurement')) as m(module)
on conflict (tenant_id, module) do nothing;

-- Finance/procurement lookup data: organizations, cost centers, a vendor
-- account, PAYE/NSSF statutory rates, and demo catalog materials. These
-- used to be referenced by a comment above ("cost_centers below
-- where a real tenant member already exists") that implied fixtures for
-- them existed in this file -- they never actually landed, so every
-- Autocomplete backed by these three tables (Supplier Invoice,
-- Request Submission, etc.) has been silently empty on a fresh replay.
-- These inserts run before the seeded app_users rows exist. Their default
-- triggers derive tenant_id from auth.uid(), so preserve the explicit seed
-- tenant while loading this bootstrap data.
alter table organizations disable trigger trg_set_organization_defaults;
alter table cost_centers disable trigger trg_set_cost_center_defaults;

insert into organizations (id, tenant_id, company_code, site_name) values
  ('00000000-0000-0000-0000-000000000040', '00000000-0000-0000-0000-000000000001', 'HQ', 'Head Office')
on conflict (id) do nothing;

insert into cost_centers (id, tenant_id, name, project_code, budget_amount) values
  ('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000001', 'Head Office', 'HQ-001', 50000000.00),
  ('00000000-0000-0000-0000-000000000042', '00000000-0000-0000-0000-000000000001', 'Site A', 'STA-001', 20000000.00)
on conflict (id) do nothing;

alter table organizations enable trigger trg_set_organization_defaults;
alter table cost_centers enable trigger trg_set_cost_center_defaults;

insert into accounts (id, tenant_id, account_code, name, account_type, is_active) values
  ('00000000-0000-0000-0000-000000000043', '00000000-0000-0000-0000-000000000001', 'VEND-001', 'Test Vendor Ltd', 'vendor', true)
on conflict (id) do nothing;

-- PAYE/NSSF rate table for the demo tenant, so payroll generation
-- computes real statutory deductions instead of zeros. Same 4-band
-- PAYE schedule seed_statutory_rate_table() ships and the payroll
-- SQL tests use (see test_payroll_generation.sql / test_statutory_
-- deductions.sql headers: reasonable for test fixtures, unconfirmed
-- against URA). statutory_rate_tables has no unique constraint, so
-- idempotency is delete-then-insert scoped to this tenant + date.
-- Effective current_date - 60 keeps the rows in force for any run
-- period from the current month on (generate_payroll_items computes
-- deductions as of current_date).
delete from statutory_rate_tables
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and effective_date = current_date - 60;

insert into statutory_rate_tables (tenant_id, rate_type, effective_date, band_order, lower_bound, upper_bound, rate, base_tax) values
  ('00000000-0000-0000-0000-000000000001', 'paye', current_date - 60, 1, 0, 335000, 0, 0),
  ('00000000-0000-0000-0000-000000000001', 'paye', current_date - 60, 2, 335000, 410000, 10, 0),
  ('00000000-0000-0000-0000-000000000001', 'paye', current_date - 60, 3, 410000, 10000000, 20, 7500),
  ('00000000-0000-0000-0000-000000000001', 'paye', current_date - 60, 4, 10000000, null, 30, 1927500),
  ('00000000-0000-0000-0000-000000000001', 'nssf_employee', current_date - 60, 1, 0, null, 5, 0),
  ('00000000-0000-0000-0000-000000000001', 'nssf_employer', current_date - 60, 1, 0, null, 10, 0);

-- A few demo catalog materials for the Test Construction Co tenant, so
-- the procurement request form's "Type or pick from catalog"
-- freeSolo picker has real suggestions (and MaterialCatalogAdmin has
-- rows to show). material_catalog carries no BEFORE INSERT trigger --
-- the client resolves tenant_id itself (see
-- 20260822120000_material_catalog_insert_policy.sql) -- so these
-- inserts are safe under the seed's postgres role. material_type_id /
-- material_group_id stay NULL; the join in the request form tolerates
-- that.
insert into material_catalog (id, tenant_id, name, code, unit, is_active) values
  ('00000000-0000-0000-0000-000000000044', '00000000-0000-0000-0000-000000000001', 'Portland Cement (50kg bag)', 'MAT-CEM-001', 'Bag', true),
  ('00000000-0000-0000-0000-000000000045', '00000000-0000-0000-0000-000000000001', 'Reinforcing Steel Bar 12mm (per m)', 'MAT-STL-012', 'm', true),
  ('00000000-0000-0000-0000-000000000046', '00000000-0000-0000-0000-000000000001', 'River Sand (per trip)', 'MAT-SND-001', 'Trip', true)
on conflict (id) do nothing;

-- ============================================================================
-- 2. The other 9 documented test accounts. Ported from the archived
--    migrations named in the header above -- same pinned IDs (or,
--    for pmo/machine.ops, newly pinned here) and same
--    auth.users/app_users/approval_assignments|staff_roles pattern.
-- ============================================================================
do $$
declare
  v_tenant_id uuid := '00000000-0000-0000-0000-000000000001';
  v_cost_control_user_id uuid := 'b93bd287-c359-44cc-a7a6-2dd1578b06ee';
  v_finance_user_id uuid := 'ed9cd87d-7649-486c-958b-36114271a0b2';
  v_procurement_user_id uuid := '6cb314bb-c39e-40e2-aca9-446e12a1795f';
  v_cce_user_id uuid := '833c98a7-31fc-4636-8f47-ed9b7cfbd52b';
  v_proc_offer_user_id uuid := '691b759e-6355-4736-b5da-525836ab2bd8';
  v_it_user_id uuid := 'c50dcbbf-78af-4582-b215-499f83ea47f0';
  v_hr_user_id uuid := '53665127-5662-442b-bf63-92e930ff40ef';
  v_pmo_user_id uuid := '87b890d6-27b7-4ca9-9a96-41906881037d';
  v_machine_user_id uuid := 'b98b4fe4-2a3e-49ec-8e71-7704c9eef640';
  v_emp1 uuid;
  v_emp2 uuid;
begin
  -- Cost Control Manager, Finance Officer, Procurement & Logistics Chief
  -- (the three original test accounts).
  if not exists (select 1 from auth.users where id = v_cost_control_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values
    ('00000000-0000-0000-0000-000000000000', v_cost_control_user_id, 'authenticated', 'authenticated',
     'cost.control@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', '', '', '', '', '', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_finance_user_id, 'authenticated', 'authenticated',
     'finance@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', '', '', '', '', '', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_procurement_user_id, 'authenticated', 'authenticated',
     'procurement@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', '', '', '', '', '', '', '');
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title, created_at) values
    (v_cost_control_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000010', 'Test Cost Controller', 'cost.control@test.local', 'Cost Control Manager', '2026-07-30 11:30:48.602762+00'),
    (v_finance_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000012', 'Test Finance Officer', 'finance@test.local', 'Finance Officer', '2026-07-30 11:30:48.602762+00'),
    (v_procurement_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000011', 'Test Procurement Lead', 'procurement@test.local', 'Procurement & Logistics Chief', '2026-07-30 11:30:48.602762+00')
  on conflict (id) do nothing;

  -- finance@test.local must be a finance team member, not just an
  -- app_user with a Finance role_title: the accounts/organizations/
  -- statutory_rate_tables RLS SELECT policies (and the finance write
  -- policies) all key off is_finance_team_member(), the same
  -- membership-table pattern as hr_team_members below. Without this
  -- row, finance@test.local sees an EMPTY accounts/organizations
  -- dropdown on the supplier-invoice screen even though the fixture
  -- rows above exist -- exactly what the e2e finance spec hits.
  insert into finance_team_members (tenant_id, user_id, role)
  values (v_tenant_id, v_finance_user_id, 'finance')
  on conflict (tenant_id, user_id, role) do nothing;

  -- procurement@test.local (Test Procurement Lead, "Procurement & Logistics
  -- Chief") had no assignment on the Budget Controller stage (...033) at
  -- all -- every other stage in this seed has one, this one was just
  -- missing. Without it, no user can act on that stage regardless of the
  -- requires_offer_selection flag above.
  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max, created_at) values
    (v_tenant_id, v_cost_control_user_id, '00000000-0000-0000-0000-000000000031', 'global', null, '2026-07-30 11:30:48.602762+00'),
    (v_tenant_id, v_finance_user_id, '00000000-0000-0000-0000-000000000034', 'global', null, '2026-07-30 11:30:48.602762+00'),
    (v_tenant_id, v_procurement_user_id, '00000000-0000-0000-0000-000000000033', 'global', null, '2026-07-30 11:30:48.602762+00')
  on conflict (tenant_id, user_id, workflow_stage_id) do nothing;

  -- Cost Control Engineer and Procurement: Offer Entry (the stage-gap
  -- accounts -- without these, nothing could move past workflow stage 1).
  if not exists (select 1 from auth.users where id = v_cce_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_cce_user_id, 'authenticated', 'authenticated',
      'cce@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      '2026-07-30 15:03:09.838892+00', '{"provider":"email","providers":["email"]}', '{}',
      '2026-07-30 15:03:09.838892+00', '2026-07-30 15:03:09.838892+00', '', '', '', '', '', '', '', ''
    );
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title, created_at)
  values (
    v_cce_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000010',
    'Test Cost Control Engineer', 'cce@test.local', 'Cost Control Engineer', '2026-07-30 15:03:09.838892+00'
  )
  on conflict (id) do nothing;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (v_tenant_id, v_cce_user_id, '00000000-0000-0000-0000-000000000030', 'global', null)
  on conflict (tenant_id, user_id, workflow_stage_id) do nothing;

  if not exists (select 1 from auth.users where id = v_proc_offer_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_proc_offer_user_id, 'authenticated', 'authenticated',
      'procurement.offer@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      '2026-07-30 15:03:09.838892+00', '{"provider":"email","providers":["email"]}', '{}',
      '2026-07-30 15:03:09.838892+00', '2026-07-30 15:03:09.838892+00', '', '', '', '', '', '', '', ''
    );
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title, created_at)
  values (
    v_proc_offer_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000011',
    'Test Procurement Offer Entry', 'procurement.offer@test.local', 'Procurement/Logistics Expert', '2026-07-30 15:03:09.838892+00'
  )
  on conflict (id) do nothing;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (v_tenant_id, v_proc_offer_user_id, '00000000-0000-0000-0000-000000000032', 'global', null)
  on conflict (tenant_id, user_id, workflow_stage_id) do nothing;

  -- IT Manager (platform admin) and HR Manager (hr module admin --
  -- final state after the manager-to-admin upgrade the archived
  -- migrations applied in two steps; seeded directly at that end state
  -- here since this file only needs to reproduce the outcome, not the
  -- history).
  if not exists (select 1 from auth.users where id = v_it_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values
    ('00000000-0000-0000-0000-000000000000', v_it_user_id, 'authenticated', 'authenticated',
     'it@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-08-06 14:39:37.733784+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-08-06 14:39:37.733784+00', '2026-08-06 14:39:37.733784+00', '', '', '', '', '', '', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_hr_user_id, 'authenticated', 'authenticated',
     'hr@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-08-06 14:39:37.733784+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-08-06 14:39:37.733784+00', '2026-08-06 14:39:37.733784+00', '', '', '', '', '', '', '', '');
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title)
  values
    (v_it_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000014', 'Test IT Manager', 'it@test.local', 'IT Manager'),
    (v_hr_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000015', 'Test HR Manager', 'hr@test.local', 'HR Manager')
  on conflict (id) do update set
    department_id = excluded.department_id,
    role_title = excluded.role_title;

  -- app_users_single_platform_admin is a partial unique index allowing
  -- at most ONE true row across the whole table (all tenants), not just
  -- this one -- so unconditionally setting it@test.local's is_platform_admin
  -- to true (as the insert above used to) raises a duplicate-key error
  -- the moment any other row already holds that flag: a branch cloned
  -- from data that already has a real platform admin, or simply re-running
  -- this file after it already succeeded once. Grant it here only if no
  -- *other* row currently holds the flag, and skip quietly otherwise --
  -- seed.sql needs to be safe to run against varying starting states, not
  -- just a truly empty database.
  update app_users
  set is_platform_admin = true
  where id = v_it_user_id
    and not exists (select 1 from app_users where is_platform_admin = true and id != v_it_user_id);

  insert into staff_roles (tenant_id, user_id, module, role)
  values (v_tenant_id, v_hr_user_id, 'hr', 'admin')
  on conflict (tenant_id, user_id, module) do nothing;

  -- is_hr_team_member() (used to gate Payroll's "New run" button, among
  -- other HR screens) checks hr_team_members, NOT staff_roles -- the two
  -- are separate membership patterns in this codebase (see the bd/it
  -- module RBAC unification note). The staff_roles row above alone does
  -- not make hr@test.local an HR team member; this insert does.
  insert into hr_team_members (tenant_id, user_id, role)
  values (v_tenant_id, v_hr_user_id, 'admin')
  on conflict (tenant_id, user_id) do nothing;

  -- Two demo employees with compensation records, mirroring the
  -- payroll SQL-test fixtures (test_payroll_generation.sql). Payroll's
  -- generate_payroll_items() pulls active employees joined to
  -- hr_employee_current_compensation -- with zero rows there, the e2e
  -- payroll spec's "generate items" step silently produces nothing
  -- (the run submits and approves, but there is no payroll behind it).
  -- generate_hr_employee_no() derives the number from NEW.tenant_id
  -- (no auth context needed), so these inserts are safe at this point
  -- in the file. employee emails are deliberately NOT @test.local
  -- login accounts -- these are just payrolled staff records.
  if not exists (select 1 from hr_employees where email = 'alice.anyanzwa@example.com') then
    insert into hr_employees (tenant_id, first_name, last_name, email, department_id, hire_date)
    values (v_tenant_id, 'Alice', 'Anyanzwa', 'alice.anyanzwa@example.com',
            '00000000-0000-0000-0000-000000000015', current_date - interval '1 year')
    returning id into v_emp1;
    insert into hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, created_by)
    values (v_tenant_id, v_emp1, 300000, current_date - 30, v_hr_user_id);
  end if;

  if not exists (select 1 from hr_employees where email = 'brian.byaruhanga@example.com') then
    insert into hr_employees (tenant_id, first_name, last_name, email, department_id, hire_date)
    values (v_tenant_id, 'Brian', 'Byaruhanga', 'brian.byaruhanga@example.com',
            '00000000-0000-0000-0000-000000000015', current_date - interval '1 year')
    returning id into v_emp2;
    insert into hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, created_by)
    values (v_tenant_id, v_emp2, 1200000, current_date - 30, v_hr_user_id);
  end if;

  -- PMO Manager and Machine Operations Manager, plus their starter
  -- lookup data, matching the empty-state hints already in the UI copy.
  if not exists (select 1 from auth.users where id = v_pmo_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values
    ('00000000-0000-0000-0000-000000000000', v_pmo_user_id, 'authenticated', 'authenticated',
     'pmo@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '', '', '', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_machine_user_id, 'authenticated', 'authenticated',
     'machine.ops@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '', '', '', '', '');
  end if;

  insert into app_users (id, tenant_id, name, email, role_title) values
    (v_pmo_user_id, v_tenant_id, 'Test PMO Admin', 'pmo@test.local', 'PMO Manager'),
    (v_machine_user_id, v_tenant_id, 'Test Machine Ops Admin', 'machine.ops@test.local', 'Machine Operations Manager')
  on conflict (id) do nothing;

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant_id, v_pmo_user_id, 'pmo', 'admin'),
    (v_tenant_id, v_machine_user_id, 'machine_operation', 'admin')
  on conflict (tenant_id, user_id, module) do nothing;

  insert into pmo_project_categories (tenant_id, name) values
    (v_tenant_id, 'Infrastructure'), (v_tenant_id, 'Building'),
    (v_tenant_id, 'Road'), (v_tenant_id, 'Water')
  on conflict (tenant_id, name) do nothing;

  insert into pmo_task_types (tenant_id, name) values
    (v_tenant_id, 'Design'), (v_tenant_id, 'Procurement'),
    (v_tenant_id, 'Construction'), (v_tenant_id, 'Inspection')
  on conflict (tenant_id, name) do nothing;

  insert into machine_types (tenant_id, name) values
    (v_tenant_id, 'Excavator'), (v_tenant_id, 'Bulldozer'),
    (v_tenant_id, 'Crane'), (v_tenant_id, 'Dump Truck')
  on conflict (tenant_id, name) do nothing;

  insert into maintenance_types (tenant_id, name) values
    (v_tenant_id, 'Preventive'), (v_tenant_id, 'Corrective'), (v_tenant_id, 'Inspection')
  on conflict (tenant_id, name) do nothing;
end $$;

-- ============================================================================
-- 3. Deputy General Manager and Project Manager (the high-threshold
--    approval branch: Chief -> Project Manager -> Deputy GM -> Finance).
--    These two were the only ones ever captured anywhere before this
--    file existed -- neither is created by any migration, archived or
--    otherwise. The tenant they depend on is now guaranteed to exist by
--    section 1 above, so the old "tenant not found, skip everything"
--    guard has been removed.
-- ============================================================================
do $$
declare
  v_tenant_id uuid := '00000000-0000-0000-0000-000000000001';
  v_gm_user_id uuid := '8fb20874-6f74-4c58-bda5-5716c5396bfb';
  v_pm_user_id uuid := '792c28b4-a7cf-4936-b6d2-596e8a3bc1ef';
begin
  -- Deputy General Manager (high-threshold approval terminal stage)
  if not exists (select 1 from auth.users where id = v_gm_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_gm_user_id, 'authenticated', 'authenticated',
      'gm@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '', '', '', '', ''
    );
  end if;

  insert into app_users (id, tenant_id, name, email, role_title)
  values (v_gm_user_id, v_tenant_id, 'Test General Manager', 'gm@test.local', 'General Manager')
  on conflict (id) do nothing;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (v_tenant_id, v_gm_user_id, '00000000-0000-0000-0000-000000000036', 'global', null)
  on conflict (tenant_id, user_id, workflow_stage_id) do nothing;

  -- Project Manager (high-threshold branch, stage before Deputy GM)
  if not exists (select 1 from auth.users where id = v_pm_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_pm_user_id, 'authenticated', 'authenticated',
      'pm@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '', '', '', '', ''
    );
  end if;

  insert into app_users (id, tenant_id, name, email, role_title)
  values (v_pm_user_id, v_tenant_id, 'Test Project Manager', 'pm@test.local', 'Project Manager')
  on conflict (id) do nothing;

  -- pm@test.local as a payroll approver so the payroll e2e spec can
  -- approve runs without a manual one-time grant in the UI. Payroll
  -- approval rights live in payroll_approvers (checked by
  -- is_payroll_approver()), a separate tier from staff_roles -- same
  -- pattern as hr_team_members/finance_team_members above. Role
  -- matches what grant_payroll_approver() inserts.
  insert into payroll_approvers (tenant_id, user_id, role, is_active)
  values (v_tenant_id, v_pm_user_id, 'approver', true)
  on conflict (tenant_id, user_id) do update set is_active = true;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (v_tenant_id, v_pm_user_id, '00000000-0000-0000-0000-000000000035', 'global', null)
  on conflict (tenant_id, user_id, workflow_stage_id) do nothing;

  -- is_payroll_approver() (gates approve_payroll_run/reject_payroll_run)
  -- checks payroll_approvers, which is a separate grant from the
  -- workflow-stage approval_assignments row above -- role_title alone
  -- does not make pm@test.local a payroll approver. Matches the row
  -- shape grant_payroll_approver() would insert (role='approver').
  -- Without this, e2e/payroll-disbursement.spec.ts's approval step fails
  -- with "nothing waiting on you" until an HR admin grants it manually
  -- via /hr/admin/payroll-approvers, per e2e/README.md.
  insert into payroll_approvers (tenant_id, user_id, role, is_active)
  values (v_tenant_id, v_pm_user_id, 'approver', true)
  on conflict (tenant_id, user_id) do nothing;
end $$;

-- Note on is_platform_admin for gm@test.local: the live project currently
-- has this false, even though 20260801132413_platform_admin_and_finance_team.sql
-- set it true when the platform-admin concept was introduced. This file
-- deliberately does not touch is_platform_admin on conflict, so it won't
-- fight whatever the current live/intended value is -- flagging this
-- drift for a human decision rather than guessing which one is correct.