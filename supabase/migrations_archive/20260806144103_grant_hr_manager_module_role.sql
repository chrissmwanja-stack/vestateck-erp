insert into public.staff_roles (tenant_id, user_id, module, role)
select '00000000-0000-0000-0000-000000000001', '53665127-5662-442b-bf63-92e930ff40ef', 'hr', 'manager'
where not exists (
  select 1 from public.staff_roles
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and user_id = '53665127-5662-442b-bf63-92e930ff40ef'
    and module = 'hr'
    and role = 'manager'
);
