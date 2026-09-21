-- Functional test for the PMO workflow migrations:
--   20260921110000_pmo_project_approval_flow.sql    (decisions audit,
--     submit/decide RPCs, pending_approval/rejected statuses, created_by)
--   20260921113000_pmo_time_and_cost_tracking.sql   (time/cost ledgers,
--     allocation hourly_rate, rate-snapshot trigger)
--
-- Covers:
--   * submit not_started -> pending_approval (rejected can be resubmitted)
--   * member tier cannot decide; approver tier cannot decide their OWN
--     project (created_by), but can decide a colleague's
--   * rejection requires notes; approval moves project to in_progress
--     and notifies the creator
--   * time entries: a user can log only their own rows; an allocation
--     hourly rate is snapshotted into the entry (uncosted when none)
--   * cost entries: pmo admin/manager only; outsiders read nothing
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
  v_creator  uuid := gen_random_uuid();  -- pmo member
  v_approver uuid := gen_random_uuid();  -- pmo manager
  v_plain    uuid := gen_random_uuid();  -- no roles
  v_employee uuid := gen_random_uuid();  -- hr_employees row for approver
begin
  insert into tenants (id, name) values (v_tenant, 'PMO Flow Test Co');

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
    (v_creator,  'pmo-creator'),
    (v_approver, 'pmo-approver'),
    (v_plain,    'pmo-plain')
  ) as u(id, handle);

  insert into app_users (id, tenant_id, name, email)
  select u.id, v_tenant, u.name, u.email
  from (values
    (v_creator,  'PMO Member',  'pmo-creator@test.local'),
    (v_approver, 'PMO Manager', 'pmo-approver@test.local'),
    (v_plain,    'Plain User',  'pmo-plain@test.local')
  ) as u(id, name, email);

  insert into tenant_modules (tenant_id, module) values (v_tenant, 'pmo');

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_creator,  'pmo', 'member'),
    (v_tenant, v_approver, 'pmo', 'manager');

  -- employee row for the approver so the allocation rate trigger can find them
  insert into hr_employees (id, tenant_id, user_id, employee_no, first_name, last_name, email)
  values (v_employee, v_tenant, v_approver, 'EMP-PMO-1', 'PMO', 'Manager', 'pmo-approver@test.local');

  -- Project A: created by the member (submit -> approve flow)
  insert into pmo_projects (tenant_id, project_no, name, status, budget, created_by)
  values (v_tenant, 'PRJ-T-0001', 'Warehouse build', 'not_started', 500000, v_creator);

  -- Project B: created by the approver (self-approval probe)
  insert into pmo_projects (tenant_id, project_no, name, status, budget, created_by)
  values (v_tenant, 'PRJ-T-0002', 'Road resurfacing', 'not_started', 800000, v_approver);

  -- Active allocation with a rate for the approver on project A
  insert into pmo_resource_allocations (tenant_id, employee_id, project_id, status, hourly_rate)
  select v_tenant, v_employee, p.id, 'active', 25000
  from pmo_projects p where p.project_no = 'PRJ-T-0001';
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Creator submits project A
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from app_users where email = 'pmo-creator@test.local'))::text, true);

do $$
declare
  v_project_id uuid := (select id from pmo_projects where project_no = 'PRJ-T-0001');
begin
  perform submit_pmo_project_for_approval(v_project_id);
  if (select status from pmo_projects where id = v_project_id) <> 'pending_approval' then
    raise exception 'FAIL: submit did not move project to pending_approval';
  end if;
  if (select count(*) from pmo_project_decisions where project_id = v_project_id and decision = 'submitted') <> 1 then
    raise exception 'FAIL: no submitted decision row written';
  end if;
  raise notice 'PASS: submit_pmo_project_for_approval -> pending_approval + audit row';
end $$;

-- ---------------------------------------------------------------------
-- 2. Member tier cannot decide
-- ---------------------------------------------------------------------
do $$
declare
  v_project_id uuid := (select id from pmo_projects where project_no = 'PRJ-T-0001');
