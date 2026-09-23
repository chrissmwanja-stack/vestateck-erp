-- Regression test for:
--   supabase/migrations/20260922220000_onboarding_funnel_and_usage.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. Non-platform users get nothing from get_tenant_onboarding_status /
--      get_companies_overview (0 rows) and are refused by
--      platform_module_activity / get_platform_dashboard_stats.
--   2. Onboarding stages are the furthest CONTIGUOUS milestone: a tenant
--      with modules enabled but no admin invite is stage 0; each fixture
--      tenant lands on its expected stage with the expected next_step;
--      days_in_stage and stalled (>7 days, not suspended/internal) work;
--      the internal tenant is flagged is_internal and never stalled.
--   3. platform_module_activity counts rows in the window vs the previous
--      window per module, across several source tables, and ignores
--      tenants with no rows.
--   4. get_platform_dashboard_stats: onboarding_funnel has all 7 stages
--      with correct counts (internal tenant excluded, suspended excluded);
--      stalled_onboarding lists the stalled early-stage tenant only;
--      quiet_tenants lists the went-quiet active tenant only;
--      module_usage per module has tenants_enabled / tenants_active_30d /
--      events_30d / events_prev_30d; trial_ending_soon lists the tenant
--      whose trial ends within 14 days; legacy keys are still present.
--   5. get_companies_overview carries onboarding_stage / next_step /
--      stalled and a module-aware last_activity_at.
--   6. get_company_analytics carries module_usage / onboarding /
--      last_activity_at plus the legacy keys.
--
-- Run against a fresh local stack only (`supabase start`, then
-- `psql -f`) -- never against a linked/remote project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures: one tenant per funnel stage + quiet + live + trial
-- ---------------------------------------------------------------------
do $$
declare
  v_home     uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();
  v_plain    uuid := gen_random_uuid();
  t0 uuid := gen_random_uuid();  -- created only (but modules on -> still stage 0)
  t1 uuid := gen_random_uuid();  -- admin invited, stalled (20 days)
  t2 uuid := gen_random_uuid();  -- admin joined, fresh (1 day)
  t3 uuid := gen_random_uuid();  -- modules enabled
  t4 uuid := gen_random_uuid();  -- team invited, no activity
  t5 uuid := gen_random_uuid();  -- had activity, quiet 45 days (active)
  t6 uuid := gen_random_uuid();  -- live, trial ending in 5 days
  ts uuid := gen_random_uuid();  -- suspended, at stage 1 for 30 days
  u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid();
  u5 uuid := gen_random_uuid(); u6 uuid := gen_random_uuid(); u6b uuid := gen_random_uuid();
