-- Regression test for:
--   supabase/migrations/20260922180000_tenant_profile_and_subscription.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. Existing tenants carry sane defaults (plan trial, trialing, not
--      read-only, no seat limit); the platform home tenant is 'internal'.
--   2. update_tenant_profile: platform admin can patch whitelisted keys;
--      unknown keys, blank name, bad email, bad plan are refused; the
--      audit row holds only the changed keys; a no-change patch writes
--      nothing; non-platform users are refused.
--   3. set_tenant_read_only: reason required to enable; audited on/off;
--      read_only_since/reason cleared on disable.
--   4. Read-only guard: while read_only, an ordinary tenant user cannot
--      INSERT/UPDATE/DELETE a tenant-scoped row (TENANT_READ_ONLY:), can
--      still SELECT, can still mark notifications read; a platform admin
--      (View-as) can still write; users of *other* tenants are unaffected;
--      writes succeed again once read-only is switched off.
--   5. Seat limit: with seat_limit = members + pending, a new invitation
--      is refused (SEAT_LIMIT_REACHED:); raising the limit lets it through;
--      NULL = unlimited.
--   6. add_tenant_note / tenant_notes: platform admin only; customer
--      cannot read notes even for their own tenant.
--   7. get_tenant_profile returns seats/activity/last_status_event/
--      recent_events; get_my_tenant_access reflects read-only + plan for
--      the customer; get_companies_overview carries the new columns.
--   8. set_tenant_status stamps status_changed_at.
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
  v_home     uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();
  v_user     uuid := gen_random_uuid();   -- ordinary user in v_tenant (company admin so they may write departments)
  v_other_u  uuid := gen_random_uuid();   -- ordinary user in v_other
  v_dept     uuid := gen_random_uuid();
begin
  insert into tenants (id, name, status) values
    (v_tenant, 'Profile Test Customer Co', 'active'),
    (v_other,  'Profile Test Other Co',    'active'),
    (v_home,   'Profile Test Platform Home', 'active');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', now() - interval '3 days'
  from (values
    (v_admin,   'profile-platform-admin'),
    (v_user,    'profile-customer-admin'),
    (v_other_u, 'profile-other-user')
  ) as u(id, handle);

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin) values
    (v_admin,   v_home,   'Platform Admin', 'profile-platform-admin@test.local', true,  false),
    (v_user,    v_tenant, 'Customer Admin', 'profile-customer-admin@test.local', false, true),
    (v_other_u, v_other,  'Other User',     'profile-other-user@test.local',     false, true);

  -- departments' write policies need is_any_module_admin() (staff_roles
  -- role='admin'); give both customer users that so RLS is not what
  -- blocks them -- the read-only guard must be the thing that refuses.
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_user,    'procurement', 'admin'),
    (v_other,  v_other_u, 'procurement', 'admin');

  -- departments has a BEFORE INSERT trigger that overwrites tenant_id
  -- from get_my_tenant_id(); pose as each tenant's user for the seed rows.
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  insert into departments (id, tenant_id, name) values (v_dept, v_tenant, 'Profile Test Dept');
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_u, 'role', 'authenticated')::text, true);
  insert into departments (tenant_id, name) values (v_other, 'Other Dept');
  perform set_config('request.jwt.claims', '', true);

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (v_tenant, v_user, 'test', 'Read-only test notification', 'body');

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values
    ('tenant', v_tenant), ('other', v_other), ('home', v_home),
    ('admin', v_admin), ('user', v_user), ('other_u', v_other_u), ('dept', v_dept);
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

-- ---------------------------------------------------------------------
-- 1. Defaults
-- ---------------------------------------------------------------------
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant'); r tenants;
begin
  select * into r from tenants where id = v_tenant;
  if r.plan <> 'trial' or r.subscription_status <> 'trialing' or r.read_only or r.seat_limit is not null or r.country <> 'UG' then
    raise exception 'FAIL: unexpected defaults: %', to_jsonb(r);
  end if;
  if exists (select 1 from tenants where id = '00000000-0000-0000-0000-000000000099' and plan <> 'internal') then
    raise exception 'FAIL: platform home tenant should be plan=internal';
  end if;
  raise notice 'PASS: 1. defaults';
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 2. update_tenant_profile
-- ---------------------------------------------------------------------
select pg_temp.become('user');
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant');
begin
  begin
    perform update_tenant_profile(v_tenant, '{"plan":"enterprise"}');
    raise exception 'FAIL: customer could edit own profile via update_tenant_profile';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
