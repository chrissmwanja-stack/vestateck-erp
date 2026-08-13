-- 0003_seed_missing_stage_test_users.sql
--
-- Cost Control Engineer and Procurement: Offer Entry currently have no
-- approval_assignments holder, so nothing can move past stage 1 and the
-- new submit-offer function can't be tested end-to-end. Seeds one test
-- user per stage, following the same pattern as the existing 3 test
-- accounts (direct auth.users insert, no admin API).
--
-- Test password for both: Tester123
--
-- IDs pinned to what's actually live (833c98a7.../691b759e...) instead of
-- gen_random_uuid(). The random version meant a fresh shadow replay could
-- never reproduce the same user IDs as production, so anything created
-- later that references these two users by ID (e.g. requests seeded in
-- 20260803100235_seed_request_line_items_for_testing.sql) would hit a FK
-- violation against a shadow db that has the "wrong" random users.
-- auth.users enforces a unique email, so this must replace the random
-- insert rather than add a second row alongside it.

do $$
declare
  v_tenant_id uuid;
  v_cce_user_id uuid := '833c98a7-31fc-4636-8f47-ed9b7cfbd52b';
  v_proc_user_id uuid := '691b759e-6355-4736-b5da-525836ab2bd8';
begin
  select id into v_tenant_id from tenants limit 1;

  -- Cost Control Engineer
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
  values (
    v_tenant_id, v_cce_user_id, '00000000-0000-0000-0000-000000000030', 'global', null
  )
  on conflict do nothing;

  -- Procurement: Offer Entry
  if not exists (select 1 from auth.users where id = v_proc_user_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_proc_user_id, 'authenticated', 'authenticated',
      'procurement.offer@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
      '2026-07-30 15:03:09.838892+00', '{"provider":"email","providers":["email"]}', '{}',
      '2026-07-30 15:03:09.838892+00', '2026-07-30 15:03:09.838892+00', '', ''
    );
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title, created_at)
  values (
    v_proc_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000011',
    'Test Procurement Offer Entry', 'procurement.offer@test.local', 'Procurement/Logistics Expert', '2026-07-30 15:03:09.838892+00'
  )
  on conflict (id) do nothing;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (
    v_tenant_id, v_proc_user_id, '00000000-0000-0000-0000-000000000032', 'global', null
  )
  on conflict do nothing;
end $$;