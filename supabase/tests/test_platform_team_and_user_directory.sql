-- Regression test for:
--   supabase/migrations/20260922200000_platform_team_and_user_directory.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. A non-platform user cannot call set_platform_admin,
--      list_platform_admins or platform_users_directory
--      (PLATFORM_ADMIN_REQUIRED), and cannot flip is_platform_admin on
--      their own row (PLATFORM_ADMIN_GUARD).
--   2. set_platform_admin: reason required; grant works and is audited
--      with before/after; two admins can coexist (old single-admin index
--      is gone); list_platform_admins shows both with mfa/granted_by;
--      re-granting is a no-op (no second audit row).
--   3. set_platform_admin revoke: cannot revoke yourself; revoke of the
--      other admin ends their open View-as session and is audited; the
--      last remaining admin cannot be revoked (PLATFORM_LAST_ADMIN).
--   4. Service-role bootstrap path: inserting a second is_platform_admin
--      row via service_role raises 23505 naming
--      app_users_single_platform_admin (what bootstrap-admin handles);
--      migrations/seeds (no JWT) are unaffected.
--   5. platform_users_directory: search, tenant, kind, module and
--      quiet-days filters; total_count; modules/finance_role/mfa columns.
--   6. View as a specific user: start_impersonation(tenant, reason, user)
--      refuses users outside the tenant and platform admins; while active
--      has_module_role / is_tenant_admin / is_finance_team_member /
--      can_access_finance evaluate the TARGET user's rows (no bypass);
--      get_active_impersonation + list_impersonation_history carry the
--      user; the read-only guard applies; ending restores full bypass;
--      company-level View-as (2-arg) still bypasses.
--
-- Run against a fresh local stack only (`supabase start`, then
-- `psql -f`) -- never against a linked/remote project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant   uuid := gen_random_uuid();
  v_other    uuid := gen_random_uuid();
  v_home     uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();   -- platform admin (primary)
  v_second   uuid := gen_random_uuid();   -- will be granted platform admin
  v_cadmin   uuid := gen_random_uuid();   -- customer company admin
  v_hr       uuid := gen_random_uuid();   -- hr member + finance cost_control
  v_plain    uuid := gen_random_uuid();   -- member with nothing
  v_other_u  uuid := gen_random_uuid();   -- user in another tenant
begin
  insert into tenants (id, name, status) values
    (v_tenant, 'Team Test Customer Co', 'active'),
    (v_other,  'Team Test Other Co',    'active'),
    (v_home,   'Team Test Platform Home', 'active');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', u.lsi
  from (values
    (v_admin,   'team-platform-admin', now()),
    (v_second,  'team-second-admin',   now()),
    (v_cadmin,  'team-customer-admin', now()),
    (v_hr,      'team-hr-member',      now() - interval '90 days'),
    (v_plain,   'team-plain-member',   null::timestamptz),
    (v_other_u, 'team-other-user',     now())
  ) as u(id, handle, lsi);

  -- Seed data may already hold platform admins; neutralise inside this
  -- transaction (rolled back at the end). No JWT -> guard trigger is idle.
  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin) values
    (v_admin,   v_home,   'Platform Admin',  'team-platform-admin@test.local', true,  false),
    (v_second,  v_home,   'Second Operator', 'team-second-admin@test.local',   false, false),
    (v_cadmin,  v_tenant, 'Customer Admin',  'team-customer-admin@test.local', false, true),
    (v_hr,      v_tenant, 'HR Person',       'team-hr-member@test.local',      false, false),
    (v_plain,   v_tenant, 'Plain Person',    'team-plain-member@test.local',   false, false),
    (v_other_u, v_other,  'Other Person',    'team-other-user@test.local',     false, true);

  insert into tenant_modules (tenant_id, module) values (v_tenant, 'hr'), (v_tenant, 'procurement'), (v_tenant, 'legal')
  on conflict do nothing;

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_cadmin, 'hr', 'admin'),
    (v_tenant, v_cadmin, 'procurement', 'admin'),
    (v_tenant, v_hr,     'hr', 'member');

  insert into finance_team_members (tenant_id, user_id, role) values (v_tenant, v_hr, 'cost_control');

  insert into auth.mfa_factors (user_id, friendly_name, factor_type, status)
  values (v_cadmin, 'phone', 'totp', 'verified');

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values
    ('tenant', v_tenant), ('other', v_other), ('home', v_home),
    ('admin', v_admin), ('second', v_second), ('cadmin', v_cadmin),
    ('hr', v_hr), ('plain', v_plain), ('other_u', v_other_u);
  grant select on test_ids to authenticated, service_role;
