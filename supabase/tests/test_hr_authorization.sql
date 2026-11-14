-- HR authorization test: leave requests, appraisals, HR catalog tables and the
-- payroll-approver helper functions. These had no SQL coverage before.
--
-- Written against real behaviour: every expectation below was checked by
-- running it as the named role on a seeded local database.
--
-- Plain psql script, one transaction, ROLLBACK at the end. Prints
-- NOTICE: PASS: ... lines and RAISEs on the first failed assertion
-- (psql -v ON_ERROR_STOP=1 then exits non-zero). Local/CI database only.
--
-- Actors (all from supabase/seed.sql):
--   EMP    pm@test.local     ordinary employee, no HR role, active payroll approver
--   EMP2   cce@test.local    a second ordinary employee, no HR role
--   HRADM  hr@test.local     HR module admin (and HR team member)
--   HRMGR  gm@test.local     given the HR module "manager" role by this test
--   OTHER  ins.admin@test.local   belongs to a different tenant (b001), HR enabled there
begin;

create schema hrt;
grant usage on schema hrt to authenticated, anon;

-- run the next statements as this user (RLS applies)
create function hrt.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create function hrt.as_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
-- number of rows a query returns, under the current role
create function hrt.cnt(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute 'select count(*) from (' || p_sql || ') q' into n; return n; end $$;
-- run a write under the current role: 'ok:<rows>' | 'denied' (42501) | 'err:<sqlstate>'
create function hrt.try(p_sql text) returns text language plpgsql as $$
declare n bigint; begin
  execute p_sql; get diagnostics n = row_count; return 'ok:' || n;
exception when insufficient_privilege then return 'denied';
          when others then return 'err:' || sqlstate;
end $$;
create function hrt.expect(p_label text, p_actual text, p_expected text) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL: % -- expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'PASS: %', p_label;
end $$;
grant execute on all functions in schema hrt to authenticated, anon;

-- ---- fixtures (as postgres) ------------------------------------------------
\set T1    '''00000000-0000-0000-0000-000000000001'''
\set TB    '''00000000-0000-0000-0000-00000000b001'''
\set EMP   '''792c28b4-a7cf-4936-b6d2-596e8a3bc1ef'''
\set EMP2  '''833c98a7-31fc-4636-8f47-ed9b7cfbd52b'''
\set HRADM '''53665127-5662-442b-bf63-92e930ff40ef'''
\set HRMGR '''8fb20874-6f74-4c58-bda5-5716c5396bfb'''
\set OTHER '''00000000-0000-0000-0000-00000000b101'''

insert into staff_roles(tenant_id, user_id, module, role) values (:T1, :HRMGR, 'hr', 'manager');
update hr_employees set user_id = :EMP  where employee_no = 'HR-EMP-2026-0001';
update hr_employees set user_id = :EMP2 where employee_no = 'HR-EMP-2026-0002';
insert into hr_leave_types(tenant_id, name) values (:T1, 'Annual (test)');

select id as e1 from hr_employees where employee_no = 'HR-EMP-2026-0001' \gset
select id as e2 from hr_employees where employee_no = 'HR-EMP-2026-0002' \gset
select id as lt from hr_leave_types where name = 'Annual (test)' \gset

-- a request owned by EMP2, and an appraisal for each employee
insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
  values (:T1, :'e2', :'lt', current_date, current_date + 1, 2);
insert into hr_appraisals(tenant_id, employee_id, period, rating) values (:T1, :'e1', '2026-H1', 4);
insert into hr_appraisals(tenant_id, employee_id, period, rating) values (:T1, :'e2', '2026-H1', 3);

-- ============================================================================
-- 1. Leave requests
-- ============================================================================
select hrt.as_user(:EMP);

select hrt.expect('leave: employee files own pending request',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date, current_date + 4, 5)$q$, :T1, :'e1', :'lt')), 'ok:1');

select hrt.expect('leave: employee CANNOT file a request that is already approved',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days, status)
    values (%L, %L, %L, current_date, current_date + 4, 5, 'approved')$q$, :T1, :'e1', :'lt')), 'denied');

select hrt.expect('leave: employee CANNOT file a request with an approver already set',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days, approver_id)
    values (%L, %L, %L, current_date, current_date + 4, 5, %L)$q$, :T1, :'e1', :'lt', :HRADM)), 'denied');

