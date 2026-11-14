-- HR leave: who may decide a leave request. HR admin/manager (everyone), the
-- company admin and the employee's line manager (hr_employees.manager_id) can;
-- the employee it belongs to never can, whichever of those they are.
-- Complements test_hr_authorization.sql and
-- test_hr_leave_on_behalf_and_self_approval.sql.
--
-- Plain psql script, one transaction, ROLLBACK at the end. Prints
-- NOTICE: PASS: ... lines and RAISEs on the first failed assertion
-- (psql -v ON_ERROR_STOP=1 then exits non-zero). Local/CI database only.
--
-- Actors (all from supabase/seed.sql; employee records are created here):
--   EMP     pm@test.local        ordinary employee; line manager is LM
--   LM      cce@test.local       line manager of EMP, no HR role
--   HRADM   hr@test.local        HR module admin
--   HRMGR   gm@test.local        given the HR "manager" role here; line manager is BOSS
--   BOSS    procurement@test.local   line manager of HRMGR, no HR role
--   CADMIN  company.admin@test.local   company admin, no module role
--   BYST    finance@test.local   bystander: no HR role, manages nobody
--   OTHER   ins.admin@test.local belongs to a different tenant (b001)
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
\set T1     '''00000000-0000-0000-0000-000000000001'''
\set EMP    '''792c28b4-a7cf-4936-b6d2-596e8a3bc1ef'''
\set LM     '''833c98a7-31fc-4636-8f47-ed9b7cfbd52b'''
\set HRADM  '''53665127-5662-442b-bf63-92e930ff40ef'''
\set HRMGR  '''8fb20874-6f74-4c58-bda5-5716c5396bfb'''
\set BOSS   '''6cb314bb-c39e-40e2-aca9-446e12a1795f'''
\set CADMIN '''04eb905c-4c26-4596-bea6-55621574c65b'''
\set BYST   '''ed9cd87d-7649-486c-958b-36114271a0b2'''
\set OTHER  '''00000000-0000-0000-0000-00000000b101'''

insert into staff_roles(tenant_id, user_id, module, role) values (:T1, :HRMGR, 'hr', 'manager');
update hr_employees set user_id = :EMP where employee_no = 'HR-EMP-2026-0001';
update hr_employees set user_id = :LM  where employee_no = 'HR-EMP-2026-0002';
insert into hr_employees(tenant_id, first_name, last_name, email, user_id)
  values (:T1, 'Hana', 'Admin',  'hana.leave-test@example.com',  :HRADM),
         (:T1, 'Gabe', 'Manager','gabe.leave-test@example.com',  :HRMGR),
         (:T1, 'Bo',   'Boss',   'bo.leave-test@example.com',    :BOSS),
         (:T1, 'Cara', 'Admin',  'cara.leave-test@example.com',  :CADMIN),
         (:T1, 'Bea',  'Bystander','bea.leave-test@example.com', :BYST);
insert into hr_leave_types(tenant_id, name) values (:T1, 'Annual (test)');

select id as e_emp  from hr_employees where employee_no = 'HR-EMP-2026-0001' \gset
select id as e_lm   from hr_employees where employee_no = 'HR-EMP-2026-0002' \gset
select id as e_adm  from hr_employees where email = 'hana.leave-test@example.com' \gset
select id as e_mgr  from hr_employees where email = 'gabe.leave-test@example.com' \gset
select id as e_boss from hr_employees where email = 'bo.leave-test@example.com' \gset
select id as e_cad  from hr_employees where email = 'cara.leave-test@example.com' \gset
select id as e_byst from hr_employees where email = 'bea.leave-test@example.com' \gset
select id as lt     from hr_leave_types where name = 'Annual (test)' \gset

-- reporting lines: EMP -> LM, HRMGR -> BOSS
update hr_employees set manager_id = :'e_lm'   where id = :'e_emp';
update hr_employees set manager_id = :'e_boss' where id = :'e_mgr';

-- one pending request per employee, filed as postgres
insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
  select :T1, id, :'lt', current_date + 10, current_date + 11, 2
  from hr_employees where id in (:'e_emp', :'e_lm', :'e_adm', :'e_mgr', :'e_boss', :'e_cad', :'e_byst');