begin
  begin
    perform decide_pmo_project(v_project_id, 'approved', null);
    raise exception 'FAIL: a pmo member was allowed to decide a project';
  exception
    when raise_exception then
      if sqlerrm not like '%requires a pmo admin or manager%' then raise; end if;
  end;
  raise notice 'PASS: member-tier decide refused';
end $$;

-- ---------------------------------------------------------------------
-- 3. Approver approves A -> in_progress + creator notified
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from app_users where email = 'pmo-approver@test.local'))::text, true);

do $$
declare
  v_project_id uuid := (select id from pmo_projects where project_no = 'PRJ-T-0001');
  v_creator_id uuid := (select id from app_users where email = 'pmo-creator@test.local');
begin
  perform decide_pmo_project(v_project_id, 'approved', 'Budget signed off');

  if (select status from pmo_projects where id = v_project_id) <> 'in_progress' then
    raise exception 'FAIL: approved project did not become in_progress';
  end if;
  if (select count(*) from notifications
      where recipient_id = v_creator_id and type = 'pmo_project_approved'
        and title like 'Project approved:%') <> 1 then
    raise exception 'FAIL: creator not notified of project approval';
  end if;
  raise notice 'PASS: approve -> in_progress + audit + creator notification';
end $$;

-- ---------------------------------------------------------------------
-- 4. Self-approval refused on approver's own project (B)
-- ---------------------------------------------------------------------
do $$
declare
  v_project_id uuid := (select id from pmo_projects where project_no = 'PRJ-T-0002');
begin
  perform submit_pmo_project_for_approval(v_project_id);
  begin
    perform decide_pmo_project(v_project_id, 'approved', null);
    raise exception 'FAIL: approver self-approved their own project';
  exception
    when raise_exception then
      if sqlerrm not like '%cannot decide a project you created%' then raise; end if;
  end;
  raise notice 'PASS: creator self-approval refused';
end $$;

-- ---------------------------------------------------------------------
-- 5. Rejection requires notes; rejected can be resubmitted
-- ---------------------------------------------------------------------
do $$
declare
  v_project_id uuid := (select id from pmo_projects where project_no = 'PRJ-T-0002');
  v_creator_id uuid := (select id from app_users where email = 'pmo-creator@test.local');
begin
  begin
    perform decide_pmo_project(v_project_id, 'rejected', null);
    raise exception 'FAIL: rejection without notes was accepted';
  exception
    when raise_exception then
      if sqlerrm not like '%rejection requires notes%' then raise; end if;
  end;

  -- hand B to the member so the approver can actually decide it
  update pmo_projects set created_by = v_creator_id where id = v_project_id;
  perform decide_pmo_project(v_project_id, 'rejected', 'Rescope budget');
  if (select status from pmo_projects where id = v_project_id) <> 'rejected' then
    raise exception 'FAIL: rejected project did not become rejected';
  end if;
  if (select count(*) from notifications where type = 'pmo_project_rejected' and body like '%Rescope budget%') <> 1 then
    raise exception 'FAIL: rejection notification missing reason';
  end if;

  -- resubmit
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_creator_id)::text, true);
  perform submit_pmo_project_for_approval(v_project_id);
  if (select status from pmo_projects where id = v_project_id) <> 'pending_approval' then
    raise exception 'FAIL: rejected project could not be resubmitted';
  end if;
  raise notice 'PASS: rejection requires notes, carries the reason, and rejected can be resubmitted';
end $$;

-- ---------------------------------------------------------------------
-- 6. Time entries: own rows only; allocation rate snapshot; uncosted
--    fallback when no allocation exists
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from app_users where email = 'pmo-approver@test.local'))::text, true);

