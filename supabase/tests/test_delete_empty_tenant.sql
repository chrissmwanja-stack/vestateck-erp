-- Regression test for 20261015090000_delete_empty_tenant.sql.
--
--   a. A non-platform-admin is refused (PLATFORM_ADMIN_REQUIRED).
--   b. A wrong confirmation name is refused and nothing is deleted.
--   c. An unknown tenant id is refused.
--   d. A tenant with users is refused, and the message says to suspend it.
--   e. A tenant with data in an unseeded table is refused.
--   f. A tenant holding only seeded rows is deleted, the seeded rows cascade,
--      and a 'tenant.delete' audit event keeps the id and name.
--   g. Only authenticated can execute the function (anon/PUBLIC cannot).
--
-- Run only on a disposable local/test database; every fixture rolls back.

\set ON_ERROR_STOP on
begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then
      return;
    end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  v_home   uuid := gen_random_uuid();   -- where the platform admin belongs
  v_admin  uuid := gen_random_uuid();
  v_plain  uuid := gen_random_uuid();
  t_clean  uuid := gen_random_uuid();
  t_users  uuid := gen_random_uuid();
  t_data   uuid := gen_random_uuid();
  n        integer;
  v_detail jsonb;
  v_target text;
begin
  insert into tenants(id, name) values
    (v_home, 'Delete tenant home'), (t_clean, 'Delete clean co'),
    (t_users, 'Delete users co'), (t_data, 'Delete data co');

  -- Only one platform admin may exist, so clear any seed row inside this transaction.
  update app_users set is_platform_admin = false where is_platform_admin;

  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'delete-tenant-'||u||'@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[v_admin, v_plain]) u;
  insert into app_users(id, tenant_id, name, email, is_platform_admin) values
    (v_admin, v_home, 'Delete tenant admin', 'delete-tenant-'||v_admin||'@test.local', true),
    (v_plain, t_users, 'Delete tenant plain user', 'delete-tenant-'||v_plain||'@test.local', false);

  -- Seeded starter rows only, for the clean tenant.
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (t_clean, '1000', 'Operating', 'asset');
  insert into tenant_modules(tenant_id, module) values (t_clean, 'insurance');

  -- a. A non-admin is refused.
  perform pg_temp.jwt(v_plain); set local role authenticated;
  perform pg_temp.expect_error(format('select delete_empty_tenant(%L, %L)', t_clean, 'Delete clean co'),
    'PLATFORM_ADMIN_REQUIRED', 'a: non-admin delete');
  reset role;
  select count(*) into n from tenants where id = t_clean;
  perform pg_temp.assert(n = 1, 'a: non-admin attempt removed the tenant');

  -- From here on, act as the platform admin.
  perform pg_temp.jwt(v_admin); set local role authenticated;

  -- b. Wrong confirmation name.
  perform pg_temp.expect_error(format('select delete_empty_tenant(%L, %L)', t_clean, 'Wrong name'),
    'Confirmation name does not match', 'b: wrong confirmation name');
  -- Name must match after trimming surrounding spaces only, not be case-insensitive.
  perform pg_temp.expect_error(format('select delete_empty_tenant(%L, %L)', t_clean, 'delete clean co'),
    'Confirmation name does not match', 'b: confirmation name is case-sensitive');

  -- c. Unknown tenant.
  perform pg_temp.expect_error(format('select delete_empty_tenant(%L, %L)', gen_random_uuid(), 'Nobody'),
    'tenant not found', 'c: unknown tenant');

  -- d. Tenant with users.
  perform pg_temp.expect_error(format('select delete_empty_tenant(%L, %L)', t_users, 'Delete users co'),
    'Suspend it instead', 'd: tenant with users');

  -- e. Tenant with data in an unseeded table.
  reset role;
  insert into accounts(tenant_id, account_code, name, account_type) values (t_data, 'X-1', 'Client money', 'client');
  perform pg_temp.jwt(v_admin); set local role authenticated;
  perform pg_temp.expect_error(format('select delete_empty_tenant(%L, %L)', t_data, 'Delete data co'),
    'has data in "accounts"', 'e: tenant with unseeded data');
  reset role;
  select count(*) into n from tenants where id = t_data;
  perform pg_temp.assert(n = 1, 'e: refused delete still removed the tenant');

  -- f. Clean tenant is deleted.
  perform pg_temp.jwt(v_admin); set local role authenticated;
  perform delete_empty_tenant(t_clean, 'Delete clean co', 'test cleanup');
  reset role;

  select count(*) into n from tenants where id = t_clean;
  perform pg_temp.assert(n = 0, 'f: tenant row still present after delete');
  select count(*) into n from gl_accounts where tenant_id = t_clean;
  perform pg_temp.assert(n = 0, 'f: seeded gl_accounts did not cascade');
  select count(*) into n from tenant_modules where tenant_id = t_clean;
  perform pg_temp.assert(n = 0, 'f: seeded tenant_modules did not cascade');

  select target_id, before into v_target, v_detail
  from platform_audit_events
  where action = 'tenant.delete' and target_id = t_clean::text;
  perform pg_temp.assert(v_target is not null, 'f: no tenant.delete audit event');
  perform pg_temp.assert(v_detail->>'tenant_name' = 'Delete clean co',
    format('f: audit event lost the tenant name (%s)', v_detail));

  -- The audit row survives with tenant_id nulled out (ON DELETE SET NULL).
  select count(*) into n from platform_audit_events where action = 'tenant.delete' and target_id = t_clean::text and tenant_id is null;
  perform pg_temp.assert(n = 1, 'f: audit event tenant_id not nulled on delete');

  -- Refused deletes leave no audit event.
  select count(*) into n from platform_audit_events where action = 'tenant.delete' and target_id in (t_users::text, t_data::text);
  perform pg_temp.assert(n = 0, 'e/d: refused delete wrote an audit event');

  -- g. Privileges: only authenticated may execute.
  perform pg_temp.assert(has_function_privilege('authenticated', 'public.delete_empty_tenant(uuid,text,text)', 'EXECUTE'),
    'g: authenticated cannot execute delete_empty_tenant');
  perform pg_temp.assert(not has_function_privilege('anon', 'public.delete_empty_tenant(uuid,text,text)', 'EXECUTE'),
    'g: anon can execute delete_empty_tenant');

  raise notice 'PASS: delete_empty_tenant guards, cascade and audit';
end $$;

rollback;