end $$;

create or replace function pg_temp.become(p_key text, p_role text default 'authenticated', p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object(
      'sub',  (select v from test_ids where k = p_key),
      'role', p_role,
      'aal',  p_aal
    )::text, true);
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Non-platform user is refused everywhere
-- ---------------------------------------------------------------------
select pg_temp.become('cadmin');

do $$
declare
  v_second uuid := (select v from test_ids where k = 'second');
  v_cadmin uuid := (select v from test_ids where k = 'cadmin');
  v_n int;
begin
  begin
    perform set_platform_admin(v_second, true, 'trying to promote a friend');
    raise exception 'FAIL: customer admin could call set_platform_admin';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform count(*) from list_platform_admins();
    raise exception 'FAIL: customer admin could list platform admins';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform count(*) from platform_users_directory();
    raise exception 'FAIL: customer admin could read the user directory';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  -- Direct flip on own row: RLS may hide it or the guard may refuse it;
  -- either way the flag must not change.
  begin
    update app_users set is_platform_admin = true where id = v_cadmin;
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_GUARD%' then raise exception 'FAIL: unexpected direct-flip error: %', sqlerrm; end if;
  end;
  if (select is_platform_admin from app_users where id = v_cadmin) then
    raise exception 'FAIL: customer admin promoted themselves';
  end if;

  raise notice 'PASS: 1. non-platform user refused (RPCs + direct flag flip)';
end $$;

-- ---------------------------------------------------------------------
-- 2. Grant a second platform admin
-- ---------------------------------------------------------------------
select pg_temp.become('admin');

do $$
declare
  v_second uuid := (select v from test_ids where k = 'second');
  r app_users%rowtype;
  ev platform_audit_events%rowtype;
  t record;
  v_n int;
begin
  begin
    perform set_platform_admin(v_second, true, '   ');
    raise exception 'FAIL: grant accepted without a reason';
  exception when others then
    if sqlerrm not like '%reason%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  r := set_platform_admin(v_second, true, 'Joining the operations team');
  if not r.is_platform_admin then raise exception 'FAIL: grant did not set the flag'; end if;

  select * into ev from platform_audit_events
  where action = 'platform_admin.grant' and target_id = v_second::text
  order by created_at desc limit 1;
  if not found or ev.reason <> 'Joining the operations team'
     or (ev.before->>'is_platform_admin')::boolean or not (ev.after->>'is_platform_admin')::boolean then
    raise exception 'FAIL: grant not audited correctly: %', to_jsonb(ev);
  end if;

  -- Two admins at once: the old partial unique index would have refused.
  if (select count(*) from app_users where is_platform_admin) <> 2 then
    raise exception 'FAIL: expected two platform admins';
  end if;

  select count(*) into v_n from list_platform_admins();
  if v_n <> 2 then raise exception 'FAIL: list_platform_admins returned % rows', v_n; end if;
  select * into t from list_platform_admins() where user_id = v_second;
  if t.granted_by_email <> 'team-platform-admin@test.local' or t.mfa_enrolled or not t.tenant_name like 'Team Test Platform Home' then
    raise exception 'FAIL: list_platform_admins row wrong: %', to_jsonb(t);
  end if;
  select * into t from list_platform_admins() where is_self;
  if t.email <> 'team-platform-admin@test.local' then raise exception 'FAIL: is_self not flagged'; end if;

  -- Idempotent re-grant: no new audit row.
  select count(*) into v_n from platform_audit_events where action = 'platform_admin.grant' and target_id = v_second::text;
  r := set_platform_admin(v_second, true, 'Joining again for no reason');
  if (select count(*) from platform_audit_events where action = 'platform_admin.grant' and target_id = v_second::text) <> v_n then
    raise exception 'FAIL: re-grant produced a duplicate audit row';
  end if;

  raise notice 'PASS: 2. grant requires reason, is audited, allows multiple admins, listed';
