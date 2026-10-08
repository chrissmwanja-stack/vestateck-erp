-- Regression test for:
--   supabase/migrations/20261008092000_set_tenant_modules_grants_company_admins.sql
--
-- Verifies set_tenant_modules():
--   1. Newly entitled modules give the tenant's company admins an 'admin'
--      staff_roles row; non-admin members get nothing; other tenants' company
--      admins are untouched.
--   2. Adding a module later grants only the new one.
--   3. Re-saving an unchanged set does NOT re-add a role that was removed.
--   4. Un-entitling a module removes the entitlement but leaves the role row.
--   5. Still platform-admin only.
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_home uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_ca uuid := gen_random_uuid();      -- company admin of t_a
  v_member uuid := gen_random_uuid();  -- plain member of t_a
  v_ca_b uuid := gen_random_uuid();    -- company admin of t_b
  t_a uuid := gen_random_uuid();
  t_b uuid := gen_random_uuid();
begin
  create temp table test_ids (k text primary key, v uuid) on commit drop;
  insert into test_ids values ('home', v_home), ('admin', v_admin), ('ca', v_ca), ('member', v_member),
    ('ca_b', v_ca_b), ('t_a', t_a), ('t_b', t_b);
  grant select on test_ids to authenticated, anon, service_role;

  insert into tenants (id, name, status, created_at, plan, subscription_status, industry_template) values
    (v_home, 'STM Platform Home', 'active', now() - interval '300 days', 'internal', 'active', 'general'),
    (t_a,    'STM Co A',          'active', now() - interval '30 days',  'trial', 'trialing', 'general'),
    (t_b,    'STM Co B',          'active', now() - interval '30 days',  'trial', 'trialing', 'general');

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', now()
  from (values (v_admin, 'stm-admin'), (v_ca, 'stm-ca'), (v_member, 'stm-member'), (v_ca_b, 'stm-ca-b')) as u(id, handle);

  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
   values (gen_random_uuid(), v_admin, 'test', 'totp', 'verified', now(), now());

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (v_admin,  v_home, 'STM Admin',  'stm-admin@test.local',  true,  false, now() - interval '300 days'),
    (v_ca,     t_a,    'STM CA',     'stm-ca@test.local',     false, true,  now() - interval '3 days'),
    (v_member, t_a,    'STM Member', 'stm-member@test.local', false, false, now() - interval '3 days'),
    (v_ca_b,   t_b,    'STM CA B',   'stm-ca-b@test.local',   false, true,  now() - interval '3 days');
end $$;

create or replace function pg_temp.become(p_key text, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', p_aal)::text, true);
end $$;

create or replace function pg_temp.roles(p_user text, p_tenant text) returns text
language sql security definer as $$
  select coalesce(string_agg(module || ':' || role, ',' order by module), '')
  from staff_roles
  where user_id = (select v from test_ids where k = p_user)
    and tenant_id = (select v from test_ids where k = p_tenant)
$$;
grant execute on function pg_temp.roles(text, text) to authenticated;

create or replace function pg_temp.drop_role(p_user text, p_tenant text, p_module text) returns void
language sql security definer as $$
  delete from staff_roles
  where user_id = (select v from test_ids where k = p_user)
    and tenant_id = (select v from test_ids where k = p_tenant) and module = p_module
$$;
grant execute on function pg_temp.drop_role(text, text, text) to authenticated;

create or replace function pg_temp.mods(p_tenant text) returns text
language sql security definer as $$
  select coalesce(string_agg(module, ',' order by module), '') from tenant_modules
  where tenant_id = (select v from test_ids where k = p_tenant)
$$;
grant execute on function pg_temp.mods(text) to authenticated;

set local role authenticated;

-- 5. non-platform-admins are refused
select pg_temp.become('ca');
do $$
begin
  perform set_tenant_modules((select v from test_ids where k = 't_a'), array['hr']);
  raise exception 'FAIL: company admin changed modules';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end $$;

select pg_temp.become('admin');
do $$
declare t_a uuid := (select v from test_ids where k = 't_a');
begin
  -- 1. initial entitlement
  perform set_tenant_modules(t_a, array['hr', 'pmo']);
  if pg_temp.roles('ca', 't_a') <> 'hr:admin,pmo:admin' then raise exception 'FAIL: company admin roles = %', pg_temp.roles('ca', 't_a'); end if;
  if pg_temp.roles('member', 't_a') <> '' then raise exception 'FAIL: plain member got roles'; end if;
  if pg_temp.roles('ca_b', 't_b') <> '' then raise exception 'FAIL: other tenant company admin got roles'; end if;

  -- 2. adding a module grants only the new one
  perform set_tenant_modules(t_a, array['hr', 'pmo', 'it']);
  if pg_temp.roles('ca', 't_a') <> 'hr:admin,it:admin,pmo:admin' then raise exception 'FAIL: after add = %', pg_temp.roles('ca', 't_a'); end if;

  -- 3. a removed role is not re-added by re-saving the same set
  perform pg_temp.drop_role('ca', 't_a', 'it');
  perform set_tenant_modules(t_a, array['hr', 'pmo', 'it']);
  if pg_temp.roles('ca', 't_a') <> 'hr:admin,pmo:admin' then raise exception 'FAIL: re-save re-added role: %', pg_temp.roles('ca', 't_a'); end if;

  -- 4. un-entitling keeps the role row (inert) but drops the entitlement
  perform set_tenant_modules(t_a, array['hr']);
  if pg_temp.mods('t_a') <> 'hr' then raise exception 'FAIL: modules = %', pg_temp.mods('t_a'); end if;
  if pg_temp.roles('ca', 't_a') <> 'hr:admin,pmo:admin' then raise exception 'FAIL: role rows changed on un-entitle: %', pg_temp.roles('ca', 't_a'); end if;

  -- other tenant untouched throughout
  if pg_temp.roles('ca_b', 't_b') <> '' then raise exception 'FAIL: other tenant touched'; end if;
end $$;

reset role;
rollback;