begin
  insert into tenants (id, name, status, created_at, plan, subscription_status, trial_ends_at) values
    (v_home, 'Funnel Test Platform Home', 'active', now() - interval '400 days', 'internal', 'active', null),
    (t0, 'Funnel T0 Created',       'pending', now() - interval '2 days',   'trial', 'trialing', now() + interval '28 days'),
    (t1, 'Funnel T1 Invited',       'pending', now() - interval '30 days',  'trial', 'trialing', now() + interval '60 days'),
    (t2, 'Funnel T2 Joined',        'pending', now() - interval '10 days',  'trial', 'trialing', now() + interval '60 days'),
    (t3, 'Funnel T3 Modules',       'active',  now() - interval '10 days',  'starter', 'active', null),
    (t4, 'Funnel T4 Team',          'active',  now() - interval '10 days',  'starter', 'active', null),
    (t5, 'Funnel T5 Quiet',         'active',  now() - interval '120 days', 'standard', 'active', null),
    (t6, 'Funnel T6 Live',          'active',  now() - interval '20 days',  'trial', 'trialing', now() + interval '5 days'),
    (ts, 'Funnel TS Suspended',     'suspended', now() - interval '40 days', 'trial', 'trialing', now() + interval '60 days');

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
    (v_admin, 'funnel-platform-admin', now()),
    (v_plain, 'funnel-plain', now()),
    (u2, 'funnel-t2-admin', now() - interval '1 day'),
    (u3, 'funnel-t3-admin', now() - interval '1 day'),
    (u4, 'funnel-t4-admin', now() - interval '1 day'),
    (u5, 'funnel-t5-admin', now() - interval '45 days'),
    (u6, 'funnel-t6-admin', now() - interval '1 day'),
    (u6b, 'funnel-t6-member', now() - interval '2 days')
  ) as u(id, handle, lsi);

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (v_admin, v_home, 'Platform Admin', 'funnel-platform-admin@test.local', true,  false, now() - interval '400 days'),
    (v_plain, t6,     'Plain',          'funnel-plain@test.local',          false, false, now() - interval '3 days'),
    (u2, t2, 'T2 Admin', 'funnel-t2-admin@test.local', false, true, now() - interval '1 day'),
    (u3, t3, 'T3 Admin', 'funnel-t3-admin@test.local', false, true, now() - interval '9 days'),
    (u4, t4, 'T4 Admin', 'funnel-t4-admin@test.local', false, true, now() - interval '9 days'),
    (u5, t5, 'T5 Admin', 'funnel-t5-admin@test.local', false, true, now() - interval '110 days'),
    (u6, t6, 'T6 Admin', 'funnel-t6-admin@test.local', false, true, now() - interval '19 days'),
    (u6b, t6, 'T6 Member', 'funnel-t6-member@test.local', false, false, now() - interval '18 days');

  -- Invitations (admin invites for t1..t6 and ts; member invites for t4..t6)
  insert into invitations (tenant_id, email, invited_by, role_bundle, status, created_at) values
    (t1, 't1admin@x.test', v_admin, 'company_admin', 'pending',  now() - interval '20 days'),
    (t2, 't2admin@x.test', v_admin, 'company_admin', 'accepted', now() - interval '2 days'),
    (t3, 't3admin@x.test', v_admin, 'company_admin', 'accepted', now() - interval '9 days'),
    (t4, 't4admin@x.test', v_admin, 'company_admin', 'accepted', now() - interval '9 days'),
    (t5, 't5admin@x.test', v_admin, 'company_admin', 'accepted', now() - interval '110 days'),
    (t6, 't6admin@x.test', v_admin, 'company_admin', 'accepted', now() - interval '19 days'),
    (ts, 'tsadmin@x.test', v_admin, 'company_admin', 'pending',  now() - interval '30 days'),
    (t4, 't4member@x.test', u4, 'member', 'pending',  now() - interval '8 days'),
    (t5, 't5member@x.test', u5, 'member', 'accepted', now() - interval '100 days'),
    (t6, 't6member@x.test', u6, 'member', 'accepted', now() - interval '18 days');

  -- Modules: t0 has modules but no admin -> must still be stage 0.
  insert into tenant_modules (tenant_id, module, enabled_at) values
    (t0, 'hr', now() - interval '2 days'),
    (t3, 'hr', now() - interval '8 days'),
    (t4, 'hr', now() - interval '8 days'), (t4, 'it', now() - interval '8 days'),
    (t5, 'hr', now() - interval '100 days'),
    (t6, 'hr', now() - interval '18 days'), (t6, 'bd', now() - interval '18 days'), (t6, 'it', now() - interval '18 days')
  on conflict do nothing;

  -- Activity.
  -- t5: hr rows 45 days ago only -> first activity yes, quiet now.
  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, created_at) values
    (t5, 'E1', 'Old', 'One', 'old1@t5.test', now() - interval '45 days'),
    (t5, 'E2', 'Old', 'Two', 'old2@t5.test', now() - interval '50 days');
  -- t6: hr 3 rows this window, 1 previous window; bd 2 this window; it 0.
  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, created_at) values
    (t6, 'E1', 'A', 'A', 'a@t6.test', now() - interval '1 day'),
    (t6, 'E2', 'B', 'B', 'b@t6.test', now() - interval '2 days'),
    (t6, 'E3', 'C', 'C', 'c@t6.test', now() - interval '3 days'),
    (t6, 'E0', 'Z', 'Z', 'z@t6.test', now() - interval '40 days');
  insert into bd_leads (tenant_id, company_name, contact_name, created_at) values
    (t6, 'Lead A', 'Anna', now() - interval '1 day'),
    (t6, 'Lead B', 'Ben',  now() - interval '5 days');
  -- a third module for t6 (pmo, not enabled in tenant_modules -- usage
  -- is counted from rows, entitlement is a separate column)
  insert into pmo_projects (tenant_id, project_no, name, created_at) values (t6, 'P-FUNNEL-1', 'Funnel project', now() - interval '1 day');

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values
    ('home', v_home), ('admin', v_admin), ('plain', v_plain),
    ('t0', t0), ('t1', t1), ('t2', t2), ('t3', t3), ('t4', t4), ('t5', t5), ('t6', t6), ('ts', ts);
  grant select on test_ids to authenticated;
end $$;