end $$;

-- ---------------------------------------------------------------------
-- 3. Revoke rules
-- ---------------------------------------------------------------------
do $$
declare
  v_admin  uuid := (select v from test_ids where k = 'admin');
  v_second uuid := (select v from test_ids where k = 'second');
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  r app_users%rowtype;
begin
  begin
    perform set_platform_admin(v_admin, false, 'Stepping down');
    raise exception 'FAIL: could revoke self';
  exception when others then
    if sqlerrm not like '%remove yourself%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  raise notice 'PASS: 3a. cannot revoke yourself';
end $$;

-- Second admin opens a View-as session, then gets revoked by the first.
select pg_temp.become('second');
select start_impersonation((select v from test_ids where k = 'tenant'), 'Looking into a ticket');
do $$
begin
  if (select count(*) from get_active_impersonation()) <> 1 then raise exception 'FAIL: second admin session not active'; end if;
end $$;

select pg_temp.become('admin');
do $$
declare
  v_admin  uuid := (select v from test_ids where k = 'admin');
  v_second uuid := (select v from test_ids where k = 'second');
  r app_users%rowtype;
begin
  r := set_platform_admin(v_second, false, 'Left the company');
  if r.is_platform_admin then raise exception 'FAIL: revoke did not clear the flag'; end if;
  if exists (select 1 from impersonation_sessions where platform_admin_id = v_second and ended_at is null) then
    raise exception 'FAIL: revoked admin still has an open View-as session';
  end if;
  if not exists (select 1 from platform_audit_events where action = 'platform_admin.revoke' and target_id = v_second::text and reason = 'Left the company') then
    raise exception 'FAIL: revoke not audited';
  end if;
  raise notice 'PASS: 3b. revoke ends open sessions and is audited';
end $$;

-- Last-admin guard: with only 'admin' left, nobody else can revoke them,
-- and the guard trigger refuses too (service_role path).
reset role;
select pg_temp.become('admin', 'service_role');
do $$
declare v_admin uuid := (select v from test_ids where k = 'admin');
begin
  begin
    update app_users set is_platform_admin = false where id = v_admin;
    raise exception 'FAIL: last admin removed via service_role update';
  exception when others then
    if sqlerrm not like 'PLATFORM_LAST_ADMIN%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  raise notice 'PASS: 3c. last platform admin cannot be removed';
end $$;

-- ---------------------------------------------------------------------
-- 4. Bootstrap path keeps its 23505 contract
-- ---------------------------------------------------------------------
do $$
declare v_plain uuid := (select v from test_ids where k = 'plain');
begin
  begin
    update app_users set is_platform_admin = true where id = v_plain;
    raise exception 'FAIL: service_role could create a second admin outside set_platform_admin';
  exception when unique_violation then
    if sqlerrm not like '%app_users_single_platform_admin%' then raise exception 'FAIL: 23505 without the constraint name: %', sqlerrm; end if;
  end;
  if (select is_platform_admin from app_users where id = v_plain) then raise exception 'FAIL: flag changed'; end if;
  raise notice 'PASS: 4. service_role second-admin insert raises 23505 (bootstrap contract)';
end $$;

-- ---------------------------------------------------------------------
-- 5. Directory filters
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('admin');

do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_other  uuid := (select v from test_ids where k = 'other');
  t record; v_n int; v_total bigint;
