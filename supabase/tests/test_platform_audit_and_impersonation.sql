-- Regression test for:
--   supabase/migrations/20260922160000_platform_audit_and_impersonation_hardening.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. A non-platform user cannot start impersonation, change tenant
--      status/modules, or read platform_audit_events (0 rows, no error).
--   2. A platform admin WITHOUT any enrolled TOTP factor can act on an
--      aal1 session (bootstrap path) -- and every action is audited.
--   3. start_impersonation requires a reason; the session carries reason
--      + expires_at; get_active_impersonation returns them; end writes
--      the matching audit row.
--   4. Suspension requires a reason; activation does not; a no-op status
--      change writes nothing; the legacy 2-arg overload still works for
--      activation.
--   5. set_tenant_modules audits before/after; an identical set is a
--      no-op in the log.
--   6. update_workflow_stage_threshold audits with old/new values.
--   7. platform_settings UPDATE is audited by trigger.
--   8. Once the platform admin has a verified TOTP factor, the same
--      actions on an aal1 session are refused with PLATFORM_MFA_REQUIRED,
--      and succeed again on an aal2 session.
--   9. list_platform_audit_events / list_impersonation_history filter and
--      page; non-platform callers get zero rows.
--  10. Clients cannot write platform_audit_events directly (no INSERT
--      policy) and cannot call log_platform_event.
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
  v_home     uuid := gen_random_uuid();   -- platform admin's own tenant
  v_admin    uuid := gen_random_uuid();
  v_plain    uuid := gen_random_uuid();
  v_stage    uuid := gen_random_uuid();
begin
  insert into tenants (id, name, status) values
    (v_tenant, 'Audit Test Customer Co', 'active'),
    (v_home,   'Audit Test Platform Home', 'active');

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
    (v_admin, 'audit-platform-admin'),
    (v_plain, 'audit-plain-user')
  ) as u(id, handle);

  -- The partial unique index app_users_single_platform_admin allows one
  -- true row in the whole table. Seed data may already hold it; clear it
  -- inside this transaction (rolled back at the end).
  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin) values
    (v_admin, v_home,   'Platform Admin', 'audit-platform-admin@test.local', true),
    (v_plain, v_tenant, 'Plain User',     'audit-plain-user@test.local',     false);

  -- A workflow stage with a threshold for the customer tenant.
  insert into workflow_stages (id, tenant_id, name, sequence_order, approver_role, threshold_amount)
  values (v_stage, v_tenant, 'Audit Threshold Stage', 99, 'manager', 5000000);

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values ('tenant', v_tenant), ('home', v_home), ('admin', v_admin), ('plain', v_plain), ('stage', v_stage);
  grant select on test_ids to authenticated;
end $$;

-- Helper to switch identity. aal defaults to aal1.
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

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Non-platform user is refused everywhere
-- ---------------------------------------------------------------------
select pg_temp.become('plain');

do $$
declare v_tenant uuid := (select v from test_ids where k = 'tenant');
begin
  begin
    perform start_impersonation(v_tenant, 'trying to sneak in');
    raise exception 'FAIL: plain user could start impersonation';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then
      raise exception 'FAIL: unexpected error for plain impersonation: %', sqlerrm;
    end if;
  end;

  begin
    perform set_tenant_status(v_tenant, 'suspended', 'nope');
    raise exception 'FAIL: plain user could suspend a tenant';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then
      raise exception 'FAIL: unexpected error for plain suspend: %', sqlerrm;
    end if;
  end;

  begin
    perform set_tenant_modules(v_tenant, array['hr']);
    raise exception 'FAIL: plain user could set modules';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then
      raise exception 'FAIL: unexpected error for plain modules: %', sqlerrm;
    end if;
  end;

  if (select count(*) from platform_audit_events) <> 0 then
    raise exception 'FAIL: plain user can read platform_audit_events';
  end if;
  if (select count(*) from list_platform_audit_events()) <> 0 then
    raise exception 'FAIL: plain user gets rows from list_platform_audit_events';
  end if;
  if (select count(*) from list_impersonation_history()) <> 0 then
    raise exception 'FAIL: plain user gets rows from list_impersonation_history';
  end if;

  begin
    insert into platform_audit_events (action) values ('client.forged');
    raise exception 'FAIL: client could insert into platform_audit_events';
  exception when insufficient_privilege or others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  begin
    perform log_platform_event('client.forged');
    raise exception 'FAIL: client could call log_platform_event';
  exception when insufficient_privilege then
    null;
  when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  raise notice 'PASS: non-platform user refused on all privileged paths and reads nothing';