end $$;

select pg_temp.become('admin');
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  r tenants; e platform_audit_events; n0 int;
begin
  select count(*) into n0 from platform_audit_events;

  r := update_tenant_profile(v_tenant, jsonb_build_object(
    'contact_name', '  Jane Doe ', 'contact_email', 'Jane@Example.com', 'plan', 'standard',
    'subscription_status', 'active', 'seat_limit', 5, 'trial_ends_at', null));
  if r.contact_name <> 'Jane Doe' or r.contact_email <> 'jane@example.com' or r.plan <> 'standard'
     or r.subscription_status <> 'active' or r.seat_limit <> 5 or r.trial_ends_at is not null then
    raise exception 'FAIL: patch not applied: %', to_jsonb(r);
  end if;
  if r.updated_at is null or r.updated_at < now() - interval '1 minute' then
    raise exception 'FAIL: updated_at not touched';
  end if;

  select * into e from platform_audit_events where tenant_id = v_tenant and action = 'tenant.profile.update' order by created_at desc limit 1;
  if e.id is null then raise exception 'FAIL: no audit row for profile update'; end if;
  if e.after ? 'trial_ends_at' then raise exception 'FAIL: unchanged key (trial_ends_at null->null) should not be in diff: %', e.after; end if;
  if (e.after->>'plan') <> 'standard' or (e.before->>'plan') <> 'trial' or (e.after->>'seat_limit')::int <> 5 then
    raise exception 'FAIL: diff wrong: before=% after=%', e.before, e.after;
  end if;

  -- No-op patch writes nothing.
  select count(*) into n0 from platform_audit_events;
  perform update_tenant_profile(v_tenant, '{"plan":"standard"}');
  if (select count(*) from platform_audit_events) <> n0 then raise exception 'FAIL: no-op patch was audited'; end if;

  begin
    perform update_tenant_profile(v_tenant, '{"status":"suspended"}');
    raise exception 'FAIL: status editable via profile patch';
  exception when others then
    if sqlerrm not like '%cannot be edited%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform update_tenant_profile(v_tenant, '{"name":"   "}');
    raise exception 'FAIL: blank name accepted';
  exception when others then
    if sqlerrm not like '%cannot be blank%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform update_tenant_profile(v_tenant, '{"contact_email":"not-an-email"}');
    raise exception 'FAIL: bad email accepted';
  exception when others then
    if sqlerrm not like '%email%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform update_tenant_profile(v_tenant, '{"plan":"platinum"}');
    raise exception 'FAIL: bad plan accepted';
  exception when check_violation then null;
  end;
  begin
    perform update_tenant_profile(v_tenant, '{"seat_limit":0}');
    raise exception 'FAIL: seat_limit 0 accepted';
  exception when check_violation then null;
  end;
  raise notice 'PASS: 2. update_tenant_profile';
end $$;

-- ---------------------------------------------------------------------
-- 3. set_tenant_read_only
-- ---------------------------------------------------------------------
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant'); r tenants;
begin
  begin
    perform set_tenant_read_only(v_tenant, true, '   ');
    raise exception 'FAIL: read-only enabled without reason';
  exception when others then
    if sqlerrm not like '%reason is required%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  r := set_tenant_read_only(v_tenant, true, 'Invoice 60 days overdue');
  if not r.read_only or r.read_only_reason <> 'Invoice 60 days overdue' or r.read_only_since is null then
    raise exception 'FAIL: read-only not applied: %', to_jsonb(r);
  end if;
  if not exists (select 1 from platform_audit_events where tenant_id = v_tenant and action = 'tenant.read_only.on' and reason = 'Invoice 60 days overdue') then
    raise exception 'FAIL: read_only.on not audited';
  end if;
  raise notice 'PASS: 3. set_tenant_read_only';
end $$;

-- ---------------------------------------------------------------------
-- 4. Read-only guard as seen by the customer
-- ---------------------------------------------------------------------
select pg_temp.become('user');
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_dept   uuid := (select v from test_ids where k = 'dept');
  v_user   uuid := (select v from test_ids where k = 'user');
  acc jsonb; v_n int;
