-- Test tenant read_only guard
-- Verifies item 1 fix: tenant_read_only=true blocks writes for ordinary users,
-- allows platform_admin and service_role, allows notifications read marking

begin;

-- Setup: create test tenant and user
-- Use existing seed pattern: we are inside a transaction that will rollback
-- Create a dummy tenant
insert into public.tenants (id, name, status) values ('00000000-0000-0000-0000-0000000000aa', 'test-readonly-tenant', 'active')
on conflict (id) do update set status='active', read_only=false;

-- Create app_user for test (if not exists)
-- We need auth user, but we can simulate by setting request.jwt.claims and using get_my_tenant_id()
-- Instead test the guard function directly

-- Test 1: guard should allow when read_only=false
update public.tenants set read_only=false, read_only_reason=null where id='00000000-0000-0000-0000-0000000000aa';
-- Simulate authenticated request
-- platform_request_role() reads current_setting('request.jwt.claims') -> set it
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
-- Mock get_my_tenant_id to return our test tenant via app_users? 
-- For unit test of guard, we can directly test the function with NEW/OLD

-- Test guard logic directly: create a temp table with tenant_id and trigger
create temp table tmp_readonly_test (id uuid default gen_random_uuid() primary key, tenant_id uuid, name text);
create trigger tmp_readonly_guard before insert or update or delete on tmp_readonly_test
  for each row execute function public.tenant_read_only_guard();

-- Should succeed when read_only=false
insert into tmp_readonly_test (tenant_id, name) values ('00000000-0000-0000-0000-0000000000aa', 'should succeed');

-- Now set read_only=true
update public.tenants set read_only=true, read_only_reason='past due 60 days', read_only_since=now()
where id='00000000-0000-0000-0000-0000000000aa';

-- Should fail for authenticated ordinary user
do $$
begin
  begin
    insert into tmp_readonly_test (tenant_id, name) values ('00000000-0000-0000-0000-0000000000aa', 'should fail');
    raise exception 'FAIL: insert succeeded despite read_only=true';
  exception when insufficient_privilege then
    -- expected TENANT_READ_ONLY
    if sqlerrm not like 'TENANT_READ_ONLY:%' then
      raise exception 'FAIL: wrong error message: %', sqlerrm;
    end if;
    -- ok
  end;
end $$;

-- Should succeed for platform_admin (bypass)
-- Simulate platform admin: need app_users.is_platform_admin=true for auth.uid()
-- For test, we set platform_request_role to service_role (bypass)
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into tmp_readonly_test (tenant_id, name) values ('00000000-0000-0000-0000-0000000000aa', 'service_role should succeed');

-- Reset
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);

-- Test notifications exempt: notifications table should NOT have guard
-- Check that trigger does not exist on notifications
do $$
declare
  v_count int;
begin
  select count(*) into v_count from pg_trigger where tgname='tenant_read_only_guard' and tgrelid='public.notifications'::regclass;
  if v_count > 0 then
    raise exception 'FAIL: notifications should be exempt from read_only guard';
  end if;
end $$;

-- Cleanup
drop table tmp_readonly_test;
update public.tenants set read_only=false, read_only_reason=null where id='00000000-0000-0000-0000-0000000000aa';

-- Verify apply function attaches to tenant_feature_flags (new table)
do $$
declare
  v_count int;
begin
  select count(*) into v_count from pg_trigger where tgname='tenant_read_only_guard' and tgrelid='public.tenant_feature_flags'::regclass;
  if v_count = 0 then
    raise exception 'FAIL: tenant_feature_flags should have read_only guard after re-apply';
  end if;
end $$;

raise notice 'PASS: tenant_read_only_guard tests';

rollback;
