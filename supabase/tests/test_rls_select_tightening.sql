-- RLS audit (2026-09-21) regression test for:
--   supabase/migrations/20260921090000_hr_select_tightening_and_attendance_delete.sql
--   supabase/migrations/20260921093000_young_module_select_tightening.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. A tenant user with NO staff_roles rows can no longer read
--      hr_job_applications / hr_trainings (candidate PII and the training
--      catalog), nor any row of the four young modules (law_*  , pmo_*,
--      machines et al., sustainability_*) -- previously all readable
--      tenant-wide via the REST API.
--   2. Module members read their own module's rows, and ONLY their own
--      module's rows (an hr/member must not see law cases, a legal/member
--      must not see job applications).
--   3. pmo_tasks keeps its assignee exception: a user holding no pmo
--      staff_roles row still sees the task assigned to them, and nothing
--      else in pmo_projects.
--   4. hr_attendance now has a DELETE verb: an HR manager can delete an
--      attendance row (AttendanceList.tsx's button was an RLS-denied
--      no-op before), while a non-HR user silently cannot.
--
-- Run against a fresh local stack only (`supabase start`, then
-- `psql -f`), same caveat as every other file in this directory -- never
-- against a linked/remote project. Fails loudly via RAISE EXCEPTION.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures (as the migration/table owner, before impersonation)
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant      uuid := gen_random_uuid();
  v_hr_member   uuid := gen_random_uuid();
  v_hr_manager  uuid := gen_random_uuid();
  v_legal_user  uuid := gen_random_uuid();
  v_plain_user  uuid := gen_random_uuid();
  v_assignee    uuid := gen_random_uuid();
  v_employee_id uuid := gen_random_uuid();
  v_project_id  uuid := gen_random_uuid();
begin
  insert into tenants (id, name) values (v_tenant, 'RLS Tighten Test Co');

  -- One auth identity + app_users row per test persona. Same fixture
  -- shape every test in this directory uses; password follows the
  -- seed.sql convention.
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
    (v_hr_member,  'rls-hr-member'),
    (v_hr_manager, 'rls-hr-manager'),
    (v_legal_user, 'rls-legal-member'),
    (v_plain_user, 'rls-plain-user'),
    (v_assignee,   'rls-pmo-assignee')
  ) as u(id, handle);

  insert into app_users (id, tenant_id, name, email)
  select u.id, v_tenant, u.name, u.email
  from (values
    (v_hr_member,  'HR Member',   'rls-hr-member@test.local'),
    (v_hr_manager, 'HR Manager',  'rls-hr-manager@test.local'),
    (v_legal_user, 'Legal Member','rls-legal-member@test.local'),
    (v_plain_user, 'Plain User',  'rls-plain-user@test.local'),
    (v_assignee,   'PMO Assignee','rls-pmo-assignee@test.local')
  ) as u(id, name, email);

  -- Module entitlements for the tenant (has_module_role checks these)
  insert into tenant_modules (tenant_id, module)
  select v_tenant, m from (values
    ('hr'), ('legal'), ('pmo'), ('machine_operation'), ('sustainability')
  ) as t(m);

  -- Roles: two HR tiers, one legal member. Plain user and the PMO
  -- assignee deliberately get NO staff_roles row at all.
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_hr_member,  'hr',    'member'),
    (v_tenant, v_hr_manager, 'hr',    'manager'),
    (v_tenant, v_legal_user, 'legal', 'member');

  -- One employee record to hang attendance rows off
  insert into hr_employees (id, tenant_id, employee_no, first_name, last_name, email)
  values (v_employee_id, v_tenant, 'EMP-RLS-1', 'Test', 'Employee', 'rls-emp@test.local');

  -- One row per table under test, all in this tenant
  insert into hr_job_applications (tenant_id, candidate_name, email, phone)
  values (v_tenant, 'Candidate One', 'cand1@test.local', '0700000001');

  insert into hr_trainings (tenant_id, title)
  values (v_tenant, 'Forklift Certification');

  insert into hr_attendance (tenant_id, employee_id, attendance_date, status)
  values (v_tenant, v_employee_id, current_date, 'present');

  insert into law_cases (tenant_id, case_no, title)
  values (v_tenant, 'CASE-RLS-1', 'Test case');

  insert into pmo_projects (id, tenant_id, project_no, name)
  values (v_project_id, v_tenant, 'PRJ-RLS-1', 'Test project');

  insert into pmo_tasks (tenant_id, project_id, title, assignee_id)
  values (v_tenant, v_project_id, 'Task assigned to no-role user', v_assignee);

  insert into machines (tenant_id, machine_no, name)
  values (v_tenant, 'MCH-RLS-1', 'Excavator');

  insert into sustainability_metrics (tenant_id, value, unit)
  values (v_tenant, 42, 'kg');

  -- test_identities: a plain, RLS-free lookup table for resolving each
  -- persona's id by handle. app_users itself can't be used for this --
  -- its SELECT policy is `tenant_id = get_my_tenant_id() OR id =
  -- auth.uid()`, both sides of which depend on auth.uid(), which is
  -- still unset the first time we need to look an id up (nothing has
  -- called set_config('request.jwt.claims', ...) yet). Querying
  -- app_users at that point silently returns zero rows, so `sub` gets
  -- set to NULL instead of raising -- every check after that then
  -- fails closed with 0 rows everywhere, which looks like a pass for
  -- "sees nothing" assertions but is really auth.uid() never resolving
  -- at all. Same pattern as test_law_contract_approval_flow.sql and
  -- the sibling BD/machine/sustainability/PMO test files.
  create temp table if not exists test_identities(handle text primary key, id uuid not null) on commit drop;
  insert into test_identities (handle, id) values
    ('rls-hr-member',    v_hr_member),
    ('rls-hr-manager',   v_hr_manager),
    ('rls-legal-member', v_legal_user),
    ('rls-plain-user',   v_plain_user),
    ('rls-pmo-assignee', v_assignee);
  grant select on test_identities to authenticated;
