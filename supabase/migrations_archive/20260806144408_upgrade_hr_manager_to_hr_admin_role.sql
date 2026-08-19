update public.staff_roles
set role = 'admin'
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and user_id = '53665127-5662-442b-bf63-92e930ff40ef'
  and module = 'hr';
