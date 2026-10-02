-- Regression test for:
--   supabase/migrations/20261002070000_fix_set_member_access_ambiguous_columns.sql
--
-- set_member_access() is declared RETURNS TABLE (user_id, ...). Those names are
-- PL/pgSQL OUT variables, and unqualified `user_id` in the body collided with
-- them (42702 "column reference user_id is ambiguous") on every call, so the
-- Team Members "Save changes" action never worked. No SQL test called the
-- function, and the component test mocks the RPC.
--
-- Verifies, against a fully-migrated fresh stack:
--   1. A company admin can ADD a module grant; the returned row reflects it.
--   2. Passing the original set back REMOVES the extra grant (replace-all).
--   3. Finance role: set 'finance', switch to 'cost_control' (the old row is
--      cleared), then clear it with '' (and with NULL modules = clear all).
--   4. Calling it twice with the same input is idempotent (ON CONFLICT paths).
--   5. A module admin who is not a company admin, and a plain member, are
--      refused.
--   6. A company admin cannot change a user of ANOTHER tenant.
--   7. An invalid finance role is refused.
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
  v_tenant   uuid := gen_random_uuid();
  v_other    uuid := gen_random_uuid();
  v_cadmin   uuid := gen_random_uuid();  -- company admin
  v_modadmin uuid := gen_random_uuid();  -- hr module admin, not a company admin
  v_member   uuid := gen_random_uuid();  -- the member whose access is edited
  v_outsider uuid := gen_random_uuid();  -- user of the other tenant
begin
  insert into tenants (id, name, status) values
    (v_tenant, 'SetAccess Test Co',       'active'),
    (v_other,  'SetAccess Test Other Co', 'active');

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
    (v_cadmin,   'sma-company-admin'),
    (v_modadmin, 'sma-module-admin'),
    (v_member,   'sma-member'),
    (v_outsider, 'sma-outsider')
  ) as u(id, handle);

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin) values
    (v_cadmin,   v_tenant, 'SMA Company Admin', 'sma-company-admin@test.local', false, true),
    (v_modadmin, v_tenant, 'SMA Module Admin',  'sma-module-admin@test.local',  false, false),
    (v_member,   v_tenant, 'SMA Member',        'sma-member@test.local',        false, false),
    (v_outsider, v_other,  'SMA Outsider',      'sma-outsider@test.local',      false, false);

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_modadmin, 'hr', 'admin'),
    (v_tenant, v_member, 'machine_operation', 'admin');

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values
    ('tenant', v_tenant), ('other', v_other),
    ('cadmin', v_cadmin), ('modadmin', v_modadmin), ('member', v_member), ('outsider', v_outsider);
  grant select on test_ids to authenticated;
end $$;

create or replace function pg_temp.become(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object(
      'sub',  (select v from test_ids where k = p_key),
      'role', 'authenticated',
      'aal',  'aal1'
    )::text, true);
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1-4. Company admin: add, restore, finance role, idempotence
-- ---------------------------------------------------------------------
select pg_temp.become('cadmin');
do $$
declare
  v_member uuid := (select v from test_ids where k = 'member');
  r record;
  v_modules jsonb;
  v_rows int;
