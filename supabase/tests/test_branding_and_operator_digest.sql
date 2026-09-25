-- Regression test for:
--   supabase/migrations/20260922240000_branding_and_operator_digest.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. get_platform_branding() works for anon and authenticated, applies
--      defaults, validates colour / logo URL / support email, and reflects
--      what the platform admin saved.
--   2. The item-5 gates still hold after the refactor: plain users get
--      nothing from get_tenant_onboarding_status(); the internal
--      *_all / *_scan functions are not executable by clients.
--   3. platform_run_operator_digest(): payload contains the expected
--      stalled / trial-ending / pending-over-threshold / admins-without-
--      MFA entries; attention_count and summary match; every platform
--      admin gets one 'operator_digest' notification; recipients and
--      delivery_status come from notifications settings; the audit log
--      records the run; the scheduled trigger respects digest_enabled
--      while a manual run does not.
--   4. run_operator_digest_now() / list_platform_digests() are platform
--      admin only; mark_platform_digest_delivered() is service-role only.
--   5. The daily cron job exists (when pg_cron is installed).
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_home   uuid := gen_random_uuid();
  v_admin  uuid := gen_random_uuid();   -- platform admin, MFA enrolled
  v_admin2 uuid := gen_random_uuid();   -- platform admin, no MFA
  v_plain  uuid := gen_random_uuid();
  t_stall  uuid := gen_random_uuid();   -- admin invited 20 days ago, pending -> stalled + pending over threshold
  t_trial  uuid := gen_random_uuid();   -- live, trial ends in 3 days
  t_fresh  uuid := gen_random_uuid();   -- created today (new company)
  u_trial  uuid := gen_random_uuid();
  u_trial2 uuid := gen_random_uuid();
begin
  create temp table test_ids (k text primary key, v uuid) on commit drop;
  insert into test_ids values ('home', v_home), ('admin', v_admin), ('admin2', v_admin2), ('plain', v_plain),
    ('t_stall', t_stall), ('t_trial', t_trial), ('t_fresh', t_fresh);
  grant select on test_ids to authenticated, anon, service_role;

  insert into tenants (id, name, status, created_at, plan, subscription_status, trial_ends_at) values
    (v_home,  'Digest Test Platform Home', 'active',  now() - interval '300 days', 'internal', 'active', null),
    (t_stall, 'Digest Stalled Co',         'pending', now() - interval '25 days',  'trial', 'trialing', now() + interval '40 days'),
    (t_trial, 'Digest Trial Co',           'active',  now() - interval '20 days',  'trial', 'trialing', now() + interval '3 days'),
    (t_fresh, 'Digest Fresh Co',           'pending', now() - interval '2 hours',  'trial', 'trialing', now() + interval '30 days');

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
    (v_admin,  'digest-admin',  now()),
    (v_admin2, 'digest-admin2', now()),
    (v_plain,  'digest-plain',  now()),
    (u_trial,  'digest-trial-admin', now() - interval '1 day'),
    (u_trial2, 'digest-trial-member', now() - interval '1 day')
  ) as u(id, handle, lsi);

  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
   values (gen_random_uuid(), v_admin, 'test', 'totp', 'verified', now(), now());

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (v_admin,  v_home,  'Digest Admin',  'digest-admin@test.local',  true,  false, now() - interval '300 days'),
    (v_admin2, v_home,  'Digest Admin2', 'digest-admin2@test.local', true,  false, now() - interval '200 days'),
    (v_plain,  t_trial, 'Plain',         'digest-plain@test.local',  false, false, now() - interval '3 days'),
    (u_trial,  t_trial, 'Trial Admin',   'digest-trial-admin@test.local', false, true, now() - interval '19 days'),
    (u_trial2, t_trial, 'Trial Member',  'digest-trial-member@test.local', false, false, now() - interval '18 days');

  insert into invitations (tenant_id, email, invited_by, role_bundle, status, created_at) values
    (t_stall, 'stall@x.test', v_admin, 'company_admin', 'pending', now() - interval '20 days'),
    (t_trial, 'trial@x.test', v_admin, 'company_admin', 'accepted', now() - interval '20 days'),
    (t_trial, 'trialm@x.test', v_admin, 'member', 'accepted', now() - interval '19 days');

  insert into tenant_modules (tenant_id, module, enabled_at) values (t_trial, 'pmo', now() - interval '19 days');
  insert into pmo_projects (tenant_id, name, created_at) values (t_trial, 'Digest live project', now() - interval '1 day');

  -- Deterministic period: forget earlier runs (rolled back with the test).
  delete from platform_digests;

  -- Settings: branding + notifications (recipients, threshold 2 days).
  update platform_settings set
    branding = jsonb_build_object('platform_name', 'Acme Cloud ERP', 'logo_url', 'https://cdn.example/logo.png',
                                  'primary_color', '#a1b2c3', 'support_email', 'Help@Acme.Example', 'tagline', 'Run the business'),
    notifications = jsonb_build_object('alert_recipients', jsonb_build_array('ops@acme.example', 'boss@acme.example'),
                                       'pending_company_threshold_days', 2, 'digest_enabled', true)
  where id = true;
