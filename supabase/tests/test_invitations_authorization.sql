-- Regression test for:
--   supabase/migrations/20261002054037_invitations_company_admin_only.sql
--
-- Invitations (SELECT / INSERT policies and revoke_invitation()) must be
-- keyed to is_tenant_admin() -- the company admin -- and NOT to "admin of
-- any module" (staff_roles.role = 'admin').
--
-- Verifies, against a fully-migrated fresh stack:
--   1. A company admin with NO staff_roles row can INSERT a member
--      invitation, SELECT it, and revoke it through revoke_invitation().
--   2. A company admin still cannot INSERT a role_bundle='company_admin'
--      invitation directly (only platform admins / the edge function mint
--      those).
--   3. A module admin who is NOT a company admin (staff_roles hr/admin)
--      sees no invitations, cannot INSERT one, and cannot revoke one.
--      This is the privilege-escalation path: a direct invitation row
--      choosing modules_and_roles / finance_role is later honoured by
--      accept-invite.
--   4. An ordinary member (no roles) is refused the same three ways.
--   5. A company admin of ANOTHER tenant cannot see, create or revoke
--      invitations of this tenant.
--   6. A revoked invitation cannot be revoked again.
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
  v_cadmin   uuid := gen_random_uuid();  -- company admin, NO staff_roles row
  v_modadmin uuid := gen_random_uuid();  -- hr module admin, not a company admin
  v_member   uuid := gen_random_uuid();  -- ordinary member, no roles
  v_other_ca uuid := gen_random_uuid();  -- company admin of the other tenant
  v_inv_a    uuid := gen_random_uuid();  -- pending invitation, for revoke tests
  v_inv_b    uuid := gen_random_uuid();  -- pending invitation, for refused revokes
begin
  insert into tenants (id, name, status) values
    (v_tenant, 'Invitations Test Co',       'active'),
    (v_other,  'Invitations Test Other Co', 'active');

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
    (v_cadmin,   'inv-company-admin'),
    (v_modadmin, 'inv-module-admin'),
    (v_member,   'inv-plain-member'),
    (v_other_ca, 'inv-other-company-admin')
  ) as u(id, handle);

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin) values
    (v_cadmin,   v_tenant, 'Inv Company Admin', 'inv-company-admin@test.local',       false, true),
    (v_modadmin, v_tenant, 'Inv Module Admin',  'inv-module-admin@test.local',        false, false),
    (v_member,   v_tenant, 'Inv Plain Member',  'inv-plain-member@test.local',        false, false),
    (v_other_ca, v_other,  'Inv Other CA',      'inv-other-company-admin@test.local', false, true);

  -- The module admin: admin of one module, deliberately not a company admin.
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_modadmin, 'hr', 'admin');

  -- Pending invitations created as the table owner (the edge function path).
  insert into invitations (id, tenant_id, email, invited_by, role_bundle, modules_and_roles, status) values
    (v_inv_a, v_tenant, 'inv-pending-a@test.local', v_cadmin, 'member',
       '[{"module":"hr","role":"member"}]'::jsonb, 'pending'),
    (v_inv_b, v_tenant, 'inv-pending-b@test.local', v_cadmin, 'member',
       '[{"module":"hr","role":"member"}]'::jsonb, 'pending');

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values
    ('tenant', v_tenant), ('other', v_other),
    ('cadmin', v_cadmin), ('modadmin', v_modadmin), ('member', v_member), ('other_ca', v_other_ca),
    ('inv_a', v_inv_a), ('inv_b', v_inv_b);
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
-- 1. Company admin (no staff_roles row) manages invitations
-- ---------------------------------------------------------------------
select pg_temp.become('cadmin');
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_cadmin uuid := (select v from test_ids where k = 'cadmin');
  v_inv_a  uuid := (select v from test_ids where k = 'inv_a');
  v_seen int;
  v_new  uuid;
  v_status text;
begin
  if exists (select 1 from staff_roles where user_id = v_cadmin) then
    raise exception 'FIXTURE: company admin must have no staff_roles row';
  end if;

  select count(*) into v_seen from invitations where tenant_id = v_tenant;
  if v_seen < 2 then
    raise exception 'FAIL: company admin sees % invitations of own tenant, expected at least 2', v_seen;
  end if;

  insert into invitations (tenant_id, email, invited_by, role_bundle, modules_and_roles)
  values (v_tenant, 'inv-created-by-ca@test.local', v_cadmin, 'member',
          '[{"module":"hr","role":"member"}]'::jsonb)
  returning id into v_new;
  if v_new is null then raise exception 'FAIL: company admin could not INSERT a member invitation'; end if;

  perform revoke_invitation(v_inv_a);
  select status into v_status from invitations where id = v_inv_a;
  if v_status is distinct from 'revoked' then
    raise exception 'FAIL: company admin revoke left status %', v_status;
  end if;

  raise notice 'PASS: 1. company admin without staff_roles lists, creates and revokes invitations';
