-- HR leave: can_decide_leave(), the check behind the Leave Approvals screen and
-- its sidebar entry. True for an HR module admin/manager, the company admin, and
-- anyone who is the line manager (hr_employees.manager_id) of at least one
-- employee in their own tenant. False for everyone else, and never from another
-- tenant's reporting line.
--
-- The part that matters most is section 2: the function has to agree with what
-- the hr_leave_requests update policy actually lets each person decide, or the
-- screen would open for people the database then refuses (or stay closed for
-- people it would accept). Complements test_hr_leave_deciders.sql, which tests
-- the policy itself.
--
-- Plain psql script, one transaction, ROLLBACK at the end. Prints
-- NOTICE: PASS: ... lines and RAISEs on the first failed assertion
-- (psql -v ON_ERROR_STOP=1 then exits non-zero). Local/CI database only.
--
-- Actors (all from supabase/seed.sql; employee records are created here):
--   EMP     pm@test.local        given the HR "member" role here; manages nobody
--   LM      cce@test.local       line manager of EMP, no HR role
--   HRADM   hr@test.local        HR module admin
--   HRMGR   gm@test.local        given the HR "manager" role here; line manager is BOSS
--   BOSS    procurement@test.local   line manager of HRMGR, no HR role
--   CADMIN  company.admin@test.local   company admin, no module role
--   BYST    finance@test.local   bystander: no HR role, manages nobody (until section 3)
--   OTHER   ins.admin@test.local belongs to a different tenant
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
create function hrt.expect(p_label text, p_actual text, p_expected text) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL: % -- expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'PASS: %', p_label;
end $$;
-- Can this user decide at least one OTHER person's pending request, according to
-- the update policy? FOR UPDATE applies the policy's USING clause (and the select
-- policy), so it reports what an UPDATE would be allowed to touch without
-- changing any row. The caller's own requests are left out.
create function hrt.policy_lets_decide_someone_else() returns boolean language plpgsql as $$
begin
  return hrt.cnt($q$
    select 1 from hr_leave_requests r
    where r.status = 'pending'
      and r.employee_id not in (select id from hr_employees where user_id = (select auth.uid()))
    for update
  $q$) > 0;
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
insert into staff_roles(tenant_id, user_id, module, role)
  select :T1, :EMP, 'hr', 'member'
  where not exists (select 1 from staff_roles where tenant_id = :T1 and user_id = :EMP and module = 'hr');

update hr_employees set user_id = :EMP where employee_no = 'HR-EMP-2026-0001' and tenant_id = :T1;
update hr_employees set user_id = :LM  where employee_no = 'HR-EMP-2026-0002' and tenant_id = :T1;
insert into hr_employees(tenant_id, first_name, last_name, email, user_id)
  values (:T1, 'Hana', 'Admin',  'hana.decide-test@example.com',  :HRADM),
         (:T1, 'Gabe', 'Manager','gabe.decide-test@example.com',  :HRMGR),
         (:T1, 'Bo',   'Boss',   'bo.decide-test@example.com',    :BOSS),
         (:T1, 'Cara', 'Admin',  'cara.decide-test@example.com',  :CADMIN),
         (:T1, 'Bea',  'Bystander','bea.decide-test@example.com', :BYST),
         (:T1, 'Dan',  'Direct', 'dan.decide-test@example.com',   null);
-- an employee of the OTHER tenant, who is OTHER's own record
insert into hr_employees(tenant_id, first_name, last_name, email, user_id)
  select tenant_id, 'Olga', 'Other', 'olga.decide-test@example.com', id from app_users where id = :OTHER;
insert into hr_leave_types(tenant_id, name) values (:T1, 'Annual (decide test)');

select id as e_emp  from hr_employees where employee_no = 'HR-EMP-2026-0001' and tenant_id = :T1 \gset
select id as e_lm   from hr_employees where employee_no = 'HR-EMP-2026-0002' and tenant_id = :T1 \gset
select id as e_mgr  from hr_employees where email = 'gabe.decide-test@example.com' \gset
select id as e_boss from hr_employees where email = 'bo.decide-test@example.com' \gset
select id as e_byst from hr_employees where email = 'bea.decide-test@example.com' \gset
select id as e_dan  from hr_employees where email = 'dan.decide-test@example.com' \gset
select id as e_olga from hr_employees where email = 'olga.decide-test@example.com' \gset
select id as lt     from hr_leave_types where name = 'Annual (decide test)' \gset

-- reporting lines: EMP -> LM, HRMGR -> BOSS
update hr_employees set manager_id = :'e_lm'   where id = :'e_emp';
update hr_employees set manager_id = :'e_boss' where id = :'e_mgr';

