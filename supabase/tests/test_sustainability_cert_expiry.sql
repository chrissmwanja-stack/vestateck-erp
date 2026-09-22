-- Functional test for the sustainability certification sweep migration:
--   20260921130000_sustainability_cert_expiry.sql
--     (renewal_reminded_at marker + sustainability_cert_expiry_sweep RPC)
--
-- Covers:
--   * past-due 'valid' certs flip to 'expired' exactly once and notify
--     creator + sustainability admins/managers
--   * certs expiring within 30 days get one reminder (status untouched,
--     renewal_reminded_at marker set, day count in the body)
--   * far-future and already-expired certs are untouched
--   * the sweep is idempotent and outsiders get 0 / notify nobody
--
-- Run against a fresh local stack only (psql -f), never a linked project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant   uuid := gen_random_uuid();
  v_member   uuid := gen_random_uuid(); -- sustainability member, creates certs
  v_mgr      uuid := gen_random_uuid(); -- sustainability manager
  v_plain    uuid := gen_random_uuid(); -- no roles
begin
  insert into tenants (id, name) values (v_tenant, 'Cert Sweep Test Co');

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
    (v_member, 'sus-member'),
    (v_mgr,    'sus-manager'),
    (v_plain,  'sus-plain')
  ) as u(id, handle);

  insert into app_users (id, tenant_id, name, email)
  select u.id, v_tenant, u.name, u.email
  from (values
    (v_member, 'Sustain Member',  'sus-member@test.local'),
    (v_mgr,    'Sustain Manager', 'sus-manager@test.local'),
    (v_plain,  'Plain User',      'sus-plain@test.local')
  ) as u(id, name, email);

  insert into tenant_modules (tenant_id, module) values (v_tenant, 'sustainability');

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_member, 'sustainability', 'member'),
    (v_tenant, v_mgr,    'sustainability', 'manager');

  -- A: lapsed but still marked valid -> must flip
  insert into sustainability_certifications (tenant_id, name, standard, issue_date, expiry_date, status, created_by)
  values (v_tenant, 'Lapsed ISO 14001', 'ISO 14001', current_date - 400, current_date - 1, 'valid', v_member);

  -- B: expires in 10 days -> must remind once
  insert into sustainability_certifications (tenant_id, name, standard, issue_date, expiry_date, status, created_by)
  values (v_tenant, 'Due Soon ISO 45001', 'ISO 45001', current_date - 355, current_date + 10, 'valid', v_member);

  -- C: far future -> untouched
  insert into sustainability_certifications (tenant_id, name, standard, expiry_date, status, created_by)
  values (v_tenant, 'Far Future Cert', null, current_date + 200, 'valid', v_member);

  -- D: already expired -> untouched, no notification
  insert into sustainability_certifications (tenant_id, name, standard, expiry_date, status, created_by)
  values (v_tenant, 'Already Lapsed', null, current_date - 5, 'expired', v_member);

  -- Handle -> id lookup (see test_machine_maintenance_workflow.sql for why)
  create temp table if not exists test_identities(handle text primary key, id uuid not null) on commit drop;
  insert into test_identities (handle, id) values
    ('member', v_member), ('manager', v_mgr), ('plain', v_plain), ('tenant', v_tenant),
    ('cert_a', (select id from sustainability_certifications where name = 'Lapsed ISO 14001')),
    ('cert_b', (select id from sustainability_certifications where name = 'Due Soon ISO 45001')),
    ('cert_c', (select id from sustainability_certifications where name = 'Far Future Cert')),
    ('cert_d', (select id from sustainability_certifications where name = 'Already Lapsed'));
  grant select on test_identities to authenticated;
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Outsider sweep: 0, notifies nobody
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'plain'))::text, true);

do $$
declare
  v_n int;
begin
  v_n := sustainability_cert_expiry_sweep();
  if v_n <> 0 then
    raise exception 'FAIL: outsider sweep returned % instead of 0', v_n;
  end if;
end $$;

reset role;
do $$
begin
  if (select count(*) from notifications where type like 'certification_%') <> 0 then
    raise exception 'FAIL: outsider sweep generated notifications';
  end if;
  raise notice 'PASS: outsider sweep returns 0 and notifies nobody';
end $$;

-- ---------------------------------------------------------------------
-- 2. Member sweep: flips A, reminds about B, ignores C and D
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'member'))::text, true);

do $$
declare
  v_n int;
begin
  v_n := sustainability_cert_expiry_sweep();
  if v_n <> 2 then
    raise exception 'FAIL: sweep flagged % certs, expected exactly 2 (one lapse, one reminder)', v_n;
  end if;

  if (select status from sustainability_certifications
      where id = (select id from test_identities where handle = 'cert_a')) <> 'expired' then
    raise exception 'FAIL: past-due valid cert not flipped to expired';
  end if;
  if (select status from sustainability_certifications
      where id = (select id from test_identities where handle = 'cert_b')) <> 'valid' then
    raise exception 'FAIL: due-soon cert status changed (reminders must not flip status)';
  end if;
  if (select renewal_reminded_at from sustainability_certifications
      where id = (select id from test_identities where handle = 'cert_b')) is null then
    raise exception 'FAIL: reminder marker not set on the due-soon cert';
  end if;
  if (select status from sustainability_certifications
      where id = (select id from test_identities where handle = 'cert_c')) <> 'valid'
     or (select renewal_reminded_at from sustainability_certifications
      where id = (select id from test_identities where handle = 'cert_c')) is not null then
    raise exception 'FAIL: far-future cert was touched';
  end if;
end $$;

reset role;
do $$
declare
  v_member uuid := (select id from test_identities where handle = 'member');
  v_mgr    uuid := (select id from test_identities where handle = 'manager');
begin
  if (select count(*) from notifications
      where type = 'certification_expired'
        and title = 'Certification expired: Lapsed ISO 14001'
        and recipient_id in (v_member, v_mgr)) <> 2 then
    raise exception 'FAIL: lapse notification did not reach creator + manager';
  end if;
  if (select count(*) from notifications
      where type = 'certification_expiring'
        and title = 'Certification expiring soon: Due Soon ISO 45001'
        and body like '%10 day(s) away%'
        and recipient_id in (v_member, v_mgr)) <> 2 then
    raise exception 'FAIL: renewal reminder missing or wrong audience/day count';
  end if;
  if (select count(*) from notifications where title like '%Far Future%'
       or title like '%Already Lapsed%') <> 0 then
    raise exception 'FAIL: notifications generated for certs that should be untouched';
  end if;
  raise notice 'PASS: lapse flip + renewal reminder land with creator and manager';
end $$;

-- ---------------------------------------------------------------------
-- 3. Idempotency: a second sweep does nothing
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'manager'))::text, true);

do $$
declare
  v_n int;
begin
  v_n := sustainability_cert_expiry_sweep();
  if v_n <> 0 then
    raise exception 'FAIL: second sweep re-flagged % certs (not idempotent)', v_n;
  end if;
end $$;

reset role;
do $$
begin
  if (select count(*) from notifications where type = 'certification_expired') <> 2
     or (select count(*) from notifications where type = 'certification_expiring') <> 2 then
    raise exception 'FAIL: second sweep duplicated notifications';
  end if;
  raise notice 'PASS: sweep is idempotent (status flip is one-shot, reminders marked)';
end $$;

reset role;
rollback;
