-- Regression test for:
--   supabase/migrations/20261008061315_platform_modules_registry.sql
--   supabase/migrations/20261008061330_template_module_validation_uses_registry.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. The registry holds the 8 previously-valid module keys plus 'finance',
--      with the intended tiers, and only 'finance' is not tenant-entitled.
--   2. The three old module CHECK constraints are gone and replaced by FKs.
--   3. Behaviour is unchanged: unknown keys are rejected on tenant_modules,
--      staff_roles and platform_module_activity_sources; 'finance' is still
--      rejected on tenant_modules and staff_roles; every one of the 8 old keys
--      is still accepted on both.
--   4. A key cannot be deleted from the registry while referenced.
--   5. Registry access: signed-in users can read it, nobody can write it
--      through the API, anon cannot read it.
--   6. save_industry_template() validates module items against the registry,
--      so a newly registered key becomes usable in a template without a deploy.
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_home  uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_user  uuid := gen_random_uuid();
  t_a     uuid := gen_random_uuid();
begin
  create temp table test_ids (k text primary key, v uuid) on commit drop;
  insert into test_ids values ('home', v_home), ('admin', v_admin), ('user', v_user), ('t_a', t_a);
  grant select on test_ids to authenticated, anon, service_role;

  insert into tenants (id, name, status, created_at, plan, subscription_status, industry_template) values
    (v_home, 'Reg Test Platform Home', 'active', now() - interval '300 days', 'internal', 'active', 'general'),
    (t_a,    'Reg Test Co',            'active', now() - interval '30 days',  'trial', 'trialing', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', now()
  from (values (v_admin, 'reg-admin'), (v_user, 'reg-user')) as u(id, handle);

  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
   values (gen_random_uuid(), v_admin, 'test', 'totp', 'verified', now(), now());

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (v_admin, v_home, 'Reg Admin', 'reg-admin@test.local', true,  false, now() - interval '300 days'),
    (v_user,  t_a,    'Reg User',  'reg-user@test.local',  false, false, now() - interval '3 days');
end $$;

create or replace function pg_temp.become(p_key text, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', p_aal)::text, true);
end $$;

-- ---------------------------------------------------------------------
-- 1 + 2. Registry contents and constraint swap (as table owner)
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
  if (select count(*) from platform_modules where key in
      ('hr','legal','bd','it','pmo','procurement','machine_operation','sustainability','finance')) <> 9 then
    raise exception 'FAIL: expected the 9 backfilled module keys';
  end if;
  if (select count(*) from platform_modules where tenant_entitled) < 8
     or exists (select 1 from platform_modules where key = 'finance' and tenant_entitled)
     or exists (select 1 from platform_modules where key <> 'finance' and key in
        ('hr','legal','bd','it','pmo','procurement','machine_operation','sustainability') and not tenant_entitled) then
    raise exception 'FAIL: tenant_entitled flags wrong';
  end if;
  if (select tier from platform_modules where key = 'finance') <> 'core'
     or (select vertical from platform_modules where key = 'pmo') <> 'construction'
     or (select tier from platform_modules where key = 'bd') <> 'optional' then
    raise exception 'FAIL: tiers wrong';
  end if;

  select count(*) into v_n from pg_constraint
   where conname in ('tenant_modules_module_check','staff_roles_module_check','platform_module_activity_sources_module_check');
  if v_n <> 0 then raise exception 'FAIL: old module CHECKs still present (%)', v_n; end if;

  select count(*) into v_n from pg_constraint
   where contype = 'f' and confrelid = 'public.platform_modules'::regclass
     and conrelid in ('public.tenant_modules'::regclass, 'public.staff_roles'::regclass, 'public.platform_module_activity_sources'::regclass);
  if v_n <> 3 then raise exception 'FAIL: expected 3 FKs into platform_modules, got %', v_n; end if;

  -- tier / vertical consistency
  begin
    insert into platform_modules (key, name, tier, vertical) values ('bad_a', 'Bad', 'vertical', null);
    raise exception 'FAIL: vertical tier without vertical accepted';
  exception when check_violation then null; end;
  begin
    insert into platform_modules (key, name, tier, vertical) values ('bad_b', 'Bad', 'optional', 'x');
    raise exception 'FAIL: vertical set on non-vertical tier accepted';
  exception when check_violation then null; end;
  begin
    insert into platform_modules (key, name, tier) values ('Bad-Key', 'Bad', 'optional');
    raise exception 'FAIL: malformed key accepted';
  exception when check_violation then null; end;
end $$;

-- ---------------------------------------------------------------------
-- 3. Behaviour unchanged on the three referencing tables
-- ---------------------------------------------------------------------
do $$
declare
  t_a uuid := (select v from test_ids where k = 't_a');
  v_user uuid := (select v from test_ids where k = 'user');
  m text;
begin
  -- all 8 old keys still accepted on tenant_modules and staff_roles
  foreach m in array array['hr','legal','bd','it','pmo','procurement','machine_operation','sustainability'] loop
    insert into tenant_modules (tenant_id, module) values (t_a, m) on conflict do nothing;
    insert into staff_roles (tenant_id, user_id, module, role) values (t_a, v_user, m, 'member');
  end loop;

  -- unknown key rejected (FK)
  begin
    insert into tenant_modules (tenant_id, module) values (t_a, 'crypto');
    raise exception 'FAIL: unknown module accepted on tenant_modules';
  exception when foreign_key_violation then null; end;
  begin
    insert into staff_roles (tenant_id, user_id, module, role) values (t_a, v_user, 'crypto', 'member');
    raise exception 'FAIL: unknown module accepted on staff_roles';
  exception when foreign_key_violation then null; end;
  begin
    insert into platform_module_activity_sources (module, table_name) values ('crypto', 'tenants');
    raise exception 'FAIL: unknown module accepted on activity sources';
  exception when foreign_key_violation then null; end;

  -- finance: registered, but not entitlable (same outcome as the old CHECK)
  begin
    insert into tenant_modules (tenant_id, module) values (t_a, 'finance');
    raise exception 'FAIL: finance accepted on tenant_modules';
  exception when check_violation then null; end;
  begin
    insert into staff_roles (tenant_id, user_id, module, role) values (t_a, v_user, 'finance', 'member');
    raise exception 'FAIL: finance accepted on staff_roles';
  exception when check_violation then null; end;
  -- ...but still valid for activity sources, as before
  insert into platform_module_activity_sources (module, table_name) values ('finance', 'tenants')
    on conflict do nothing;

  -- updating a row onto a non-entitlable key is also blocked
  begin
    update tenant_modules set module = 'finance' where tenant_id = t_a and module = 'hr';
    raise exception 'FAIL: update to finance accepted';
  exception when check_violation then null; end;

  -- 4. referenced keys cannot be deleted
  begin
    delete from platform_modules where key = 'hr';
    raise exception 'FAIL: referenced registry key deleted';
  exception when foreign_key_violation then null; end;
end $$;

-- ---------------------------------------------------------------------
-- 5. Access
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('user');
do $$
begin
  if (select count(*) from platform_modules) < 9 then raise exception 'FAIL: authenticated cannot read registry'; end if;
  begin
    insert into platform_modules (key, name, tier) values ('sneaky', 'Sneaky', 'optional');
    raise exception 'FAIL: authenticated inserted into registry';
  exception when insufficient_privilege then null; end;
  begin
    update platform_modules set name = 'x' where key = 'hr';
    raise exception 'FAIL: authenticated updated registry';
  exception when insufficient_privilege then null; end;
  begin
    delete from platform_modules where key = 'hr';
    raise exception 'FAIL: authenticated deleted from registry';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

set local role anon;
do $$
begin
  perform 1 from platform_modules limit 1;
  raise exception 'FAIL: anon read the registry';
exception when insufficient_privilege then null;
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 6. Template validation reads the registry
-- ---------------------------------------------------------------------
do $$
begin
  insert into platform_modules (key, name, tier, vertical, route_base)
  values ('regtest_pack', 'Registry Test Pack', 'vertical', 'regtest', '/regtest'),
         ('regtest_off',  'Registry Test Inactive', 'optional', null, null);
  update platform_modules set is_active = false where key = 'regtest_off';
end $$;

set local role authenticated;
select pg_temp.become('admin');
do $$
begin
  -- unknown, non-entitlable and inactive keys are refused
  begin
    perform save_industry_template('regtpl', 'Reg Tpl', null, '[{"kind":"module","name":"crypto"}]'::jsonb);
    raise exception 'FAIL: unknown module accepted in template';
  exception when others then
    if sqlerrm not like 'TEMPLATE_ITEMS_INVALID: unknown module%' then raise; end if;
  end;
  begin
    perform save_industry_template('regtpl', 'Reg Tpl', null, '[{"kind":"module","name":"finance"}]'::jsonb);
    raise exception 'FAIL: finance accepted as a template module';
  exception when others then
    if sqlerrm not like 'TEMPLATE_ITEMS_INVALID: unknown module%' then raise; end if;
  end;
  begin
    perform save_industry_template('regtpl', 'Reg Tpl', null, '[{"kind":"module","name":"regtest_off"}]'::jsonb);
    raise exception 'FAIL: inactive module accepted in template';
  exception when others then
    if sqlerrm not like 'TEMPLATE_ITEMS_INVALID: unknown module%' then raise; end if;
  end;

  -- a freshly registered key works with no code change
  perform save_industry_template('regtpl', 'Reg Tpl', null,
    '[{"kind":"module","name":"regtest_pack"},{"kind":"module","name":"hr"}]'::jsonb);
  if (select module_count from list_industry_templates(true) where key = 'regtpl') <> 2 then
    raise exception 'FAIL: template with registry module not saved';
  end if;
end $$;
reset role;

rollback;