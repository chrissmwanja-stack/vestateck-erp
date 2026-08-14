-- Run ONCE, by hand, against a brand-new production project immediately
-- after the first `supabase db push` and before any real company is
-- created (Foundation Playbook Phase 4, step 3). This is not a
-- migration and must never be added to supabase/migrations/ -- it is
-- destructive and tenant-scoped to the demo data specifically, not
-- something that should replay automatically on every environment.
--
-- What it does:
--   1. Deletes every row scoped to the demo tenant (Test Construction Co,
--      00000000-0000-0000-0000-000000000001) across every table that has
--      a tenant_id column -- discovered dynamically via
--      information_schema, so it does not go stale as new modules add
--      tables. This also covers the satellite tables (hr_*, pmo_*,
--      machines, sustainability_*) that don't have an FK to tenants(id)
--      yet and so would NOT be cleaned up by cascade alone.
--   2. Deletes the demo tenant row itself.
--   3. Deletes every @test.local auth.users row (cascades to app_users
--      via the on-delete-cascade FK in 0001_init_core_schema.sql).
--
-- Session_replication_role is set to 'replica' for the duration so FK
-- constraints don't block deletion order across ~120 tables -- this
-- requires running as a role with that privilege (the Supabase SQL
-- editor / postgres role has it; the anon/authenticated app roles do
-- not, which is correct).
--
-- Safety guard: refuses to run unless the tenant row matches the exact
-- demo tenant id AND name, so pointing this at the wrong project by
-- accident fails loud instead of deleting real customer data.

do $$
declare
  v_demo_tenant_id uuid := '00000000-0000-0000-0000-000000000001';
  v_demo_tenant_name text;
  r record;
begin
  select name into v_demo_tenant_name from tenants where id = v_demo_tenant_id;

  if v_demo_tenant_name is null then
    raise notice 'strip-demo-data: no tenant % found -- nothing to strip (already clean, or this was already run).', v_demo_tenant_id;
    return;
  end if;

  if v_demo_tenant_name <> 'Test Construction Co' then
    raise exception 'strip-demo-data: tenant % has name %, expected "Test Construction Co". Refusing to run -- this does not look like the demo tenant.', v_demo_tenant_id, v_demo_tenant_name;
  end if;

  set local session_replication_role = 'replica';

  for r in
    select distinct table_schema, table_name
    from information_schema.columns
    where column_name = 'tenant_id' and table_schema = 'public'
  loop
    execute format('delete from %I.%I where tenant_id = %L', r.table_schema, r.table_name, v_demo_tenant_id);
  end loop;

  delete from public.tenants where id = v_demo_tenant_id;

  set local session_replication_role = 'origin';

  raise notice 'strip-demo-data: cleared all tenant-scoped rows for %.', v_demo_tenant_id;
end $$;

-- auth.users is not tenant-scoped (it's cross-tenant by design), so this
-- runs outside the tenant-scoped loop above, matched by email pattern
-- instead. Cascades to app_users via app_users.id references
-- auth.users(id) on delete cascade.
delete from auth.users where email like '%@test.local';

-- Verify: both of these should return 0 rows.
select count(*) as remaining_test_users from auth.users where email like '%@test.local';
select count(*) as remaining_demo_tenant from tenants where id = '00000000-0000-0000-0000-000000000001';
