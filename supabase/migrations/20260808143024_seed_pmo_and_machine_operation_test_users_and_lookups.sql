-- PMO and Machine Operation tables/RLS already exist (pmo_and_machine_operation_schema
-- + part2), but no one holds the 'pmo' or 'machine_operation' module role, so every
-- write screen (New Project, Equipment, admin lookups, logs) would hit an RLS
-- violation on first use -- same gap pattern as finance_team_members earlier.
-- Same pattern as existing test users (direct auth.users insert, no admin API).
-- Test password for both: Tester123

do $$
declare
  v_tenant_id uuid;
  v_pmo_user_id uuid;
  v_machine_user_id uuid;
begin
  select id into v_tenant_id from tenants limit 1;

  -- PMO admin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'pmo@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  )
  returning id into v_pmo_user_id;

  insert into app_users (id, tenant_id, name, email, role_title)
  values (v_pmo_user_id, v_tenant_id, 'Test PMO Admin', 'pmo@test.local', 'PMO Manager');

  insert into staff_roles (tenant_id, user_id, module, role)
  values (v_tenant_id, v_pmo_user_id, 'pmo', 'admin');

  -- Machine Operation admin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'machine.ops@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  )
  returning id into v_machine_user_id;

  insert into app_users (id, tenant_id, name, email, role_title)
  values (v_machine_user_id, v_tenant_id, 'Test Machine Ops Admin', 'machine.ops@test.local', 'Machine Operations Manager');

  insert into staff_roles (tenant_id, user_id, module, role)
  values (v_tenant_id, v_machine_user_id, 'machine_operation', 'admin');

  -- Starter lookup data, matching the empty-state hints already in the UI copy
  insert into pmo_project_categories (tenant_id, name) values
    (v_tenant_id, 'Infrastructure'), (v_tenant_id, 'Building'),
    (v_tenant_id, 'Road'), (v_tenant_id, 'Water');

  insert into pmo_task_types (tenant_id, name) values
    (v_tenant_id, 'Design'), (v_tenant_id, 'Procurement'),
    (v_tenant_id, 'Construction'), (v_tenant_id, 'Inspection');

  insert into machine_types (tenant_id, name) values
    (v_tenant_id, 'Excavator'), (v_tenant_id, 'Bulldozer'),
    (v_tenant_id, 'Crane'), (v_tenant_id, 'Dump Truck');

  insert into maintenance_types (tenant_id, name) values
    (v_tenant_id, 'Preventive'), (v_tenant_id, 'Corrective'), (v_tenant_id, 'Inspection');
end $$;