begin
  -- search by email fragment, scoped to our fixture tenants via prefix
  select count(*), max(total_count) into v_n, v_total from platform_users_directory(p_search => 'team-');
  if v_n <> 6 or v_total <> 6 then raise exception 'FAIL: search returned %/% rows', v_n, v_total; end if;

  select count(*) into v_n from platform_users_directory(p_search => 'team-', p_tenant_id => v_tenant);
  if v_n <> 3 then raise exception 'FAIL: tenant filter returned %', v_n; end if;

  select count(*) into v_n from platform_users_directory(p_search => 'team-', p_kind => 'company_admin');
  if v_n <> 2 then raise exception 'FAIL: company_admin kind returned %', v_n; end if;

  select count(*) into v_n from platform_users_directory(p_search => 'team-', p_kind => 'platform_admin');
  if v_n <> 1 then raise exception 'FAIL: platform_admin kind returned %', v_n; end if;

  select count(*) into v_n from platform_users_directory(p_search => 'team-', p_kind => 'finance');
  if v_n <> 1 then raise exception 'FAIL: finance kind returned %', v_n; end if;

  select count(*) into v_n from platform_users_directory(p_search => 'team-', p_module => 'hr');
  if v_n <> 2 then raise exception 'FAIL: module=hr returned %', v_n; end if;

  -- quiet 60 days: hr (90 days ago) + plain (never)
  select count(*) into v_n from platform_users_directory(p_search => 'team-', p_quiet_days => 60);
  if v_n <> 2 then raise exception 'FAIL: quiet filter returned %', v_n; end if;

  -- paging
  select count(*), max(total_count) into v_n, v_total from platform_users_directory(p_search => 'team-', p_limit => 2, p_offset => 4);
  if v_n <> 2 or v_total <> 6 then raise exception 'FAIL: paging %/%', v_n, v_total; end if;

  select * into t from platform_users_directory(p_search => 'team-customer-admin');
  if not t.mfa_enrolled or not t.is_company_admin or jsonb_array_length(t.modules) <> 2 or t.tenant_name <> 'Team Test Customer Co' then
    raise exception 'FAIL: customer admin row wrong: %', to_jsonb(t);
  end if;
  select * into t from platform_users_directory(p_search => 'team-hr-member');
  if t.finance_role <> 'cost_control' or t.mfa_enrolled or t.last_sign_in_at > now() - interval '80 days' then
    raise exception 'FAIL: hr member row wrong: %', to_jsonb(t);
  end if;

  raise notice 'PASS: 5. directory search / tenant / kind / module / quiet / paging';
end $$;

-- ---------------------------------------------------------------------
-- 6. View as a specific user
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant  uuid := (select v from test_ids where k = 'tenant');
  v_other   uuid := (select v from test_ids where k = 'other');
  v_admin   uuid := (select v from test_ids where k = 'admin');
  v_hr      uuid := (select v from test_ids where k = 'hr');
  v_other_u uuid := (select v from test_ids where k = 'other_u');
  s impersonation_sessions%rowtype;
  a record; h record;