end $$;

-- From here on everything runs as the authenticated role; only the JWT
-- claims change between personas.
set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Plain user (no staff_roles): sees nothing in any of these tables
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rls-plain-user'))::text, true);

do $$
begin
  if (select count(*) from hr_job_applications) > 0 then
    raise exception 'FAIL: plain same-tenant user can read hr_job_applications (candidate PII)';
  end if;
  raise notice 'PASS: plain user reads 0 hr_job_applications';

  if (select count(*) from hr_trainings) > 0 then
    raise exception 'FAIL: plain same-tenant user can read hr_trainings';
  end if;
  raise notice 'PASS: plain user reads 0 hr_trainings';

  if (select count(*) from law_cases) > 0 then
    raise exception 'FAIL: plain user can read law_cases';
  end if;
  if (select count(*) from pmo_projects) > 0 then
    raise exception 'FAIL: plain user can read pmo_projects';
  end if;
  if (select count(*) from pmo_tasks) > 0 then
    raise exception 'FAIL: plain user can read pmo_tasks';
  end if;
  if (select count(*) from machines) > 0 then
    raise exception 'FAIL: plain user can read machines';
  end if;
  if (select count(*) from sustainability_metrics) > 0 then
    raise exception 'FAIL: plain user can read sustainability_metrics';
  end if;
  raise notice 'PASS: plain user reads 0 rows from law/pmo/machine/sustainability tables';
end $$;

-- ---------------------------------------------------------------------
-- 2. HR member: reads HR tables, still cannot read other modules
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rls-hr-member'))::text, true);

do $$
begin
  if (select count(*) from hr_job_applications) <> 1 then
    raise exception 'FAIL: hr/member cannot read hr_job_applications (expected 1 row)';
  end if;
  if (select count(*) from hr_trainings) <> 1 then
    raise exception 'FAIL: hr/member cannot read hr_trainings (expected 1 row)';
  end if;
  raise notice 'PASS: hr/member reads hr_job_applications and hr_trainings';

  if (select count(*) from law_cases) > 0 then
    raise exception 'FAIL: hr/member can read law_cases -- cross-module leak';
  end if;
  raise notice 'PASS: hr/member still cannot read legal module rows';
end $$;

-- ---------------------------------------------------------------------
-- 3. Legal member: reads law tables, cannot read HR recruitment tables
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rls-legal-member'))::text, true);

do $$
begin
  if (select count(*) from law_cases) <> 1 then
    raise exception 'FAIL: legal/member cannot read law_cases (expected 1 row)';
  end if;
  raise notice 'PASS: legal/member reads law_cases';

  if (select count(*) from hr_job_applications) > 0 then
    raise exception 'FAIL: legal/member can read hr_job_applications -- cross-module leak';
  end if;
  raise notice 'PASS: legal/member cannot read HR recruitment rows';
end $$;

-- ---------------------------------------------------------------------
-- 4. PMO assignee with no staff_roles row: sees own task only
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rls-pmo-assignee'))::text, true);

do $$
begin
  if (select count(*) from pmo_tasks) <> 1 then
    raise exception 'FAIL: assignee without pmo role cannot read the task assigned to them';
  end if;
  raise notice 'PASS: no-role assignee reads exactly their own pmo_tasks row';

  if (select count(*) from pmo_projects) > 0 then
    raise exception 'FAIL: no-role assignee can read pmo_projects beyond assignee scope';
  end if;
  raise notice 'PASS: assignee exception does not extend to pmo_projects';
end $$;

-- ---------------------------------------------------------------------
-- 5. Non-HR user cannot delete attendance; HR manager can
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rls-legal-member'))::text, true);

do $$
declare
  v_deleted int;
begin
  -- Don't verify via a re-SELECT here: the legal-member has no SELECT
  -- grant on hr_attendance at all, so count(*) would read 0 whether the
  -- delete was blocked or actually succeeded -- indistinguishable.
  -- GET DIAGNOSTICS reads the DELETE's own affected-row count instead,
  -- which is unambiguous regardless of this role's SELECT visibility.
  delete from hr_attendance;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 0 then
    raise exception 'FAIL: non-HR user deleted % hr_attendance row(s)', v_deleted;
  end if;
  raise notice 'PASS: hr_attendance delete denied (silently filtered) for non-HR user';
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rls-hr-manager'))::text, true);

do $$
declare
  v_attendance_id uuid;
begin
  -- HR manager deletes through the same path the app uses (DELETE by id)
  select id into v_attendance_id from hr_attendance limit 1;
  if v_attendance_id is null then
    raise exception 'FAIL: hr/manager cannot even see attendance rows to delete';
  end if;

  delete from hr_attendance where id = v_attendance_id;
  if (select count(*) from hr_attendance where id = v_attendance_id) <> 0 then
    raise exception 'FAIL: hr/manager delete on hr_attendance was denied (the original AttendanceList bug)';
  end if;
  raise notice 'PASS: hr/manager can delete hr_attendance (AttendanceList.tsx button now works)';
end $$;

rollback;