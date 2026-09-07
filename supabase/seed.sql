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

insert into departments (id, tenant_id, name, created_at) values
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'Cost Control', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'Procurement & Logistics', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', 'Finance & Financial Reporting', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', 'Project Management Office', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000001', 'IT Support', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000001', 'Human Resources', '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

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
begin
  -- Cost Control Manager, Finance Officer, Procurement & Logistics Chief
  -- (the three original test accounts).
  if not exists (select 1 from auth.users where id = v_cost_control_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token
    ) values
    ('00000000-0000-0000-0000-000000000000', v_cost_control_user_id, 'authenticated', 'authenticated',
     'cost.control@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_finance_user_id, 'authenticated', 'authenticated',
     'finance@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_procurement_user_id, 'authenticated', 'authenticated',
     'procurement@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', '');
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title, created_at) values
    (v_cost_control_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000010', 'Test Cost Controller', 'cost.control@test.local', 'Cost Control Manager', '2026-07-30 11:30:48.602762+00'),
    (v_finance_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000012', 'Test Finance Officer', 'finance@test.local', 'Finance Officer', '2026-07-30 11:30:48.602762+00'),
    (v_procurement_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000011', 'Test Procurement Lead', 'procurement@test.local', 'Procurement & Logistics Chief', '2026-07-30 11:30:48.602762+00')
  on conflict (id) do nothing;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max, created_at) values
    (v_tenant_id, v_cost_control_user_id, '00000000-0000-0000-0000-000000000031', 'global', null, '2026-07-30 11:30:48.602762+00'),
    (v_tenant_id, v_finance_user_id, '00000000-0000-0000-0000-000000000034', 'global', null, '2026-07-30 11:30:48.602762+00')
  on conflict (tenant_id, user_id, workflow_stage_id) do nothing;

  -- Cost Control Engineer and Procurement: Offer Entry (the stage-gap
  -- accounts -- without these, nothing could move past workflow stage 1).
  if not exists (select 1 from auth.users where id = v_cce_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_cce_user_id, 'authenticated', 'authenticated',
      'cce@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      '2026-07-30 15:03:09.838892+00', '{"provider":"email","providers":["email"]}', '{}',
      '2026-07-30 15:03:09.838892+00', '2026-07-30 15:03:09.838892+00', '', ''
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
      created_at, updated_at, confirmation_token, recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_proc_offer_user_id, 'authenticated', 'authenticated',
      'procurement.offer@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      '2026-07-30 15:03:09.838892+00', '{"provider":"email","providers":["email"]}', '{}',
      '2026-07-30 15:03:09.838892+00', '2026-07-30 15:03:09.838892+00', '', ''
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
      created_at, updated_at, confirmation_token, recovery_token
    ) values
    ('00000000-0000-0000-0000-000000000000', v_it_user_id, 'authenticated', 'authenticated',
     'it@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-08-06 14:39:37.733784+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-08-06 14:39:37.733784+00', '2026-08-06 14:39:37.733784+00', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_hr_user_id, 'authenticated', 'authenticated',
     'hr@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-08-06 14:39:37.733784+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-08-06 14:39:37.733784+00', '2026-08-06 14:39:37.733784+00', '', '');
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title, is_platform_admin)
  values
    (v_it_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000014', 'Test IT Manager', 'it@test.local', 'IT Manager', true),
    (v_hr_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000015', 'Test HR Manager', 'hr@test.local', 'HR Manager', false)
  on conflict (id) do update set
    department_id = excluded.department_id,
    role_title = excluded.role_title,
    is_platform_admin = excluded.is_platform_admin;

  insert into staff_roles (tenant_id, user_id, module, role)
  values (v_tenant_id, v_hr_user_id, 'hr', 'admin')
  on conflict (tenant_id, user_id, module) do nothing;

  -- PMO Manager and Machine Operations Manager, plus their starter
  -- lookup data, matching the empty-state hints already in the UI copy.
  if not exists (select 1 from auth.users where id = v_pmo_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token
    ) values
    ('00000000-0000-0000-0000-000000000000', v_pmo_user_id, 'authenticated', 'authenticated',
     'pmo@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''),
    ('00000000-0000-0000-0000-000000000000', v_machine_user_id, 'authenticated', 'authenticated',
     'machine.ops@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '');
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
      created_at, updated_at, confirmation_token, recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_gm_user_id, 'authenticated', 'authenticated',
      'gm@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
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
      created_at, updated_at, confirmation_token, recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_pm_user_id, 'authenticated', 'authenticated',
      'pm@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    );
  end if;

  insert into app_users (id, tenant_id, name, email, role_title)
  values (v_pm_user_id, v_tenant_id, 'Test Project Manager', 'pm@test.local', 'Project Manager')
  on conflict (id) do nothing;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (v_tenant_id, v_pm_user_id, '00000000-0000-0000-0000-000000000035', 'global', null)
  on conflict (tenant_id, user_id, workflow_stage_id) do nothing;
end $$;

-- Note on is_platform_admin for gm@test.local: the live project currently
-- has this false, even though 20260801132413_platform_admin_and_finance_team.sql
-- set it true when the platform-admin concept was introduced. This file
-- deliberately does not touch is_platform_admin on conflict, so it won't
-- fight whatever the current live/intended value is -- flagging this
-- drift for a human decision rather than guessing which one is correct.