end $$;

-- ---------------------------------------------------------------------
-- 2-7. Platform admin, no MFA factor enrolled yet (aal1 is enough)
-- ---------------------------------------------------------------------
select pg_temp.become('admin');

do $$
declare
  v_tenant  uuid := (select v from test_ids where k = 'tenant');
  v_admin   uuid := (select v from test_ids where k = 'admin');
  v_sess    impersonation_sessions;
  v_active  record;
  v_cnt     int;
  v_row     record;
  v_stage   uuid;
  v_before  int;
  v_sessrow record;
begin
  select * into v_sessrow from get_platform_admin_session();
  if not v_sessrow.is_platform_admin or v_sessrow.has_mfa_factor or v_sessrow.session_is_mfa or not v_sessrow.can_act then
    raise exception 'FAIL: get_platform_admin_session wrong for un-enrolled admin: %', to_jsonb(v_sessrow);
  end if;

  -- 3. impersonation needs a reason
  begin
    perform start_impersonation(v_tenant, '   ');
    raise exception 'FAIL: impersonation accepted a blank reason';
  exception when others then
    if sqlerrm not like '%reason%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  begin
    perform start_impersonation(v_tenant);
    raise exception 'FAIL: legacy 1-arg impersonation still works';
  exception when others then
    if sqlerrm not like '%requires a reason%' then raise exception 'FAIL: unexpected legacy error: %', sqlerrm; end if;
  end;

  v_sess := start_impersonation(v_tenant, 'Investigating ticket #123');
  if v_sess.reason <> 'Investigating ticket #123' then raise exception 'FAIL: reason not stored'; end if;
  if v_sess.expires_at is null or v_sess.expires_at <= now() then raise exception 'FAIL: expires_at not set'; end if;
  if get_my_tenant_id() <> v_tenant then raise exception 'FAIL: get_my_tenant_id did not switch to impersonated tenant'; end if;

  select * into v_active from get_active_impersonation();
  if v_active.tenant_id <> v_tenant or v_active.reason <> 'Investigating ticket #123' or v_active.expires_at is null then
    raise exception 'FAIL: get_active_impersonation missing new columns: %', to_jsonb(v_active);
  end if;

  select count(*) into v_cnt from platform_audit_events where action = 'impersonation.start' and tenant_id = v_tenant and reason = 'Investigating ticket #123';
  if v_cnt <> 1 then raise exception 'FAIL: impersonation.start not audited (%)', v_cnt; end if;

  perform end_impersonation();
  if (select count(*) from get_active_impersonation()) <> 0 then raise exception 'FAIL: session still active after end'; end if;
  select count(*) into v_cnt from platform_audit_events where action = 'impersonation.end' and tenant_id = v_tenant;
  if v_cnt <> 1 then raise exception 'FAIL: impersonation.end not audited'; end if;
  raise notice 'PASS: impersonation requires reason, stores expiry, audited start+end';

  -- 4. tenant status
  begin
    perform set_tenant_status(v_tenant, 'suspended');
    raise exception 'FAIL: suspension without reason accepted (2-arg)';
  exception when others then
    if sqlerrm not like '%reason is required to suspend%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform set_tenant_status(v_tenant, 'suspended', '');
    raise exception 'FAIL: suspension with empty reason accepted';
  exception when others then
    if sqlerrm not like '%reason is required to suspend%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  perform set_tenant_status(v_tenant, 'suspended', 'Invoice 90 days overdue');
  if (select status from tenants where id = v_tenant) <> 'suspended' then raise exception 'FAIL: not suspended'; end if;
  select * into v_row from platform_audit_events where action = 'tenant.suspend' and tenant_id = v_tenant;
  if v_row.reason <> 'Invoice 90 days overdue' or v_row.before ->> 'status' <> 'active' or v_row.after ->> 'status' <> 'suspended' then
    raise exception 'FAIL: tenant.suspend audit row wrong: %', to_jsonb(v_row);
  end if;
  if v_row.actor_id <> v_admin or v_row.actor_email <> 'audit-platform-admin@test.local' then
    raise exception 'FAIL: actor not captured';
  end if;

  select count(*) into v_before from platform_audit_events;
  perform set_tenant_status(v_tenant, 'suspended', 'again');    -- no-op
  if (select count(*) from platform_audit_events) <> v_before then raise exception 'FAIL: no-op status change was audited'; end if;

  perform set_tenant_status(v_tenant, 'active');                  -- legacy overload, no reason needed
  if (select status from tenants where id = v_tenant) <> 'active' then raise exception 'FAIL: not reactivated'; end if;
  if (select count(*) from platform_audit_events where action = 'tenant.activate' and tenant_id = v_tenant) <> 1 then
    raise exception 'FAIL: tenant.activate not audited';
  end if;
  raise notice 'PASS: suspend needs reason, activate does not, no-op silent, both audited';

  -- 5. modules
  perform set_tenant_modules(v_tenant, array['hr', 'pmo']);
  select * into v_row from platform_audit_events where action = 'tenant.modules.set' and tenant_id = v_tenant order by created_at desc limit 1;
  if v_row.before -> 'modules' <> '[]'::jsonb or v_row.after -> 'modules' <> '["hr","pmo"]'::jsonb then
    raise exception 'FAIL: modules audit wrong: %', to_jsonb(v_row);
  end if;
  select count(*) into v_before from platform_audit_events;
  perform set_tenant_modules(v_tenant, array['pmo', 'hr']);      -- same set, different order
  if (select count(*) from platform_audit_events) <> v_before then raise exception 'FAIL: identical module set was audited'; end if;
  raise notice 'PASS: modules audited with before/after; identical set is silent';

  -- 6. threshold
  v_stage := (select v from test_ids where k = 'stage');
  perform update_workflow_stage_threshold(v_stage, 7500000);
  select * into v_row from platform_audit_events where action = 'workflow.threshold.update' and target_id = v_stage::text;
  if (v_row.before ->> 'threshold_amount')::numeric <> 5000000 or (v_row.after ->> 'threshold_amount')::numeric <> 7500000 or v_row.tenant_id <> v_tenant then
    raise exception 'FAIL: threshold audit wrong: %', to_jsonb(v_row);
  end if;
  raise notice 'PASS: threshold change audited with old/new';

  -- 7. platform_settings trigger
  update platform_settings set security = coalesce(security, '{}'::jsonb) || '{"session_timeout_minutes": 45}'::jsonb where id = true;
  select * into v_row from platform_audit_events where action = 'platform_settings.update' order by created_at desc limit 1;
  if v_row is null or (v_row.after -> 'security' ->> 'session_timeout_minutes') <> '45' then
    raise exception 'FAIL: platform_settings update not audited: %', to_jsonb(v_row);
  end if;
  if (select updated_by from platform_settings where id = true) <> v_admin then
    raise exception 'FAIL: platform_settings.updated_by not stamped';
  end if;
  raise notice 'PASS: platform_settings save audited via trigger';

  -- every row so far should say mfa_verified = false (aal1)
  if exists (select 1 from platform_audit_events where mfa_verified) then
    raise exception 'FAIL: mfa_verified true on an aal1 session';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. Enrol a verified TOTP factor -> aal1 is no longer enough