-- one pending request for every employee in the tenant, so a manager always has
-- something to decide (filed as postgres)
insert into hr_leave_requests(tenant_id, employee_id, leave_type_id, start_date, end_date, days)
  select :T1, id, :'lt', current_date + 10, current_date + 11, 2
  from hr_employees where tenant_id = :T1;

-- ============================================================================
-- 1. Who it is true for
-- ============================================================================
select hrt.as_user(:HRADM);
select hrt.expect('HR admin: true', (select public.can_decide_leave())::text, 'true');
select hrt.as_user(:HRMGR);
select hrt.expect('HR manager: true', (select public.can_decide_leave())::text, 'true');
select hrt.as_user(:CADMIN);
select hrt.expect('company admin (no module role): true', (select public.can_decide_leave())::text, 'true');
select hrt.as_user(:LM);
select hrt.expect('line manager with no HR role: true', (select public.can_decide_leave())::text, 'true');
select hrt.as_user(:BOSS);
select hrt.expect('boss who manages an HR manager, no HR role: true', (select public.can_decide_leave())::text, 'true');

-- ============================================================================
-- 2. Who it is false for
-- ============================================================================
select hrt.as_user(:EMP);
select hrt.expect('HR member (not admin/manager) who manages nobody: false', (select public.can_decide_leave())::text, 'false');
select hrt.as_user(:BYST);
select hrt.expect('bystander who manages nobody: false', (select public.can_decide_leave())::text, 'false');
select hrt.as_user(:OTHER);
select hrt.expect('user of another tenant: false', (select public.can_decide_leave())::text, 'false');

-- ============================================================================
-- 3. It follows manager_id, in both directions
-- ============================================================================
select hrt.as_postgres();
update hr_employees set manager_id = :'e_byst' where id = :'e_dan';
select hrt.as_user(:BYST);
select hrt.expect('bystander becomes a decider once someone reports to them', (select public.can_decide_leave())::text, 'true');
select hrt.as_postgres();
update hr_employees set manager_id = null where id = :'e_dan';
select hrt.as_user(:BYST);
select hrt.expect('and stops being one when that link is cleared', (select public.can_decide_leave())::text, 'false');

-- A reporting line that crosses tenants never counts: Dan (tenant 1) pointing at
-- Olga (another tenant) must not make OTHER a decider in either tenant.
select hrt.as_postgres();
update hr_employees set manager_id = :'e_olga' where id = :'e_dan';
select hrt.as_user(:OTHER);
select hrt.expect('a cross-tenant manager_id does not make the other tenant''s user a decider', (select public.can_decide_leave())::text, 'false');
select hrt.as_postgres();
update hr_employees set manager_id = null where id = :'e_dan';

-- ============================================================================
-- 4. It agrees with the update policy
--    can_decide_leave() must be true exactly when the user can decide at least
--    one other person's pending request (every employee has one here).
-- ============================================================================
select hrt.as_user(:HRADM);
select hrt.expect('policy parity: HR admin', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');
select hrt.expect('  ... and both are true', hrt.policy_lets_decide_someone_else()::text, 'true');
select hrt.as_user(:HRMGR);
select hrt.expect('policy parity: HR manager', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');
select hrt.as_user(:CADMIN);
select hrt.expect('policy parity: company admin', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');
select hrt.expect('  ... and both are true', hrt.policy_lets_decide_someone_else()::text, 'true');
select hrt.as_user(:LM);
select hrt.expect('policy parity: line manager', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');
select hrt.expect('  ... and both are true', hrt.policy_lets_decide_someone_else()::text, 'true');
select hrt.as_user(:BOSS);
select hrt.expect('policy parity: boss', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');
select hrt.as_user(:EMP);
select hrt.expect('policy parity: HR member with no reports', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');
select hrt.expect('  ... and both are false', hrt.policy_lets_decide_someone_else()::text, 'false');
select hrt.as_user(:BYST);
select hrt.expect('policy parity: bystander', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');
select hrt.expect('  ... and both are false', hrt.policy_lets_decide_someone_else()::text, 'false');
select hrt.as_user(:OTHER);
select hrt.expect('policy parity: other tenant', (hrt.policy_lets_decide_someone_else() = public.can_decide_leave())::text, 'true');

-- ============================================================================
-- 5. Who may call it
-- ============================================================================
select hrt.as_postgres();
select hrt.expect('authenticated can execute can_decide_leave()',
  has_function_privilege('authenticated', 'public.can_decide_leave()', 'execute')::text, 'true');
select hrt.expect('anon cannot execute can_decide_leave()',
  has_function_privilege('anon', 'public.can_decide_leave()', 'execute')::text, 'false');
select hrt.expect('can_decide_leave() pins its search_path',
  (select (prosecdef and proconfig is not null and exists (select 1 from unnest(proconfig) c where c like 'search_path=%'))::text
   from pg_proc where oid = 'public.can_decide_leave()'::regprocedure), 'true');

rollback;
