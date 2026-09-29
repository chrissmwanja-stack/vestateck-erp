-- tenant_read_only_guard, asserted against the REAL tables.
--
-- The previous version of this file attached the guard to a temp table, so it
-- could not see a real table missing the trigger. This version:
--   1. asserts the guard is attached and enabled on EVERY public table with a
--      tenant_id column (same exempt list as check_live_security_drift.sql), so
--      a newly added tenant table nobody re-swept fails CI by name,
--   2. exercises the guard on real tables: writes work while the tenant is
--      writable, INSERT/UPDATE/DELETE raise TENANT_READ_ONLY for an
--      'authenticated' request while it is read_only, service_role is not
--      blocked, and writes work again once read_only is lifted,
--   3. keeps the notifications exemption and the tenant_feature_flags check.
--
-- The guard checks the request role from request.jwt.claims (not the database
-- role), so the statements run as the table owner and no RLS is involved: a
-- TENANT_READ_ONLY error can only come from the guard. Platform-admin bypass
-- needs an is_platform_admin user and is not covered here.
--
-- invitations is covered in test_reapplied_hardening.sql section 7.
-- Everything rolls back. Runs against a fresh/local database only.

\set ON_ERROR_STOP on

begin;

-- Runs a statement that must be blocked by tenant_read_only_guard().
create function pg_temp.expect_read_only(p_sql text, p_label text)
returns void language plpgsql as $$
declare v_n int;
begin
  begin
    execute p_sql;
    get diagnostics v_n = row_count;
    if v_n = 0 then
      raise exception 'FAIL: % -- could not exercise the guard, statement matched 0 rows', p_label;
    end if;
    raise exception 'FAIL: % succeeded despite read_only = true', p_label;
  exception when insufficient_privilege then
    if sqlerrm not like 'TENANT_READ_ONLY:%' then
      raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
    end if;
  end;
end $$;

create temp table ro_ctx (tenant_id uuid not null) on commit drop;
insert into ro_ctx values (gen_random_uuid());
insert into tenants (id, name) select tenant_id, 'test-readonly-tenant' from ro_ctx;

-- ---------------------------------------------------------------------
-- 1. Guard attached and enabled on every tenant_id table
-- ---------------------------------------------------------------------
do $$
declare
  v_exempt text[] := array[
    'platform_audit_events', 'impersonation_sessions', 'impersonation_logs',
    'tenant_notes', 'notifications', 'app_users', 'platform_digests', 'platform_job_runs'
  ];
  v_missing text[] := '{}';
  r record;
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
    where n.nspname = 'public' and c.relkind = 'r' and c.relname <> all (v_exempt)
      and not exists (
        select 1 from pg_trigger g
        where g.tgrelid = c.oid and g.tgname = 'tenant_read_only_guard'
          and not g.tgisinternal and g.tgenabled = 'O')
    order by c.relname
  loop
    v_missing := v_missing || r.relname;
  end loop;

  if array_length(v_missing, 1) is not null then
    raise exception 'FAIL: tenant_read_only_guard missing/disabled on % table(s): % (run select public.apply_tenant_read_only_guard())',
      array_length(v_missing, 1), array_to_string(v_missing, ', ');
  end if;

  raise notice 'PASS: tenant_read_only_guard is attached to every non-exempt tenant_id table';
end $$;

-- Exemptions and one specific newer table
do $$
begin
  if exists (select 1 from pg_trigger
             where tgname = 'tenant_read_only_guard' and tgrelid = to_regclass('public.notifications')) then
    raise exception 'FAIL: notifications should be exempt from the read_only guard';
  end if;
  if not exists (select 1 from pg_trigger
                 where tgname = 'tenant_read_only_guard' and tgrelid = to_regclass('public.tenant_feature_flags')
                   and not tgisinternal and tgenabled = 'O') then
    raise exception 'FAIL: tenant_feature_flags should have the read_only guard';
  end if;
  raise notice 'PASS: notifications exempt, tenant_feature_flags guarded';
end $$;

-- ---------------------------------------------------------------------
-- 2. Behaviour on real tables
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant uuid := (select tenant_id from ro_ctx);
  v_tbl text;
begin
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);

  -- writable tenant: writes go through
  foreach v_tbl in array array['bd_lead_sources', 'support_teams'] loop
    execute format('insert into public.%I (tenant_id, name) values (%L, %L)', v_tbl, v_tenant, 'ro-seed');
  end loop;

  update tenants set read_only = true, read_only_reason = 'past due 60 days', read_only_since = now()
  where id = v_tenant;

  -- read-only tenant, ordinary authenticated request: everything is blocked
  foreach v_tbl in array array['bd_lead_sources', 'support_teams'] loop
    perform pg_temp.expect_read_only(
      format('insert into public.%I (tenant_id, name) values (%L, %L)', v_tbl, v_tenant, 'ro-blocked'),
      v_tbl || ' INSERT');
    perform pg_temp.expect_read_only(
      format('update public.%I set name = name || ''x'' where tenant_id = %L', v_tbl, v_tenant),
      v_tbl || ' UPDATE');
    perform pg_temp.expect_read_only(
      format('delete from public.%I where tenant_id = %L', v_tbl, v_tenant),
      v_tbl || ' DELETE');
  end loop;

  -- service_role is not blocked
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  foreach v_tbl in array array['bd_lead_sources', 'support_teams'] loop
    execute format('insert into public.%I (tenant_id, name) values (%L, %L)', v_tbl, v_tenant, 'ro-service-role');
  end loop;

  -- lift read_only: ordinary requests can write again
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  update tenants set read_only = false, read_only_reason = null where id = v_tenant;
  foreach v_tbl in array array['bd_lead_sources', 'support_teams'] loop
    execute format('insert into public.%I (tenant_id, name) values (%L, %L)', v_tbl, v_tenant, 'ro-lifted');
  end loop;

  raise notice 'PASS: read_only blocks authenticated writes on real tables, service_role bypasses, lifting it restores writes';
end $$;

do $$ begin raise notice 'PASS: tenant_read_only_guard tests (real tables)'; end $$;

rollback;