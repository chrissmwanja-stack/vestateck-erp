insert into public.app_users (id, tenant_id, department_id, name, email, role_title, is_platform_admin)
values
  ('c50dcbbf-78af-4582-b215-499f83ea47f0', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000014', 'Test IT Manager', 'it@test.local', 'IT Manager', true),
  ('53665127-5662-442b-bf63-92e930ff40ef', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000015', 'Test HR Manager', 'hr@test.local', 'HR Manager', false)
on conflict (id) do update set
  department_id = excluded.department_id,
  role_title = excluded.role_title,
  is_platform_admin = excluded.is_platform_admin;
