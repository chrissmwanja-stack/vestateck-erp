-- 0003_seed_missing_stage_test_users.sql
--
-- Cost Control Engineer and Procurement: Offer Entry currently have no
-- approval_assignments holder, so nothing can move past stage 1 and the
-- new submit-offer function can't be tested end-to-end. Seeds one test
-- user per stage, following the same pattern as the existing 3 test
-- accounts (direct auth.users insert, no admin API).
--
-- Test password for both: Tester123

do $$
declare
  v_tenant_id uuid;
  v_cce_user_id uuid;
  v_proc_user_id uuid;
begin
  select id into v_tenant_id from tenants limit 1;

  -- Cost Control Engineer
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'cce@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  )
  returning id into v_cce_user_id;

  insert into app_users (id, tenant_id, department_id, name, email, role_title)
  values (
    v_cce_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000010',
    'Test Cost Control Engineer', 'cce@test.local', 'Cost Control Engineer'
  );

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (
    v_tenant_id, v_cce_user_id, '00000000-0000-0000-0000-000000000030', 'global', null
  );

  -- Procurement: Offer Entry
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'procurement.offer@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  )
  returning id into v_proc_user_id;

  insert into app_users (id, tenant_id, department_id, name, email, role_title)
  values (
    v_proc_user_id, v_tenant_id, '00000000-0000-0000-0000-000000000011',
    'Test Procurement Offer Entry', 'procurement.offer@test.local', 'Procurement/Logistics Expert'
  );

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
  values (
    v_tenant_id, v_proc_user_id, '00000000-0000-0000-0000-000000000032', 'global', null
  );
end $$;