end $$;

create or replace function pg_temp.become(p_key text, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', p_aal)::text, true);
end $$;

-- ---------------------------------------------------------------------
-- 1. Branding
-- ---------------------------------------------------------------------
do $$
declare b record;
begin
  -- anon
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  set local role anon;
  select * into b from get_platform_branding();
  if b.platform_name <> 'Acme Cloud ERP' then raise exception 'FAIL: anon branding name: %', b.platform_name; end if;
  if b.logo_url <> 'https://cdn.example/logo.png' then raise exception 'FAIL: logo url: %', b.logo_url; end if;
  if b.primary_color <> '#A1B2C3' then raise exception 'FAIL: colour normalised: %', b.primary_color; end if;
  if b.support_email <> 'help@acme.example' then raise exception 'FAIL: support email: %', b.support_email; end if;
  if b.tagline <> 'Run the business' then raise exception 'FAIL: tagline: %', b.tagline; end if;
  reset role;

  -- invalid values fall back to defaults
  update platform_settings set branding = jsonb_build_object('platform_name', '  ', 'logo_url', 'javascript:alert(1)',
    'primary_color', 'red', 'support_email', 'not-an-email') where id = true;
  select * into b from get_platform_branding();
  if b.platform_name <> 'VestaPortal' or b.logo_url <> '' or b.primary_color <> '#1B5560' or b.support_email <> ''
     or b.tagline <> 'Multi-department ERP' then
    raise exception 'FAIL: defaults not applied: %', to_jsonb(b);
  end if;

  -- restore
  update platform_settings set branding = jsonb_build_object('platform_name', 'Acme Cloud ERP', 'primary_color', '#A1B2C3') where id = true;
  raise notice 'PASS: 1. branding readable by anon, validated, defaulted';
end $$;

-- ---------------------------------------------------------------------
-- 2. Gates after the refactor
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('plain');
do $$
begin
  if (select count(*) from get_tenant_onboarding_status()) <> 0 then raise exception 'FAIL: plain user saw onboarding rows'; end if;
  begin
    perform count(*) from platform_onboarding_status_all();
    raise exception 'FAIL: plain user could call platform_onboarding_status_all';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from platform_module_activity_scan(30);
    raise exception 'FAIL: plain user could call platform_module_activity_scan';
  exception when insufficient_privilege then null;
  end;
  begin
    perform platform_run_operator_digest('manual');
    raise exception 'FAIL: plain user could run the digest directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform run_operator_digest_now();
    raise exception 'FAIL: plain user could run the digest RPC';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  if (select count(*) from list_platform_digests()) <> 0 then raise exception 'FAIL: plain user listed digests'; end if;
  begin
    perform mark_platform_digest_delivered(gen_random_uuid(), 'sent');
    raise exception 'FAIL: plain user could mark delivery';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: 2. gates hold for non-platform users';
end $$;

-- admin still sees the same shape as before
select pg_temp.become('admin');
do $$
begin
  if (select stage_key from get_tenant_onboarding_status() where tenant_id = (select v from test_ids where k = 't_stall')) <> 'admin_invited' then
    raise exception 'FAIL: stalled fixture stage';
  end if;
  if not (select stalled from get_tenant_onboarding_status() where tenant_id = (select v from test_ids where k = 't_stall')) then
    raise exception 'FAIL: stalled fixture not stalled';
  end if;
  if (select stage_key from get_tenant_onboarding_status() where tenant_id = (select v from test_ids where k = 't_trial')) <> 'live' then
    raise exception 'FAIL: trial fixture should be live';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Digest run (manual, as platform admin)
-- ---------------------------------------------------------------------
do $$
declare
  v_res       jsonb;
  v_payload   jsonb;
  v_id        uuid;
  v_n         integer;
  v_companies integer;
  v_live      integer;
begin
  -- Computed independently from the raw tables (not via the payload RPC
  -- itself), so these stay correct however many other companies already
  -- exist in this database (e.g. seed.sql's Test Construction Co) --
  -- this test only owns its own fixtures, not the whole tenants table.
  select count(*) into v_companies from tenants
    where not (plan = 'internal' or id = '00000000-0000-0000-0000-000000000099');
  select count(*) into v_live from get_tenant_onboarding_status() where not is_internal and stage = 6;

  v_res := run_operator_digest_now();
  v_id := (v_res ->> 'id')::uuid;
  v_payload := v_res -> 'payload';

  if v_res ->> 'trigger' <> 'manual' then raise exception 'FAIL: trigger'; end if;
  if v_res ->> 'delivery_status' <> 'pending' then raise exception 'FAIL: delivery_status % (recipients set)', v_res ->> 'delivery_status'; end if;
  if (select cardinality(recipients) from platform_digests where id = v_id) <> 2 then raise exception 'FAIL: recipients not captured'; end if;

  -- Content
  if not exists (select 1 from jsonb_array_elements(v_payload -> 'stalled') e where e ->> 'name' = 'Digest Stalled Co') then
    raise exception 'FAIL: stalled missing: %', v_payload -> 'stalled'; end if;
  if not exists (select 1 from jsonb_array_elements(v_payload -> 'trials_ending') e where e ->> 'name' = 'Digest Trial Co' and (e ->> 'days_left')::int = 3) then
    raise exception 'FAIL: trial ending missing: %', v_payload -> 'trials_ending'; end if;
  if not exists (select 1 from jsonb_array_elements(v_payload -> 'pending_over_threshold') e where e ->> 'name' = 'Digest Stalled Co') then
    raise exception 'FAIL: pending over threshold missing'; end if;
  if exists (select 1 from jsonb_array_elements(v_payload -> 'pending_over_threshold') e where e ->> 'name' = 'Digest Fresh Co') then
    raise exception 'FAIL: fresh pending company should be under threshold'; end if;
  if not exists (select 1 from jsonb_array_elements(v_payload -> 'new_companies') e where e ->> 'name' = 'Digest Fresh Co') then
    raise exception 'FAIL: new company missing'; end if;
  if v_payload -> 'admins_without_mfa' <> '["digest-admin2@test.local"]'::jsonb then
    raise exception 'FAIL: admins_without_mfa: %', v_payload -> 'admins_without_mfa'; end if;
  if (v_payload -> 'totals' ->> 'companies')::int <> v_companies then
    raise exception 'FAIL: totals.companies % (internal must be excluded, expected %)', v_payload -> 'totals', v_companies; end if;
  if (v_payload -> 'totals' ->> 'live')::int <> v_live then raise exception 'FAIL: totals.live % (expected %)', v_payload -> 'totals' ->> 'live', v_live; end if;
  -- Recomputed from the payload's own arrays rather than hardcoded, so a
  -- pre-existing company elsewhere in the database (e.g. seed.sql's Test
  -- Construction Co, which is long-pending and so legitimately shows up
  -- in pending_over_threshold) doesn't break this -- it still checks that
  -- attention_count/summary are wired up correctly to whatever the
  -- payload actually contains.
  if (v_res ->> 'attention_count')::int <>
     jsonb_array_length(v_payload -> 'stalled') + jsonb_array_length(v_payload -> 'quiet')
     + jsonb_array_length(v_payload -> 'trials_ending') + jsonb_array_length(v_payload -> 'pending_over_threshold')
     + jsonb_array_length(v_payload -> 'admins_without_mfa')
  then raise exception 'FAIL: attention_count % does not match payload array lengths', v_res ->> 'attention_count'; end if;
  -- Same omit-if-zero, "·"-joined shape as platform_digest_summary itself,
  -- built from the payload's own array lengths instead of fixed counts.
  if platform_digest_summary(v_payload) <> concat_ws(' · ',
       nullif(jsonb_array_length(v_payload -> 'stalled'), 0) || ' stalled in setup',
       nullif(jsonb_array_length(v_payload -> 'trials_ending'), 0) || ' trial(s) ending',
       nullif(jsonb_array_length(v_payload -> 'quiet'), 0) || ' gone quiet',
       nullif(jsonb_array_length(v_payload -> 'pending_over_threshold'), 0) || ' pending too long',
       nullif(jsonb_array_length(v_payload -> 'admins_without_mfa'), 0) || ' admin(s) without MFA')
  then raise exception 'FAIL: summary: %', platform_digest_summary(v_payload); end if;

  -- History RPC
  if (select count(*) from list_platform_digests(5)) < 1 then raise exception 'FAIL: list_platform_digests empty'; end if;
  create temp table digest_run on commit drop as select v_id as id, (v_res ->> 'attention_count')::int as attention_count;
  raise notice 'PASS: 3. manual digest: payload, count, summary';
end $$;

-- Notifications / audit are checked as postgres: notifications RLS only
-- shows a user their own rows, which is exactly what we want in prod but
-- hides the second admin's copy from the admin session above.
reset role;
do $$
declare
  v_id    uuid := (select id from digest_run);
  v_count integer := (select attention_count from digest_run);
  v_n     integer;
begin
  -- In-app notifications: one per platform admin (2), none for plain.
  select count(*) into v_n from notifications where type = 'operator_digest'
    and recipient_id in (select v from test_ids where k in ('admin', 'admin2'));
  if v_n <> 2 then raise exception 'FAIL: expected 2 admin notifications, got %', v_n; end if;
  if exists (select 1 from notifications where type = 'operator_digest' and recipient_id = (select v from test_ids where k = 'plain')) then
    raise exception 'FAIL: plain user got a digest notification'; end if;
  if (select title from notifications where type = 'operator_digest' and recipient_id = (select v from test_ids where k = 'admin') order by created_at desc limit 1)
     <> format('Operator digest: %s item(s) need attention', v_count) then
    raise exception 'FAIL: notification title'; end if;

  -- Audit
  if not exists (select 1 from platform_audit_events where action = 'platform.digest.run' and target_id = v_id::text) then
    raise exception 'FAIL: digest run not audited'; end if;

  raise notice 'PASS: 3a. notifications to every platform admin, audited';
end $$;

-- ---------------------------------------------------------------------
-- 3b. Scheduled run respects digest_enabled; manual ignores it
-- ---------------------------------------------------------------------
do $$
declare v_before integer; v_id uuid;
begin
  update platform_settings set notifications = notifications || '{"digest_enabled": false}'::jsonb where id = true;
  select count(*) into v_before from platform_digests;
  v_id := platform_run_operator_digest('scheduled');
  if v_id is not null or (select count(*) from platform_digests) <> v_before then
    raise exception 'FAIL: scheduled run ignored digest_enabled=false'; end if;
  v_id := platform_run_operator_digest('manual');
  if v_id is null then raise exception 'FAIL: manual run blocked by digest_enabled=false'; end if;

  -- With no recipients the row is 'skipped' (nothing to email) but still stored.
  update platform_settings set notifications = notifications || '{"digest_enabled": true, "alert_recipients": []}'::jsonb where id = true;
  v_id := platform_run_operator_digest('scheduled');
  if (select delivery_status from platform_digests where id = v_id) <> 'skipped' then
    raise exception 'FAIL: no-recipient run should be skipped'; end if;
  -- period_start of this run = period_end of the previous one
  if (select period_start from platform_digests where id = v_id) <>
     (select max(period_end) from platform_digests where id <> v_id) then
    raise exception 'FAIL: period chaining'; end if;
  raise notice 'PASS: 3b. digest_enabled switch, skipped when no recipients, period chaining';
end $$;

-- ---------------------------------------------------------------------
-- 4. Delivery bookkeeping (service role)
-- ---------------------------------------------------------------------
do $$
declare v_id uuid := (select id from platform_digests order by generated_at desc limit 1);
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  set local role service_role;
  perform mark_platform_digest_delivered(v_id, 'failed', 'Resend 429');
  if (select delivery_status || ':' || delivery_error from platform_digests where id = v_id) <> 'failed:Resend 429' then
    raise exception 'FAIL: failed status not recorded'; end if;
  perform mark_platform_digest_delivered(v_id, 'sent');
  if (select delivery_status from platform_digests where id = v_id) <> 'sent'
     or (select delivered_at from platform_digests where id = v_id) is null
     or (select delivery_error from platform_digests where id = v_id) is not null then
    raise exception 'FAIL: sent status not recorded'; end if;
  reset role;
  raise notice 'PASS: 4. service role records delivery';
end $$;

-- ---------------------------------------------------------------------
-- 5. Cron job
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'platform_operator_digest_daily' and schedule = '0 4 * * *') then
      raise exception 'FAIL: cron job missing'; end if;
    raise notice 'PASS: 5. daily cron job scheduled';
  else
    raise notice 'PASS: 5. (pg_cron not installed here - schedule step skipped by design)';
  end if;
end $$;

rollback;