create or replace function pg_temp.become(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', 'aal1')::text, true);
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Non-platform user
-- ---------------------------------------------------------------------
select pg_temp.become('plain');
do $$
begin
  if (select count(*) from get_tenant_onboarding_status()) <> 0 then raise exception 'FAIL: plain user saw onboarding rows'; end if;
  if (select count(*) from get_companies_overview()) <> 0 then raise exception 'FAIL: plain user saw overview rows'; end if;
  begin
    perform count(*) from platform_module_activity(30);
    raise exception 'FAIL: plain user could read module activity';
  exception when others then
    if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  begin
    perform get_platform_dashboard_stats();
    raise exception 'FAIL: plain user could read dashboard stats';
  exception when others then
    if sqlerrm not like '%platform admins%' then raise exception 'FAIL: unexpected: %', sqlerrm; end if;
  end;
  if (select count(*) from platform_module_activity_sources) <> 0 then raise exception 'FAIL: sources table visible to plain user'; end if;
  raise notice 'PASS: 1. non-platform user gets nothing';
end $$;

-- ---------------------------------------------------------------------
-- 2. Stages
-- ---------------------------------------------------------------------
select pg_temp.become('admin');
create or replace function pg_temp.expect_stage(p_key text, p_stage int, p_key_name text, p_stalled boolean) returns void
language plpgsql as $$
declare rr record;
begin
  select * into rr from get_tenant_onboarding_status() o where o.tenant_id = (select v from test_ids where k = p_key);
  if not found then raise exception 'FAIL: % missing from onboarding status', p_key; end if;
  if rr.stage <> p_stage or rr.stage_key <> p_key_name or rr.stalled <> p_stalled then
    raise exception 'FAIL: % expected stage %/%/stalled=% got %/%/% (next: %, days %)',
      p_key, p_stage, p_key_name, p_stalled, rr.stage, rr.stage_key, rr.stalled, rr.next_step, rr.days_in_stage;
  end if;
end $$;
do $$
declare r record;
begin
  perform pg_temp.expect_stage('t0', 0, 'created', false);          -- 2 days old, modules on but no admin
  perform pg_temp.expect_stage('t1', 1, 'admin_invited', true);     -- invite 20 days ago
  perform pg_temp.expect_stage('t2', 2, 'admin_joined', false);     -- joined 1 day ago
  perform pg_temp.expect_stage('t3', 3, 'modules_enabled', true);   -- enabled 8 days ago
  perform pg_temp.expect_stage('t4', 4, 'team_invited', true);      -- invited 8 days ago
  perform pg_temp.expect_stage('t5', 5, 'first_activity', false);   -- quiet is a stage, not "stalled"
  perform pg_temp.expect_stage('t6', 6, 'live', false);
  perform pg_temp.expect_stage('ts', 1, 'admin_invited', false);    -- suspended never stalls
  perform pg_temp.expect_stage('home', 1, 'admin_invited', false);  -- has the operator's account; internal never stalls

  select * into r from get_tenant_onboarding_status() o where o.tenant_id = (select v from test_ids where k = 't1');
  if r.days_in_stage not between 19 and 21 or r.next_step not ilike '%waiting for the admin%' then
    raise exception 'FAIL: t1 days/next_step wrong: % / %', r.days_in_stage, r.next_step;
  end if;
  select * into r from get_tenant_onboarding_status() o where o.tenant_id = (select v from test_ids where k = 't5');
  if r.next_step not ilike '%no activity%' or r.last_activity_at > now() - interval '40 days' then
    raise exception 'FAIL: t5 quiet detail wrong: % / %', r.next_step, r.last_activity_at;
  end if;
  select * into r from get_tenant_onboarding_status() o where o.tenant_id = (select v from test_ids where k = 'home');
  if not r.is_internal then raise exception 'FAIL: home tenant not flagged internal'; end if;
  select * into r from get_tenant_onboarding_status() o where o.tenant_id = (select v from test_ids where k = 't6');
  if r.next_step is not null or r.first_activity_at is null or r.last_activity_at < now() - interval '2 days' then
    raise exception 'FAIL: t6 live detail wrong: %', to_jsonb(r);
  end if;
  raise notice 'PASS: 2. contiguous stages, next steps, stalled rules';
end $$;

-- ---------------------------------------------------------------------
-- 3. Module activity
-- ---------------------------------------------------------------------
do $$
declare
  t6 uuid := (select v from test_ids where k = 't6');
  t5 uuid := (select v from test_ids where k = 't5');
  t0 uuid := (select v from test_ids where k = 't0');
  r record;
begin
  select * into r from platform_module_activity(30) a where a.tenant_id = t6 and a.module = 'hr';
  if r.events <> 3 or r.events_prev <> 1 then raise exception 'FAIL: t6 hr events %/%', r.events, r.events_prev; end if;
  select * into r from platform_module_activity(30) a where a.tenant_id = t6 and a.module = 'bd';
  if r.events <> 2 or r.events_prev <> 0 then raise exception 'FAIL: t6 bd events %/%', r.events, r.events_prev; end if;
  select * into r from platform_module_activity(30) a where a.tenant_id = t6 and a.module = 'pmo';
  if r.events <> 1 then raise exception 'FAIL: t6 pmo events %', r.events; end if;
  if exists (select 1 from platform_module_activity(30) a where a.tenant_id = t6 and a.module = 'it') then
    raise exception 'FAIL: t6 it should have no activity row';
  end if;
  select * into r from platform_module_activity(30) a where a.tenant_id = t5 and a.module = 'hr';
  if r.events <> 0 or r.events_prev <> 2 then raise exception 'FAIL: t5 hr events %/%', r.events, r.events_prev; end if;
  if exists (select 1 from platform_module_activity(30) a where a.tenant_id = t0) then
    raise exception 'FAIL: t0 should have no activity';
  end if;
  -- window is honoured
  select * into r from platform_module_activity(7) a where a.tenant_id = t6 and a.module = 'hr';
  if r.events <> 3 or r.events_prev <> 0 then raise exception 'FAIL: 7-day window %/%', r.events, r.events_prev; end if;
  raise notice 'PASS: 3. module activity per tenant/module with previous-window trend';
end $$;

-- ---------------------------------------------------------------------
-- 4. Dashboard stats
-- ---------------------------------------------------------------------
do $$
declare
  j jsonb := get_platform_dashboard_stats();
  f jsonb; x jsonb;
  t1 uuid := (select v from test_ids where k = 't1');
  t5 uuid := (select v from test_ids where k = 't5');
  t6 uuid := (select v from test_ids where k = 't6');
  ts uuid := (select v from test_ids where k = 'ts');
  home uuid := (select v from test_ids where k = 'home');
begin
  -- legacy keys intact
  if not (j ? 'totals' and j ? 'module_adoption' and j ? 'pending_companies_list') then raise exception 'FAIL: legacy keys missing'; end if;

  f := j->'onboarding_funnel';
  if jsonb_array_length(f) <> 7 then raise exception 'FAIL: funnel has % stages', jsonb_array_length(f); end if;
  -- Only our fixture tenants + whatever seed has; assert relative counts via our ids instead of absolutes:
  -- stage 1 must NOT count the suspended tenant, and stage 0 must not count the internal one.
  if (select (e->>'count')::int from jsonb_array_elements(f) e where e->>'stage_key' = 'admin_invited')
     <> (select count(*) from get_tenant_onboarding_status() o where o.stage = 1 and o.status <> 'suspended' and not o.is_internal) then
    raise exception 'FAIL: funnel stage 1 count wrong';
  end if;
  if (select (e->>'count')::int from jsonb_array_elements(f) e where e->>'stage_key' = 'live')
     <> (select count(*) from get_tenant_onboarding_status() o where o.stage = 6 and not o.is_internal) then
    raise exception 'FAIL: funnel live count wrong';
  end if;

  x := j->'stalled_onboarding';
  if not exists (select 1 from jsonb_array_elements(x) e where (e->>'id')::uuid = t1) then raise exception 'FAIL: t1 not in stalled list'; end if;
  if exists (select 1 from jsonb_array_elements(x) e where (e->>'id')::uuid in (ts, home, t5, t6)) then raise exception 'FAIL: stalled list has wrong members'; end if;
  if (select e->>'next_step' from jsonb_array_elements(x) e where (e->>'id')::uuid = t1) not ilike '%waiting%' then raise exception 'FAIL: stalled next_step missing'; end if;

  x := j->'quiet_tenants';
  if not exists (select 1 from jsonb_array_elements(x) e where (e->>'id')::uuid = t5 and (e->>'days_quiet')::int between 44 and 46) then
    raise exception 'FAIL: t5 not in quiet list correctly: %', x;
  end if;
  if exists (select 1 from jsonb_array_elements(x) e where (e->>'id')::uuid in (t6, t1, home)) then raise exception 'FAIL: quiet list has wrong members'; end if;

  x := j->'module_usage';
  if jsonb_array_length(x) <> 9 then raise exception 'FAIL: module_usage has % modules', jsonb_array_length(x); end if;
  if (select (e->>'events_30d')::int from jsonb_array_elements(x) e where e->>'module' = 'bd') < 2 then raise exception 'FAIL: bd events_30d'; end if;
  if (select (e->>'tenants_active_30d')::int from jsonb_array_elements(x) e where e->>'module' = 'hr') < 1 then raise exception 'FAIL: hr tenants_active_30d'; end if;
  if (select (e->>'tenants_enabled')::int from jsonb_array_elements(x) e where e->>'module' = 'it') < 2 then raise exception 'FAIL: it tenants_enabled (t4 + t6)'; end if;
  if (select (e->>'events_prev_30d')::int from jsonb_array_elements(x) e where e->>'module' = 'hr') < 3 then raise exception 'FAIL: hr events_prev_30d (t5:2 + t6:1)'; end if;

  x := j->'trial_ending_soon';
  if not exists (select 1 from jsonb_array_elements(x) e where (e->>'id')::uuid = t6 and (e->>'days_left')::int between 4 and 6) then
    raise exception 'FAIL: t6 not in trial_ending_soon: %', x;
  end if;
  if exists (select 1 from jsonb_array_elements(x) e where (e->>'id')::uuid in (t1, ts)) then raise exception 'FAIL: trial list has wrong members'; end if;

  raise notice 'PASS: 4. dashboard funnel / stalled / quiet / module_usage / trial_ending_soon';
end $$;

-- ---------------------------------------------------------------------
-- 5. Companies overview
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from get_companies_overview() o where o.tenant_id = (select v from test_ids where k = 't1');
  if r.onboarding_stage <> 'admin_invited' or not r.onboarding_stalled or r.onboarding_next_step is null then
    raise exception 'FAIL: overview t1 onboarding cols: %', to_jsonb(r);
  end if;
  select * into r from get_companies_overview() o where o.tenant_id = (select v from test_ids where k = 't6');
  if r.onboarding_stage <> 'live' or r.onboarding_stalled or r.last_activity_at < now() - interval '2 days' or r.request_count_30d <> 0 then
    raise exception 'FAIL: overview t6: %', to_jsonb(r);
  end if;
  -- t5 has no requests and no recent sign-in, but hr rows 45 days ago -> module-aware last_activity_at
  select * into r from get_companies_overview() o where o.tenant_id = (select v from test_ids where k = 't5');
  if r.last_activity_at is null or r.last_activity_at > now() - interval '40 days' then
    raise exception 'FAIL: overview t5 last_activity_at: %', r.last_activity_at;
  end if;
  raise notice 'PASS: 5. companies overview carries onboarding + module-aware activity';
end $$;

-- ---------------------------------------------------------------------
-- 6. Company analytics
-- ---------------------------------------------------------------------
do $$
declare
  j jsonb := get_company_analytics((select v from test_ids where k = 't6'));
  m jsonb;
begin
  if not (j ? 'requests_by_status' and j ? 'purchase_orders' and j ? 'top_requesters') then raise exception 'FAIL: legacy analytics keys missing'; end if;
  if jsonb_array_length(j->'module_usage') <> 9 then raise exception 'FAIL: analytics module_usage size'; end if;
  select e into m from jsonb_array_elements(j->'module_usage') e where e->>'module' = 'hr';
  if not (m->>'enabled')::boolean or (m->>'events_30d')::int <> 3 or (m->>'events_prev_30d')::int <> 1 or m->>'last_event_at' is null then
    raise exception 'FAIL: analytics hr usage: %', m;
  end if;
  select e into m from jsonb_array_elements(j->'module_usage') e where e->>'module' = 'legal';
  if (m->>'enabled')::boolean or (m->>'events_30d')::int <> 0 then raise exception 'FAIL: analytics legal usage: %', m; end if;
  select e into m from jsonb_array_elements(j->'module_usage') e where e->>'module' = 'procurement';
  if not (m->>'enabled')::boolean then raise exception 'FAIL: procurement should read as baseline-enabled'; end if;
  select e into m from jsonb_array_elements(j->'module_usage') e where e->>'module' = 'pmo';
  if (m->>'enabled')::boolean or (m->>'events_30d')::int <> 1 then raise exception 'FAIL: pmo should be used-but-not-enabled: %', m; end if;
  if (j->'onboarding'->>'stage_key') <> 'live' or (j->'onboarding') ? 'name' then raise exception 'FAIL: analytics onboarding: %', j->'onboarding'; end if;
  if (j->>'last_activity_at') is null then raise exception 'FAIL: analytics last_activity_at missing'; end if;
  raise notice 'PASS: 6. company analytics carries module_usage / onboarding / last_activity_at';
end $$;

rollback;