begin
  -- can still read
  if (select count(*) from departments where id = v_dept) <> 1 then raise exception 'FAIL: cannot read while read-only'; end if;

  begin
    insert into departments (tenant_id, name) values (v_tenant, 'Should Fail');
    raise exception 'FAIL: insert allowed in read-only';
  exception when others then
    if sqlerrm not like 'TENANT_READ_ONLY%' then raise exception 'FAIL: unexpected insert error: %', sqlerrm; end if;
  end;
  begin
    update departments set name = 'Renamed' where id = v_dept;
    get diagnostics v_n = row_count;
    raise exception 'FAIL: update allowed in read-only (rows=%)', v_n;
  exception when others then
    if sqlerrm not like 'TENANT_READ_ONLY%' then raise exception 'FAIL: unexpected update error: %', sqlerrm; end if;
  end;
  begin
    delete from departments where id = v_dept;
    raise exception 'FAIL: delete allowed in read-only';
  exception when others then
    if sqlerrm not like 'TENANT_READ_ONLY%' then raise exception 'FAIL: unexpected delete error: %', sqlerrm; end if;
  end;

  -- notifications are exempt (mark read)
  update notifications set read_at = now() where recipient_id = v_user and tenant_id = v_tenant;

  -- customer-side banner data
  acc := get_my_tenant_access();
  if not (acc->>'read_only')::boolean or acc->>'read_only_reason' <> 'Invoice 60 days overdue' or acc->>'plan' <> 'standard' then
    raise exception 'FAIL: get_my_tenant_access wrong: %', acc;
  end if;
  raise notice 'PASS: 4a. customer blocked from writes, can read';
end $$;

-- other tenant unaffected
select pg_temp.become('other_u');
do $$
declare v_other uuid := (select v from test_ids where k = 'other');
begin
  insert into departments (tenant_id, name) values (v_other, 'Other Still Writes');
  raise notice 'PASS: 4b. other tenants unaffected';
end $$;

-- platform admin (View-as) still writes; then switches read-only off; customer writes again
select pg_temp.become('admin');
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant'); r tenants;
begin
  perform start_impersonation(v_tenant, 'support: verify read-only exemption');
  insert into departments (tenant_id, name) values (v_tenant, 'Support Added Dept');
  perform end_impersonation();

  r := set_tenant_read_only(v_tenant, false, null);
  if r.read_only or r.read_only_reason is not null or r.read_only_since is not null then
    raise exception 'FAIL: read-only not cleared: %', to_jsonb(r);
  end if;
  if not exists (select 1 from platform_audit_events where tenant_id = v_tenant and action = 'tenant.read_only.off') then
    raise exception 'FAIL: read_only.off not audited';
  end if;
  raise notice 'PASS: 4c. platform admin exempt; read-only off audited';
end $$;

select pg_temp.become('user');
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant');
begin
  insert into departments (tenant_id, name) values (v_tenant, 'Writes Again');
  update departments set name = 'Renamed OK' where id = (select v from test_ids where k = 'dept');
  if not exists (select 1 from departments where name = 'Renamed OK') then
    raise exception 'FAIL: update did not land after read-only off (RLS fixture problem?)';
  end if;
  raise notice 'PASS: 4d. customer writes again after read-only off';
end $$;

