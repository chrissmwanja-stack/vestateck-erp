-- Canonical local/dev test roster for the Test Construction Co tenant
-- (00000000-0000-0000-0000-000000000001).
--
-- Runs automatically after migrations on `supabase db reset`. Idempotent:
-- every insert is `on conflict do nothing`, so it is safe to run against
-- a database that already has some or all of this roster from the
-- migration history (0001_init_core_schema.sql,
-- 20260730143728_seed_missing_stage_test_users.sql,
-- 20260806143936_seed_it_hr_test_auth_users.sql +
-- 20260806143937_add_it_platform_admin_and_hr_manager.sql,
-- 20260808143024_seed_pmo_and_machine_operation_test_users_and_lookups.sql).
--
-- Per Foundation Playbook Phase 0: this file is the target for *all new*
-- demo/seed data from now on. Nothing here should ever be duplicated into
-- a migration again (see MIGRATION_POLICY.md, rule 2).
--
-- Password for every account below: Tester123
--
-- Why gm@test.local and pm@test.local are seeded here and not just left
-- to the migrations that already seed the other 9 accounts: neither one
-- is created by ANY migration. Both exist only as rows created directly
-- in the live project's Auth panel and were never captured. Until this
-- file, a fresh `supabase db reset` produced 9 of the 11 documented test
-- accounts -- the two missing ones are the only holders of the
-- high-threshold branch of the workflow (Chief -> Project Manager ->
-- Deputy GM -> Finance), so that branch had no way to be walked
-- end-to-end on a fresh replay. IDs below are pinned to what is live on
-- the dev project today, matching the existing pattern (see the
-- 20260730143728 migration's note on why pinned IDs matter for replay
-- reproducibility) in case anything is added later that references them.

do $$
declare
  v_tenant_id uuid := '00000000-0000-0000-0000-000000000001';
  v_gm_user_id uuid := '8fb20874-6f74-4c58-bda5-5716c5396bfb';
  v_pm_user_id uuid := '792c28b4-a7cf-4936-b6d2-596e8a3bc1ef';
begin
  if not exists (select 1 from tenants where id = v_tenant_id) then
    raise notice 'seed.sql: test tenant % not found -- run migrations first (supabase db reset runs this file automatically after migrations, so seeing this notice outside that flow usually means migrations have not been applied yet).', v_tenant_id;
    return;
  end if;

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
  values (v_gm_user_id, v_tenant_id, 'Test General Manager', 'gm@test.local', 'Deputy General Manager')
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
