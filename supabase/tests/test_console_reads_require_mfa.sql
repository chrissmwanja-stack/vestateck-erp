-- Regression test for:
--   supabase/migrations/20261002090000_console_reads_require_mfa.sql
--
-- The 15 platform-console read RPCs used plain is_platform_admin(), so an
-- operator with an enrolled authenticator could read cross-tenant data on a
-- password-only (aal1) session. They now go through the same MFA rule as the
-- console's writes (require_platform_admin).
--
-- Verifies, against a fully-migrated fresh stack, for each of the 15 reads:
--   1. A non-platform user never gets PLATFORM_MFA_REQUIRED (behaviour for
--      non-admins is unchanged: empty set or the function's own refusal).
--   2. A platform admin with NO enrolled factor never gets it (aal1 is enough).
--   3. A platform admin WITH a verified factor on an aal1 session gets
--      PLATFORM_MFA_REQUIRED from every one of them.
--   4. The same admin on an aal2 session never gets it.
--   5. platform_admin_mfa_gate() is not executable by authenticated or anon.
--
-- Run against a fresh local stack only -- never against a linked/remote
-- project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant uuid := gen_random_uuid();
  v_home   uuid := gen_random_uuid();  -- platform admin's own tenant
  v_admin  uuid := gen_random_uuid();
  v_plain  uuid := gen_random_uuid();
begin
  insert into tenants (id, name, status) values
    (v_tenant, 'ConsoleMfa Customer Co', 'active'),
    (v_home,   'ConsoleMfa Platform Home', 'active');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values
    (v_admin, 'cmfa-platform-admin'),
    (v_plain, 'cmfa-plain-user')
  ) as u(id, handle);

  -- app_users_single_platform_admin allows one true row in the whole table.
  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin) values
    (v_admin, v_home,   'CMFA Platform Admin', 'cmfa-platform-admin@test.local', true),
    (v_plain, v_tenant, 'CMFA Plain User',     'cmfa-plain-user@test.local',     false);

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values ('tenant', v_tenant), ('home', v_home), ('admin', v_admin), ('plain', v_plain);
  grant select on test_ids to authenticated;
end $$;

create or replace function pg_temp.become(p_key text, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object(
      'sub',  (select v from test_ids where k = p_key),
      'role', 'authenticated',
      'aal',  p_aal
    )::text, true);
end $$;

-- The 15 console reads, as callable statements.
create or replace function pg_temp.console_reads() returns text[]
language plpgsql as $$
declare
  t text := (select v::text from test_ids where k = 'tenant');
begin
  return array[
    'select * from get_companies_overview()',
    format('select * from get_company_analytics(%L)', t),
    'select * from get_platform_dashboard_stats()',
    'select * from get_platform_health()',
    format('select * from get_tenant_modules(%L)', t),
    format('select * from get_tenant_workflow_stages(%L)', t),
    'select * from get_tenant_onboarding_status()',
    format('select * from get_tenant_feature_flags(%L)', t),
    format('select * from get_tenant_profile(%L)', t),
    'select * from list_feature_flags()',
    'select * from list_impersonation_history()',
    'select * from list_industry_templates()',
    'select * from list_platform_announcements()',
    'select * from list_platform_audit_events()',
    'select * from list_platform_digests()'
  ];
end $$;

-- Runs a statement; true only if it raised PLATFORM_MFA_REQUIRED. Any other
-- outcome (rows, empty, or the function's own refusal) is "not an MFA error".
create or replace function pg_temp.raises_mfa(p_sql text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlerrm like 'PLATFORM_MFA_REQUIRED%';
end $$;

-- ---------------------------------------------------------------------
-- 5. The gate helper is internal
-- ---------------------------------------------------------------------
do $$
begin
  if has_function_privilege('authenticated', 'public.platform_admin_mfa_gate(text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.platform_admin_mfa_gate(text)', 'EXECUTE') then
    raise exception 'FAIL 5: platform_admin_mfa_gate is executable by a client role';
  end if;
  raise notice 'PASS: 5. platform_admin_mfa_gate is not client-executable';
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Non-platform user: never an MFA error
-- ---------------------------------------------------------------------
select pg_temp.become('plain');
do $$
declare s text;
begin
  foreach s in array pg_temp.console_reads() loop
    if pg_temp.raises_mfa(s) then
      raise exception 'FAIL 1: non-admin got PLATFORM_MFA_REQUIRED from: %', s;
    end if;
  end loop;
  raise notice 'PASS: 1. non-platform user is unaffected by the MFA rule';
end $$;

-- ---------------------------------------------------------------------
-- 2. Platform admin, no factor enrolled: aal1 is enough
-- ---------------------------------------------------------------------
select pg_temp.become('admin', 'aal1');
do $$
declare s text;
begin
  foreach s in array pg_temp.console_reads() loop
    if pg_temp.raises_mfa(s) then
      raise exception 'FAIL 2: admin with no factor got PLATFORM_MFA_REQUIRED from: %', s;
    end if;
  end loop;
  raise notice 'PASS: 2. admin without an enrolled factor can still read on aal1';
end $$;

-- ---------------------------------------------------------------------
-- 3. Enrol a verified TOTP factor: aal1 is refused on every read
-- ---------------------------------------------------------------------
reset role;
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
values (gen_random_uuid(), (select v from test_ids where k = 'admin'), 'test', 'totp', 'verified', now(), now());
set local role authenticated;

select pg_temp.become('admin', 'aal1');
do $$
declare s text;
begin
  foreach s in array pg_temp.console_reads() loop
    if not pg_temp.raises_mfa(s) then
      raise exception 'FAIL 3: enrolled admin on aal1 was NOT refused by: %', s;
    end if;
  end loop;
  raise notice 'PASS: 3. all 15 console reads refuse an enrolled admin on aal1';
end $$;

-- ---------------------------------------------------------------------
-- 4. Same admin on aal2: no MFA error
-- ---------------------------------------------------------------------
select pg_temp.become('admin', 'aal2');
do $$
declare s text;
begin
  foreach s in array pg_temp.console_reads() loop
    if pg_temp.raises_mfa(s) then
      raise exception 'FAIL 4: enrolled admin on aal2 got PLATFORM_MFA_REQUIRED from: %', s;
    end if;
  end loop;
  raise notice 'PASS: 4. enrolled admin on aal2 reads normally';
end $$;

rollback;