begin
  -- 1. add a module grant
  select * into r from set_member_access(v_member,
    '[{"module":"machine_operation","role":"admin"},{"module":"sustainability","role":"member"}]'::jsonb, '');
  if r.user_id is distinct from v_member then
    raise exception 'FAIL 1: returned user_id % is not the edited member', r.user_id;
  end if;
  if jsonb_array_length(r.modules) <> 2
     or not r.modules @> '[{"module":"sustainability","role":"member"}]'::jsonb then
    raise exception 'FAIL 1: modules after add were %', r.modules;
  end if;
  if r.finance_role is not null then
    raise exception 'FAIL 1: finance_role should be null, got %', r.finance_role;
  end if;

  -- 2. restoring the original set removes the extra grant (replace-all)
  select * into r from set_member_access(v_member,
    '[{"module":"machine_operation","role":"admin"}]'::jsonb, '');
  if jsonb_array_length(r.modules) <> 1 or r.modules -> 0 ->> 'module' <> 'machine_operation' then
    raise exception 'FAIL 2: modules after restore were %', r.modules;
  end if;

  -- 3. finance role: set, switch (old row cleared), clear
  select * into r from set_member_access(v_member, r.modules, 'finance');
  if r.finance_role is distinct from 'finance' then
    raise exception 'FAIL 3a: finance_role was %', r.finance_role;
  end if;
  select * into r from set_member_access(v_member, r.modules, 'cost_control');
  if r.finance_role is distinct from 'cost_control' then
    raise exception 'FAIL 3b: finance_role was %', r.finance_role;
  end if;
  -- Count as the table owner: finance_team_members is RLS-protected and the
  -- company admin cannot necessarily read it, so a count taken as the caller
  -- would be 0 whatever the function did.
  reset role;
  select count(*) into v_rows from finance_team_members
  where user_id = v_member and tenant_id = (select v from test_ids where k = 'tenant');
  set local role authenticated;
  if v_rows <> 1 then
    raise exception 'FAIL 3b: expected exactly 1 finance_team_members row after switching role, found %', v_rows;
  end if;
  select * into r from set_member_access(v_member, r.modules, '');
  if r.finance_role is not null then
    raise exception 'FAIL 3c: finance_role should be cleared, got %', r.finance_role;
  end if;

  -- 4. idempotent: same input twice, same result, no duplicate rows
  select * into r from set_member_access(v_member,
    '[{"module":"hr","role":"member"}]'::jsonb, 'finance');
  v_modules := r.modules;
  select * into r from set_member_access(v_member,
    '[{"module":"hr","role":"member"}]'::jsonb, 'finance');
  if r.modules is distinct from v_modules or r.finance_role is distinct from 'finance' then
    raise exception 'FAIL 4: second identical call changed the result (% vs %)', r.modules, v_modules;
  end if;

  -- NULL modules clears every grant
  select * into r from set_member_access(v_member, null, '');
  if jsonb_array_length(r.modules) <> 0 then
    raise exception 'FAIL 4: NULL p_modules should clear all grants, got %', r.modules;
  end if;

  raise notice 'PASS: 1-4. company admin adds, restores, switches finance role, idempotent';
end $$;

-- ---------------------------------------------------------------------
-- 5. Non-company-admins are refused
-- ---------------------------------------------------------------------
do $$
declare
  v_who text;
  v_member uuid := (select v from test_ids where k = 'member');
  v_refused boolean;
begin
  foreach v_who in array array['modadmin', 'member'] loop
    perform pg_temp.become(v_who);
    v_refused := false;
    begin
      perform set_member_access(v_member,
        '[{"module":"procurement","role":"admin"}]'::jsonb, 'finance');
    exception when others then
      if sqlerrm like 'not authorized%' then v_refused := true; else raise; end if;
    end;
    if not v_refused then
      raise exception 'FAIL 5: % was allowed to call set_member_access', v_who;
    end if;
  end loop;
  raise notice 'PASS: 5. module admin and plain member are refused';
end $$;

-- ---------------------------------------------------------------------
-- 6 + 7. Cross-tenant target and invalid finance role (as company admin)
-- ---------------------------------------------------------------------
select pg_temp.become('cadmin');
do $$
declare
  v_outsider uuid := (select v from test_ids where k = 'outsider');
  v_member   uuid := (select v from test_ids where k = 'member');
  v_refused boolean := false;
begin
  begin
    perform set_member_access(v_outsider, '[{"module":"hr","role":"admin"}]'::jsonb, '');
  exception when others then
    if sqlerrm like 'user not found in this tenant%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 6: changed a user of another tenant'; end if;

  v_refused := false;
  begin
    perform set_member_access(v_member, '[]'::jsonb, 'superuser');
  exception when others then
    if sqlerrm like 'invalid finance role%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 7: accepted an invalid finance role'; end if;

  raise notice 'PASS: 6+7. cross-tenant target and invalid finance role are refused';
end $$;

rollback;