end $$;

-- ---------------------------------------------------------------------
-- 2. Company admin cannot mint a company_admin invitation directly
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_cadmin uuid := (select v from test_ids where k = 'cadmin');
  v_refused boolean := false;
begin
  begin
    insert into invitations (tenant_id, email, invited_by, role_bundle)
    values (v_tenant, 'inv-escalate-ca@test.local', v_cadmin, 'company_admin');
  exception when insufficient_privilege then
    v_refused := true;
  end;
  if not v_refused then
    raise exception 'FAIL: company admin inserted a role_bundle=company_admin invitation directly';
  end if;
  raise notice 'PASS: 2. company_admin bundle cannot be inserted directly';
end $$;

-- ---------------------------------------------------------------------
-- 3 + 4. Non-company-admins (module admin, plain member): no read, no
--        insert, no revoke
-- ---------------------------------------------------------------------
do $$
declare
  v_who text;
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_inv_b  uuid := (select v from test_ids where k = 'inv_b');
  v_seen int;
  v_refused boolean;
  v_status text;
begin
  foreach v_who in array array['modadmin', 'member'] loop
    perform pg_temp.become(v_who);

    select count(*) into v_seen from invitations where tenant_id = v_tenant;
    if v_seen <> 0 then
      raise exception 'FAIL: % can SELECT % invitations of the tenant', v_who, v_seen;
    end if;

    v_refused := false;
    begin
      insert into invitations (tenant_id, email, invited_by, role_bundle, modules_and_roles, finance_role)
      values (v_tenant, 'inv-escalate-' || v_who || '@test.local',
              (select v from test_ids where k = v_who), 'member',
              '[{"module":"hr","role":"admin"},{"module":"procurement","role":"admin"}]'::jsonb,
              'finance');
    exception when insufficient_privilege then
      v_refused := true;
    end;
    if not v_refused then
      raise exception 'FAIL: % inserted an invitation granting modules and finance access', v_who;
    end if;

    v_refused := false;
    begin
      perform revoke_invitation(v_inv_b);
    exception when others then
      if sqlerrm like 'Not authorized%' then v_refused := true; else raise; end if;
    end;
    if not v_refused then
      raise exception 'FAIL: % could revoke an invitation', v_who;
    end if;
  end loop;

  reset role;
  select status into v_status from invitations where id = v_inv_b;
  if v_status <> 'pending' then
    raise exception 'FAIL: invitation changed to % despite refused revokes', v_status;
  end if;
  set local role authenticated;

  raise notice 'PASS: 3+4. module admin and plain member are refused read, insert and revoke';
end $$;

-- ---------------------------------------------------------------------
-- 5. Another tenant's company admin
-- ---------------------------------------------------------------------
select pg_temp.become('other_ca');
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_other_ca uuid := (select v from test_ids where k = 'other_ca');
  v_inv_b  uuid := (select v from test_ids where k = 'inv_b');
  v_seen int;
  v_refused boolean := false;
begin
  select count(*) into v_seen from invitations where tenant_id = v_tenant;
  if v_seen <> 0 then
    raise exception 'FAIL: other tenant company admin sees % invitations', v_seen;
  end if;

  begin
    insert into invitations (tenant_id, email, invited_by, role_bundle)
    values (v_tenant, 'inv-cross-tenant@test.local', v_other_ca, 'member');
  exception when insufficient_privilege then
    v_refused := true;
  end;
  if not v_refused then raise exception 'FAIL: cross-tenant invitation INSERT succeeded'; end if;

  v_refused := false;
  begin
    perform revoke_invitation(v_inv_b);
  exception when others then
    if sqlerrm like 'Not authorized%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL: cross-tenant revoke succeeded'; end if;

  raise notice 'PASS: 5. cross-tenant company admin is refused';
end $$;

-- ---------------------------------------------------------------------
-- 6. A revoked invitation cannot be revoked again
-- ---------------------------------------------------------------------
select pg_temp.become('cadmin');
do $$
declare
  v_inv_a uuid := (select v from test_ids where k = 'inv_a');  -- revoked in step 1
  v_refused boolean := false;
begin
  begin
    perform revoke_invitation(v_inv_a);
  exception when others then
    if sqlerrm like 'Only pending invitations can be revoked%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL: a revoked invitation was revoked twice'; end if;
  raise notice 'PASS: 6. second revoke is refused';
end $$;

rollback;