-- ---------------------------------------------------------------------
reset role;
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
values (gen_random_uuid(), (select v from test_ids where k = 'admin'), 'test', 'totp', 'verified', now(), now());
set local role authenticated;

select pg_temp.become('admin', 'aal1');

do $$
declare
  v_tenant  uuid := (select v from test_ids where k = 'tenant');
  v_sessrow record;
begin
  select * into v_sessrow from get_platform_admin_session();
  if not v_sessrow.has_mfa_factor or v_sessrow.session_is_mfa or v_sessrow.can_act then
    raise exception 'FAIL: get_platform_admin_session wrong for enrolled admin on aal1: %', to_jsonb(v_sessrow);
  end if;

  begin
    perform start_impersonation(v_tenant, 'should be blocked without mfa');
    raise exception 'FAIL: enrolled admin impersonated on aal1';
  exception when others then
    if sqlerrm not like 'PLATFORM_MFA_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  begin
    perform set_tenant_status(v_tenant, 'suspended', 'should be blocked');
    raise exception 'FAIL: enrolled admin suspended on aal1';
  exception when others then
    if sqlerrm not like 'PLATFORM_MFA_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  begin
    perform set_tenant_modules(v_tenant, array['hr']);
    raise exception 'FAIL: enrolled admin set modules on aal1';
  exception when others then
    if sqlerrm not like 'PLATFORM_MFA_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;

  -- Reads still work on aal1 (the flag alone gates reads).
  if (select count(*) from list_platform_audit_events()) = 0 then
    raise exception 'FAIL: enrolled admin on aal1 cannot read the audit log';
  end if;

  raise notice 'PASS: with a verified factor, aal1 session is refused for writes, allowed for reads';