-- ============================================================================
-- 0. HR admin and HR manager cannot decide their own request (still pending here)
-- ============================================================================
select hrt.as_user(:HRADM);
select hrt.expect('HR admin: CANNOT approve their own pending request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRADM, :'e_adm')), 'denied');
select hrt.as_user(:HRMGR);
select hrt.expect('HR manager: CANNOT reject their own pending request',
  hrt.try(format($q$update hr_leave_requests set status = 'rejected', approver_id = %L where employee_id = %L$q$, :HRMGR, :'e_mgr')), 'denied');

-- ============================================================================
-- 1. Line manager
-- ============================================================================
select hrt.as_user(:LM);
select hrt.expect('line manager: sees their own request and their direct report''s, nothing else',
  hrt.cnt('select 1 from hr_leave_requests')::text, '2');
select hrt.expect('line manager: can approve a direct report''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :LM, :'e_emp')), 'ok:1');
select hrt.expect('line manager: CANNOT approve someone who does not report to them (0 rows)',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :LM, :'e_adm')), 'ok:0');
select hrt.expect('line manager: CANNOT approve their own request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :LM, :'e_lm')), 'denied');

-- ============================================================================
-- 2. The boss decides the HR manager's leave, but not their own
-- ============================================================================
select hrt.as_user(:BOSS);
select hrt.expect('boss: sees the HR manager''s request and their own',
  hrt.cnt('select 1 from hr_leave_requests')::text, '2');
select hrt.expect('boss: can approve their direct report, the HR manager',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :BOSS, :'e_mgr')), 'ok:1');
select hrt.expect('boss: CANNOT approve their own request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :BOSS, :'e_boss')), 'denied');

-- ============================================================================
-- 3. Company admin
-- ============================================================================
select hrt.as_user(:CADMIN);
select hrt.expect('company admin: sees every request in the tenant',
  hrt.cnt('select 1 from hr_leave_requests')::text, '7');
select hrt.expect('company admin: can decide an HR admin''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :CADMIN, :'e_adm')), 'ok:1');
select hrt.expect('company admin: can decide the boss''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'rejected', approver_id = %L where employee_id = %L$q$, :CADMIN, :'e_boss')), 'ok:1');
select hrt.expect('company admin: CANNOT approve their own request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :CADMIN, :'e_cad')), 'denied');

-- ============================================================================
-- 4. HR still decides for everyone except themselves
-- ============================================================================
select hrt.as_user(:HRADM);
select hrt.expect('HR admin: still sees every request',
  hrt.cnt('select 1 from hr_leave_requests')::text, '7');
select hrt.expect('HR admin: can decide an ordinary employee''s request (no line-manager link needed)',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRADM, :'e_byst')), 'ok:1');
select hrt.expect('HR admin: can decide the company admin''s request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRADM, :'e_cad')), 'ok:1');

select hrt.as_user(:HRMGR);
select hrt.expect('HR manager: can decide the line manager''s own request',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id = %L$q$, :HRMGR, :'e_lm')), 'ok:1');

-- ============================================================================
-- 5. Everyone else sees and decides nothing
-- ============================================================================
select hrt.as_user(:BYST);
select hrt.expect('bystander: sees only their own request',
  hrt.cnt('select 1 from hr_leave_requests')::text, '1');
select hrt.expect('bystander: CANNOT decide anyone''s request (0 rows)',
  hrt.try(format($q$update hr_leave_requests set status = 'approved', approver_id = %L where employee_id <> %L$q$, :BYST, :'e_byst')), 'ok:0');

select hrt.as_user(:OTHER);
select hrt.expect('tenant: another tenant sees none of these requests',
  hrt.cnt('select 1 from hr_leave_requests')::text, '0');

-- final stored state, as postgres
select hrt.as_postgres();
select hrt.expect('final: no request in the tenant was decided by the employee it belongs to',
  (not exists (select 1 from hr_leave_requests r join hr_employees e on e.id = r.employee_id
               where r.approver_id is not null and r.approver_id = e.user_id))::text, 'true');
select hrt.expect('final: every one of the seven requests was decided by someone else',
  (select count(*) from hr_leave_requests where status <> 'pending')::text, '7');
rollback;