-- ---------------------------------------------------------------------
-- 5. Seat limit (invitations insert runs as service_role in production;
--    exercised here as postgres to bypass invitation RLS, which is not
--    what's under test)
-- ---------------------------------------------------------------------
reset role;
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_admin  uuid := (select v from test_ids where k = 'admin');
begin
  -- 1 member currently; limit 2 -> one pending invite fits, second refused
  update tenants set seat_limit = 2 where id = v_tenant;
  insert into invitations (tenant_id, email, invited_by, status) values (v_tenant, 'seat1@example.com', v_admin, 'pending');
  begin
    insert into invitations (tenant_id, email, invited_by, status) values (v_tenant, 'seat2@example.com', v_admin, 'pending');
    raise exception 'FAIL: invitation beyond seat limit accepted';
  exception when others then
    if sqlerrm not like 'SEAT_LIMIT_REACHED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  update tenants set seat_limit = 3 where id = v_tenant;
  insert into invitations (tenant_id, email, invited_by, status) values (v_tenant, 'seat2@example.com', v_admin, 'pending');
  update tenants set seat_limit = null where id = v_tenant;
  insert into invitations (tenant_id, email, invited_by, status) values (v_tenant, 'seat3@example.com', v_admin, 'pending');
  raise notice 'PASS: 5. seat limit';
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 6. Notes
-- ---------------------------------------------------------------------
select pg_temp.become('user');
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant');
begin
  begin
    perform add_tenant_note(v_tenant, 'customer trying to write a note');
    raise exception 'FAIL: customer could add a tenant note';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
end $$;

select pg_temp.become('admin');
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant'); n tenant_notes;
begin
  n := add_tenant_note(v_tenant, '  Called Jane re overdue invoice; promised payment Friday.  ');
  if n.body <> 'Called Jane re overdue invoice; promised payment Friday.' or n.author_email <> 'profile-platform-admin@test.local' then
    raise exception 'FAIL: note wrong: %', to_jsonb(n);
  end if;
  begin
    perform add_tenant_note(v_tenant, '   ');
    raise exception 'FAIL: blank note accepted';
  exception when others then
    if sqlerrm not like '%blank%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  if (select count(*) from tenant_notes where tenant_id = v_tenant) <> 1 then raise exception 'FAIL: admin cannot read notes'; end if;
end $$;

select pg_temp.become('user');
do $$
begin
  if (select count(*) from tenant_notes) <> 0 then raise exception 'FAIL: customer can read tenant_notes'; end if;
  begin
    insert into tenant_notes (tenant_id, body) values ((select v from test_ids where k = 'tenant'), 'direct');
    raise exception 'FAIL: direct insert into tenant_notes allowed';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: 6. notes';
end $$;

-- ---------------------------------------------------------------------
-- 7. Read RPCs
-- ---------------------------------------------------------------------
select pg_temp.become('admin');
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  p jsonb; ov record;
begin
  p := get_tenant_profile(v_tenant);
  if p is null then raise exception 'FAIL: profile null'; end if;
  if (p->'tenant'->>'plan') <> 'standard' then raise exception 'FAIL: profile.tenant wrong: %', p->'tenant'; end if;
  if (p->'seats'->>'members')::int <> 1 or (p->'seats'->>'pending_invites')::int <> 3 then
    raise exception 'FAIL: seats wrong: %', p->'seats';
  end if;
  if (p->'activity'->>'last_sign_in_at') is null then raise exception 'FAIL: last_sign_in_at missing'; end if;
  if jsonb_array_length(p->'activity'->'company_admins') <> 1 then raise exception 'FAIL: company_admins: %', p->'activity'; end if;
  -- Inside one transaction now() is frozen, so on/off share a created_at
  -- and the tie-break is arbitrary; in production each is its own request.
  if (p->'last_status_event'->>'action') not in ('tenant.read_only.on', 'tenant.read_only.off') then
    raise exception 'FAIL: last_status_event wrong: %', p->'last_status_event';
  end if;
  if jsonb_array_length(p->'recent_events') < 3 then raise exception 'FAIL: recent_events too short: %', p->'recent_events'; end if;
  if (p->>'notes_count')::int <> 1 then raise exception 'FAIL: notes_count'; end if;
  if get_tenant_profile(gen_random_uuid()) is not null then raise exception 'FAIL: unknown tenant should be null'; end if;

  select * into ov from get_companies_overview() where tenant_id = v_tenant;
  if ov.plan <> 'standard' or ov.subscription_status <> 'active' or ov.read_only or ov.contact_email <> 'jane@example.com'
     or ov.last_activity_at is null or ov.member_count <> 1 then
    raise exception 'FAIL: overview row wrong: %', to_jsonb(ov);
  end if;
  raise notice 'PASS: 7. read RPCs';
end $$;

select pg_temp.become('user');
do $$
begin
  begin
    perform get_tenant_profile((select v from test_ids where k = 'tenant'));
    raise exception 'FAIL: customer could call get_tenant_profile';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 8. status_changed_at
-- ---------------------------------------------------------------------
select pg_temp.become('admin');
do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant'); r tenants;
begin
  r := set_tenant_status(v_tenant, 'suspended', 'test suspension');
  if r.status_changed_at is null then raise exception 'FAIL: status_changed_at not stamped'; end if;
  r := set_tenant_status(v_tenant, 'active', null);
  raise notice 'PASS: 8. status_changed_at';
end $$;

rollback;