end $$;

select pg_temp.become('admin', 'aal2');

do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_sess   impersonation_sessions;
  v_row    record;
begin
  v_sess := start_impersonation(v_tenant, 'MFA-verified session check');
  perform end_impersonation();

  perform set_tenant_status(v_tenant, 'suspended', 'MFA-verified suspend');
  perform set_tenant_status(v_tenant, 'active', 'paid');

  select * into v_row from platform_audit_events where action = 'tenant.suspend' and reason = 'MFA-verified suspend';
  if not v_row.mfa_verified then raise exception 'FAIL: mfa_verified not recorded on aal2 action'; end if;

  raise notice 'PASS: aal2 session acts normally and audit rows carry mfa_verified = true';
end $$;

-- ---------------------------------------------------------------------
-- 9. List RPCs: filtering, paging, totals
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_admin  uuid := (select v from test_ids where k = 'admin');
  v_total  bigint;
  v_page   int;
  v_hist   record;
begin
  select total_count into v_total from list_platform_audit_events(p_tenant_id => v_tenant) limit 1;
  select count(*) into v_page from list_platform_audit_events(p_tenant_id => v_tenant, p_limit => 2);
  if v_total < 8 or v_page <> 2 then
    raise exception 'FAIL: paging/total wrong (total %, page %)', v_total, v_page;
  end if;

  if (select count(*) from list_platform_audit_events(p_action => 'tenant.%')) <> (
       select count(*) from platform_audit_events where action like 'tenant.%') then
    raise exception 'FAIL: action prefix filter wrong';
  end if;

  if exists (select 1 from list_platform_audit_events(p_actor_id => v_admin) where actor_id <> v_admin) then
    raise exception 'FAIL: actor filter leaked other actors';
  end if;

  if exists (select 1 from list_platform_audit_events(p_tenant_id => v_tenant) where tenant_name <> 'Audit Test Customer Co') then
    raise exception 'FAIL: tenant_name not joined';
  end if;

  select * into v_hist from list_impersonation_history(p_tenant_id => v_tenant) limit 1;
  if v_hist.total_count <> 2 or v_hist.platform_admin_email <> 'audit-platform-admin@test.local' or v_hist.is_active then
    raise exception 'FAIL: impersonation history wrong: %', to_jsonb(v_hist);
  end if;

  raise notice 'PASS: list RPCs filter, page and join correctly';
end $$;

-- ---------------------------------------------------------------------
-- 10. expires_at is honoured by get_my_tenant_id
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_home   uuid := (select v from test_ids where k = 'home');
  v_sess   impersonation_sessions;
begin
  v_sess := start_impersonation(v_tenant, 'expiry check');
  if get_my_tenant_id() <> v_tenant then raise exception 'FAIL: not impersonating'; end if;
end $$;

reset role;
update impersonation_sessions set expires_at = now() - interval '1 minute' where ended_at is null;
set local role authenticated;
select pg_temp.become('admin', 'aal2');

do $$
declare
  v_home uuid := (select v from test_ids where k = 'home');
begin
  if get_my_tenant_id() <> v_home then
    raise exception 'FAIL: expired impersonation session still in effect';
  end if;
  if (select count(*) from get_active_impersonation()) <> 0 then
    raise exception 'FAIL: expired session reported as active';
  end if;
  raise notice 'PASS: expired session falls back to home tenant and is not reported active';
end $$;

rollback;