begin
  begin
    perform start_impersonation(v_tenant, 'wrong tenant for this user', v_other_u);
    raise exception 'FAIL: impersonated a user from another tenant';
  exception when others then
    if sqlerrm not like 'No such user in this company%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform start_impersonation((select v from test_ids where k = 'home'), 'impersonating an operator', v_admin);
    raise exception 'FAIL: impersonated a platform admin';
  exception when others then
    if sqlerrm not like 'Platform admins cannot be impersonated%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  -- Baseline: company-level View-as = full bypass.
  perform start_impersonation(v_tenant, 'Company-level look');
  if not has_module_role('legal', array['admin']) or not is_tenant_admin() or not can_access_finance() or not platform_admin_bypass() then
    raise exception 'FAIL: company-level View-as lost the bypass';
  end if;

  -- View as the HR member: hr member yes; hr admin no; legal no; not
  -- tenant admin; finance yes via cost_control; no bypass.
  s := start_impersonation(v_tenant, 'Reproducing: cannot see payroll', v_hr);
  if s.impersonated_user_id <> v_hr then raise exception 'FAIL: session did not record the user'; end if;
  if impersonated_user_id() <> v_hr or effective_user_id() <> v_hr then raise exception 'FAIL: effective_user_id not the target'; end if;
  if platform_admin_bypass() then raise exception 'FAIL: bypass still on while viewing as a user'; end if;
  if not is_platform_admin() then raise exception 'FAIL: is_platform_admin must still identify the operator'; end if;
  if get_my_tenant_id() <> v_tenant then raise exception 'FAIL: tenant not switched'; end if;
  if not has_module_role('hr', array['member']) then raise exception 'FAIL: hr member role not seen'; end if;
  if has_module_role('hr', array['admin']) then raise exception 'FAIL: hr admin granted to a member'; end if;
  if has_module_role('legal', array['admin','manager','member']) then raise exception 'FAIL: legal granted without staff_roles'; end if;
  if is_tenant_admin() or is_company_admin() then raise exception 'FAIL: tenant admin granted to a member'; end if;
  if is_any_module_admin() then raise exception 'FAIL: module admin granted to a member'; end if;
  if not is_finance_team_member('cost_control') or is_finance_team_member('finance') then raise exception 'FAIL: finance role mismatch'; end if;
  if not can_access_finance() then raise exception 'FAIL: cost_control should reach finance'; end if;
  if has_po_access() then raise exception 'FAIL: PO access granted without assignments'; end if;
  -- The operator's console still works while viewing as a user.
  if (select count(*) from list_platform_admins()) < 1 then raise exception 'FAIL: console RPC broke under user View-as'; end if;

  select * into a from get_active_impersonation();
  if a.impersonated_user_id <> v_hr or a.impersonated_user_email <> 'team-hr-member@test.local' or a.impersonated_user_name <> 'HR Person' then
    raise exception 'FAIL: get_active_impersonation missing user: %', to_jsonb(a);
  end if;
  select * into h from list_impersonation_history(v_tenant) where is_active;
  if h.impersonated_user_email <> 'team-hr-member@test.local' then raise exception 'FAIL: history missing user'; end if;
  if not exists (select 1 from platform_audit_events where action = 'impersonation.start' and target_type = 'app_user' and target_id = v_hr::text and (after->>'as_user_email') = 'team-hr-member@test.local') then
    raise exception 'FAIL: user-level start not audited';
  end if;

  raise notice 'PASS: 6a. viewing as a user evaluates that user''s permissions, no bypass';
end $$;

-- Read-only guard applies to the operator while viewing as a user.
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_cadmin uuid := (select v from test_ids where k = 'cadmin');
begin
  perform set_tenant_read_only(v_tenant, true, 'Billing hold for test');
  -- View as the company admin (module admin -> departments write policy passes)
  perform start_impersonation(v_tenant, 'Check what the admin sees during hold', v_cadmin);
  begin
    insert into departments (tenant_id, name) values (v_tenant, 'Should be refused');
    raise exception 'FAIL: write allowed while viewing as a user in a read-only tenant';
  exception when others then
    if sqlerrm not like 'TENANT_READ_ONLY%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  perform end_impersonation();
  -- Company-level: still exempt (operator fixing things).
  perform start_impersonation(v_tenant, 'Fixing during hold');
  insert into departments (tenant_id, name) values (v_tenant, 'Operator dept');
  perform end_impersonation();
  perform set_tenant_read_only(v_tenant, false, null);
  raise notice 'PASS: 6b. read-only guard applies when viewing as a user, not company-level';
end $$;

-- End restores full bypass.
do $$
declare v_home uuid := (select v from test_ids where k = 'home');
begin
  if impersonated_user_id() is not null or not platform_admin_bypass() or get_my_tenant_id() <> v_home then
    raise exception 'FAIL: bypass not restored after end';
  end if;
  if not has_module_role('legal', array['admin']) then raise exception 'FAIL: module bypass not restored'; end if;
  raise notice 'PASS: 6c. ending the session restores the platform bypass';
end $$;

-- ---------------------------------------------------------------------
-- 7. update_app_user no longer flips the flag
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_plain  uuid := (select v from test_ids where k = 'plain');
  r app_users%rowtype;
begin
  perform start_impersonation(v_tenant, 'Account admin check');
  begin
    r := update_app_user(v_plain, null, 'Clerk', true);
    raise exception 'FAIL: update_app_user promoted a user';
  exception when others then
    if sqlerrm not like '%managed from the platform console%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  r := update_app_user(v_plain, null, 'Clerk', null);
  if r.role_title <> 'Clerk' or r.is_platform_admin then raise exception 'FAIL: benign update_app_user broke'; end if;
  perform end_impersonation();
  raise notice 'PASS: 7. update_app_user refuses platform-admin changes, still edits titles';
end $$;

rollback;