do $$
declare
  v_project_a uuid := (select id from pmo_projects where project_no = 'PRJ-T-0001');
  v_project_b uuid := (select id from pmo_projects where project_no = 'PRJ-T-0002');
  v_approver  uuid := (select id from app_users where email = 'pmo-approver@test.local');
  v_creator   uuid := (select id from app_users where email = 'pmo-creator@test.local');
  v_entry_id  uuid;
begin
  -- approver logs time on A (has an active allocation @ 25000): rate snapshots
  insert into pmo_time_entries (tenant_id, project_id, user_id, hours)
  select tenant_id, id, v_approver, 4 from pmo_projects where id = v_project_a
  returning id into v_entry_id;

  if (select hourly_rate from pmo_time_entries where id = v_entry_id) <> 25000 then
    raise exception 'FAIL: allocation hourly rate was not snapshotted into the time entry';
  end if;

  -- approver logs time on B (no allocation): uncosted
  insert into pmo_time_entries (tenant_id, project_id, user_id, hours)
  select tenant_id, id, v_approver, 2 from pmo_projects where id = v_project_b
  returning id into v_entry_id;

  if (select hourly_rate from pmo_time_entries where id = v_entry_id) is not null then
    raise exception 'FAIL: entry without allocation should stay uncosted (NULL rate)';
  end if;

  -- cannot log time as someone else
  begin
    insert into pmo_time_entries (tenant_id, project_id, user_id, hours)
    select tenant_id, id, v_creator, 1 from pmo_projects where id = v_project_a;
    raise exception 'FAIL: user was able to log time as someone else';
  exception
    when insufficient_privilege then null;
  end;

  raise notice 'PASS: time entries insert as self only; rate snapshot works; uncosted fallback works';
end $$;

-- ---------------------------------------------------------------------
-- 7. Cost entries: admin/manager only; totals feed what the report reads
-- ---------------------------------------------------------------------
do $$
declare
  v_project_a uuid := (select id from pmo_projects where project_no = 'PRJ-T-0001');
  v_approver  uuid := (select id from app_users where email = 'pmo-approver@test.local');
begin
  insert into pmo_cost_entries (tenant_id, project_id, description, category, amount, created_by)
  values ((select tenant_id from pmo_projects where id = v_project_a), v_project_a, 'Concrete delivery', 'materials', 250000, v_approver);

  -- member tier cannot book costs
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from app_users where email = 'pmo-creator@test.local'))::text, true);
  begin
    insert into pmo_cost_entries (tenant_id, project_id, description, category, amount, created_by)
    values ((select tenant_id from pmo_projects where id = v_project_a), v_project_a, 'Sneaky cost', 'other', 1, v_approver);
    raise exception 'FAIL: a pmo member was able to book a cost entry';
  exception
    when insufficient_privilege then null;
  end;

  -- the member CAN read the ledger of their own tenant's project (pmo member select)
  if (select count(*) from pmo_cost_entries where project_id = v_project_a) <> 1 then
    raise exception 'FAIL: pmo member cannot read project cost ledger';
  end if;

  -- and the project's actual (as the report computes it) = cost + hours*rate
  if (select coalesce(sum(amount),0) from pmo_cost_entries where project_id = v_project_a)
        + coalesce((select sum(hours * hourly_rate) from pmo_time_entries
                    where project_id = v_project_a and hourly_rate is not null),0)
        <> 250000 + 4*25000 then
    raise exception 'FAIL: ledger totals do not match the report formula';
  end if;

  -- plain user with no roles: nothing visible anywhere
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from app_users where email = 'pmo-plain@test.local'))::text, true);
  if (select count(*) from pmo_cost_entries) > 0
  or (select count(*) from pmo_time_entries) > 0
  or (select count(*) from pmo_project_decisions) > 0 then
    raise exception 'FAIL: non-pmo user can read pmo ledger/audit tables';
  end if;

  raise notice 'PASS: cost entries admin/manager-only; ledger totals verified; outsiders read nothing';
  raise notice 'ALL PMO APPROVAL + LEDGER TESTS PASSED';
end $$;

rollback;
