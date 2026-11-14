-- HR leave workflow decisions: (1) HR can file a leave request on an employee's
-- behalf; (2) nobody approves or rejects their own leave request, HR manager
-- included. Complements test_hr_authorization.sql, which covers the ordinary
-- employee and HR paths.
--
-- Plain psql script, one transaction, ROLLBACK at the end. Prints
-- NOTICE: PASS: ... lines and RAISEs on the first failed assertion
-- (psql -v ON_ERROR_STOP=1 then exits non-zero). Local/CI database only.
--
-- Actors (all from supabase/seed.sql):
--   EMP    pm@test.local     ordinary employee, no HR role
--   HRADM  hr@test.local     HR module admin; linked to an employee record here
--   HRMGR  gm@test.local     given the HR module "manager" role here; linked to an employee record
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
\set HRADM '''53665127-5662-442b-bf63-92e930ff40ef'''
\set HRMGR '''8fb20874-6f74-4c58-bda5-5716c5396bfb'''
\set OTHER '''00000000-0000-0000-0000-00000000b101'''

insert into staff_roles(tenant_id, user_id, module, role) values (:T1, :HRMGR, 'hr', 'manager');
update hr_employees set user_id = :EMP where employee_no = 'HR-EMP-2026-0001';
insert into hr_employees(tenant_id, first_name, last_name, email, user_id)
  values (:T1, 'Hana', 'Admin',   'hana.admin.leave-test@example.com',   :HRADM),
         (:T1, 'Gabe', 'Manager', 'gabe.manager.leave-test@example.com', :HRMGR);
insert into hr_leave_types(tenant_id, name) values (:T1, 'Annual (test)');

select id as e_emp from hr_employees where employee_no = 'HR-EMP-2026-0001' \gset
select id as e_adm from hr_employees where email = 'hana.admin.leave-test@example.com' \gset
select id as e_mgr from hr_employees where email = 'gabe.manager.leave-test@example.com' \gset
select id as lt from hr_leave_types where name = 'Annual (test)' \gset

-- an employee record in the other tenant
select hrt.as_postgres();
insert into hr_employees(tenant_id, first_name, last_name, email)
  values (:TB, 'Olu', 'Other', 'olu.other.leave-test@example.com');
select id as e_other from hr_employees where email = 'olu.other.leave-test@example.com' \gset

-- ============================================================================
-- 1. HR files on behalf of an employee
-- ============================================================================
select hrt.as_user(:HRADM);
select hrt.expect('on behalf: HR admin files a pending request for an employee',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date, current_date + 1, 2)$q$, :T1, :'e_emp', :'lt')), 'ok:1');
select hrt.expect('on behalf: ...and it is stored pending with no approver',
  (select status || ':' || coalesce(approver_id::text, 'none') from hr_leave_requests where employee_id = :'e_emp'), 'pending:none');
select hrt.expect('on behalf: HR admin CANNOT file it already approved',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days, status)
    values (%L, %L, %L, current_date, current_date + 1, 2, 'approved')$q$, :T1, :'e_emp', :'lt')), 'denied');
select hrt.expect('on behalf: HR admin CANNOT file it with an approver already set',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days, approver_id)
    values (%L, %L, %L, current_date, current_date + 1, 2, %L)$q$, :T1, :'e_emp', :'lt', :HRADM)), 'denied');
select hrt.expect('on behalf: HR admin CANNOT file for an employee of another tenant',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date, current_date + 1, 2)$q$, :T1, :'e_other', :'lt')), 'denied');

select hrt.as_user(:HRMGR);
select hrt.expect('on behalf: HR manager files a pending request for an employee',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date + 5, current_date + 6, 2)$q$, :T1, :'e_emp', :'lt')), 'ok:1');

select hrt.as_user(:EMP);
select hrt.expect('on behalf: an ordinary employee CANNOT file for a colleague',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date, current_date + 1, 2)$q$, :T1, :'e_adm', :'lt')), 'denied');
select hrt.expect('on behalf: ...but still files their own',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date + 9, current_date + 9, 1)$q$, :T1, :'e_emp', :'lt')), 'ok:1');

-- ============================================================================
-- 2. Nobody decides their own leave request
-- ============================================================================
-- HR files requests for the two HR people (on behalf), then each tries to decide their own.
select hrt.as_user(:HRADM);
select hrt.expect('self: HR admin files a request for the HR manager',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date + 20, current_date + 21, 2)$q$, :T1, :'e_mgr', :'lt')), 'ok:1');
select hrt.expect('self: HR admin files their own request (as the employee)',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date + 30, current_date + 31, 2)$q$, :T1, :'e_adm', :'lt')), 'ok:1');
select hrt.expect('self: HR admin CANNOT approve their own request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRADM, :'e_adm')), 'denied');
select hrt.expect('self: HR admin CANNOT reject their own request',
  hrt.try(format($q$update hr_leave_requests set status = 'rejected', approver_id = %L where employee_id = %L$q$, :HRADM, :'e_adm')), 'denied');
select hrt.expect('self: HR admin CANNOT re-point another request at themselves and approve it',
  hrt.try(format($q$update hr_leave_requests set employee_id = %L, status = 'approved', approver_id = %L where employee_id = %L$q$, :'e_adm', :HRADM, :'e_mgr')), 'denied');
select hrt.expect('self: HR admin CAN still approve someone else''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L and start_date = current_date$q$, :HRADM, :'e_emp')), 'ok:1');
select hrt.expect('self: HR admin CAN approve the HR manager''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRADM, :'e_mgr')), 'ok:1');

select hrt.as_user(:HRMGR);
select hrt.expect('self: HR manager files their own request',
  hrt.try(format($q$insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
    values (%L, %L, %L, current_date + 40, current_date + 41, 2)$q$, :T1, :'e_mgr', :'lt')), 'ok:1');
select hrt.expect('self: HR manager CANNOT approve their own request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L and status = 'pending'$q$, :HRMGR, :'e_mgr')), 'denied');
select hrt.expect('self: HR manager CANNOT reject their own request',
  hrt.try(format($q$update hr_leave_requests set status = 'rejected', approver_id = %L where employee_id = %L and status = 'pending'$q$, :HRMGR, :'e_mgr')), 'denied');
select hrt.expect('self: HR manager CAN approve the HR admin''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRMGR, :'e_adm')), 'ok:1');
select hrt.expect('self: HR manager CAN approve an ordinary employee''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'rejected', approver_id = %L where employee_id = %L and start_date = current_date + 5$q$, :HRMGR, :'e_emp')), 'ok:1');

select hrt.as_postgres();
select hrt.expect('self: (fixture) the HR manager''s own pending request is untouched',
  (select status || ':' || coalesce(approver_id::text, 'none') from hr_leave_requests where employee_id = :'e_mgr' and start_date = current_date + 40), 'pending:none');

-- another tenant's HR cannot reach these rows at all
select hrt.as_user(:OTHER);
select hrt.expect('tenant: another tenant sees none of these requests',
  hrt.cnt('select 1 from hr_leave_requests')::text, '0');

select hrt.as_postgres();
rollback;