select hrt.expect('leave: employee CANNOT file a request for someone else',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date, current_date + 1, 2)$q$, :T1, :'e2', :'lt')), 'denied');

select hrt.expect('leave: employee CANNOT approve their own pending request',
  hrt.try($q$update hr_leave_requests set status = 'approved' where status = 'pending'$q$), 'denied');

select hrt.expect('leave: employee CANNOT set an approver on their own pending request',
  hrt.try(format($q$update hr_leave_requests set approver_id = %L where status = 'pending'$q$, :HRADM)), 'denied');

select hrt.expect('leave: employee can still edit the reason on their own pending request',
  hrt.try($q$update hr_leave_requests set reason = 'family event' where status = 'pending' and reason is null$q$), 'ok:1');

select hrt.expect('leave: employee sees only their own requests (not EMP2''s)',
  hrt.cnt('select 1 from hr_leave_requests')::text, '1');

select hrt.as_postgres();
select hrt.expect('leave: (fixture) the stored row is still pending with no approver',
  (select status || ':' || coalesce(approver_id::text, 'none')
     from hr_leave_requests where employee_id = :'e1'), 'pending:none');

select hrt.as_user(:EMP2);
select hrt.expect('leave: another employee sees only their own request',
  hrt.cnt('select 1 from hr_leave_requests')::text, '1');
select hrt.expect('leave: another employee CANNOT touch someone else''s request (0 rows)',
  hrt.try($q$update hr_leave_requests set reason = 'hijack' where employee_id <> (select id from hr_employees where user_id = auth.uid())$q$), 'ok:0');

select hrt.as_user(:HRADM);
select hrt.expect('leave: HR admin sees every request in the tenant',
  hrt.cnt('select 1 from hr_leave_requests')::text, '2');
select hrt.expect('leave: HR admin can approve and record the approver',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRADM, :'e1')), 'ok:1');

select hrt.as_user(:HRMGR);
select hrt.expect('leave: HR manager can reject a request',
  hrt.try(format($q$update hr_leave_requests set status = 'rejected', approver_id = %L where employee_id = %L$q$, :HRMGR, :'e2')), 'ok:1');

select hrt.as_user(:EMP);
select hrt.expect('leave: employee CANNOT change a request once it has been decided (0 rows)',
  hrt.try($q$update hr_leave_requests set status = 'pending', reason = 'undo' where status = 'approved'$q$), 'ok:0');

select hrt.as_user(:OTHER);
select hrt.expect('leave: another tenant sees no requests',
  hrt.cnt('select 1 from hr_leave_requests')::text, '0');
select hrt.expect('leave: another tenant CANNOT file a request into this tenant',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date, current_date + 1, 2)$q$, :T1, :'e1', :'lt')), 'denied');

-- ============================================================================
-- 2. Appraisals: HR admin/manager, or the employee for their own row
-- ============================================================================
select hrt.as_user(:EMP);
select hrt.expect('appraisal: employee sees only their own', hrt.cnt('select 1 from hr_appraisals')::text, '1');
select hrt.expect('appraisal: employee CANNOT file one',
  hrt.try(format($q$insert into hr_appraisals(tenant_id, employee_id, period, rating) values (%L, %L, '2026-H2', 5)$q$, :T1, :'e1')), 'denied');
select hrt.expect('appraisal: employee CANNOT raise their own rating (0 rows)',
  hrt.try($q$update hr_appraisals set rating = 5$q$), 'ok:0');
select hrt.expect('appraisal: employee CANNOT delete their own (0 rows)',
  hrt.try($q$delete from hr_appraisals$q$), 'ok:0');

select hrt.as_user(:EMP2);
select hrt.expect('appraisal: another employee sees only theirs', hrt.cnt('select 1 from hr_appraisals')::text, '1');

select hrt.as_user(:OTHER);
select hrt.expect('appraisal: another tenant sees none', hrt.cnt('select 1 from hr_appraisals')::text, '0');

select hrt.as_user(:HRMGR);
select hrt.expect('appraisal: HR manager sees all', hrt.cnt('select 1 from hr_appraisals')::text, '2');
select hrt.expect('appraisal: HR manager can file one',
  hrt.try(format($q$insert into hr_appraisals(tenant_id, employee_id, period, rating) values (%L, %L, '2026-H2', 4)$q$, :T1, :'e1')), 'ok:1');

-- ============================================================================
-- 3. HR catalog tables: tenant-wide read, HR *admin* only write
-- ============================================================================
select hrt.as_user(:EMP2);
select hrt.expect('catalog: any tenant member can read leave types',
  (hrt.cnt('select 1 from hr_leave_types') >= 1)::text, 'true');
select hrt.expect('catalog: non-HR member CANNOT add a position',
  hrt.try(format($q$insert into hr_positions(tenant_id, title) values (%L, 'x')$q$, :T1)), 'denied');
select hrt.expect('catalog: non-HR member CANNOT add a leave type',
  hrt.try(format($q$insert into hr_leave_types(tenant_id, name) values (%L, 'x')$q$, :T1)), 'denied');
select hrt.expect('catalog: non-HR member CANNOT post a job',
  hrt.try(format($q$insert into hr_job_postings(tenant_id, title) values (%L, 'x')$q$, :T1)), 'denied');

select hrt.as_user(:HRMGR);
select hrt.expect('catalog: HR manager (not admin) CANNOT add a position',
  hrt.try(format($q$insert into hr_positions(tenant_id, title) values (%L, 'x')$q$, :T1)), 'denied');

select hrt.as_user(:HRADM);
select hrt.expect('catalog: HR admin can add a position',
  hrt.try(format($q$insert into hr_positions(tenant_id, title) values (%L, 'Analyst')$q$, :T1)), 'ok:1');
select hrt.expect('catalog: HR admin can add a leave type',
  hrt.try(format($q$insert into hr_leave_types(tenant_id, name) values (%L, 'Study')$q$, :T1)), 'ok:1');
select hrt.expect('catalog: HR admin can post a job',
  hrt.try(format($q$insert into hr_job_postings(tenant_id, title) values (%L, 'Analyst')$q$, :T1)), 'ok:1');
select hrt.expect('catalog: HR admin CANNOT write into another tenant',
  hrt.try(format($q$insert into hr_positions(tenant_id, title) values (%L, 'x')$q$, :TB)), 'denied');

select hrt.as_user(:OTHER);
select hrt.expect('catalog: another tenant sees none of these tenants'' positions / types / postings',
  (hrt.cnt('select 1 from hr_positions') + hrt.cnt('select 1 from hr_leave_types') + hrt.cnt('select 1 from hr_job_postings'))::text, '0');
select hrt.expect('catalog: another tenant CANNOT write into this tenant',
  hrt.try(format($q$insert into hr_positions(tenant_id, title) values (%L, 'x')$q$, :T1)), 'denied');

-- ============================================================================
-- 4. Payroll approver helpers
-- ============================================================================
select hrt.as_user(:EMP);
select hrt.expect('payroll: active approver -> is_payroll_approver()', public.is_payroll_approver()::text, 'true');
select hrt.expect('payroll: active approver -> can_view_payroll_approvals()', public.can_view_payroll_approvals()::text, 'true');

select hrt.as_user(:EMP2);
select hrt.expect('payroll: ordinary employee is not an approver', public.is_payroll_approver()::text, 'false');
select hrt.expect('payroll: ordinary employee cannot view payroll approvals', public.can_view_payroll_approvals()::text, 'false');

select hrt.as_user(:HRADM);
select hrt.expect('payroll: HR team member is not automatically an approver', public.is_payroll_approver()::text, 'false');
select hrt.expect('payroll: HR team member can view payroll approvals', public.can_view_payroll_approvals()::text, 'true');

select hrt.as_user(:OTHER);
select hrt.expect('payroll: other tenant is not an approver here', public.is_payroll_approver()::text, 'false');

select hrt.as_postgres();
update payroll_approvers set is_active = false where user_id = :EMP;
select hrt.as_user(:EMP);
select hrt.expect('payroll: a deactivated approver loses the role', public.is_payroll_approver()::text, 'false');
select hrt.expect('payroll: ...and loses payroll-approval visibility', public.can_view_payroll_approvals()::text, 'false');

select hrt.as_postgres();
rollback;
