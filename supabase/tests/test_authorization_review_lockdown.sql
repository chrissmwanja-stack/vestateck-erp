-- Regression test for:
--   supabase/migrations/20261002080000_authorization_review_lockdown.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. get_posting_account and the three supplier_invoice_* helpers are not
--      executable by authenticated or anon (internal helpers; triggers call
--      them as the function owner).
--   2. record_employee_compensation needs BOTH an hr_team_members row AND the
--      HR module `manager` role. A team member without the manager role, a
--      manager who is not on the HR team, and an HR admin who is neither are
--      refused. A manager on the HR team succeeds, but not for an employee of
--      another tenant.
--   3. An HR admin cannot grant payroll approver access to themselves, nor
--      re-activate their own approver row, but can grant it to someone else
--      and can deactivate their own row.
--
-- Run against a fresh local stack only -- never against a linked/remote
-- project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant   uuid := gen_random_uuid();
  v_other    uuid := gen_random_uuid();
  v_hradmin  uuid := gen_random_uuid();  -- hr module admin, no HR team row
  v_hrmgr    uuid := gen_random_uuid();  -- hr module manager + HR team member
  v_hrteam   uuid := gen_random_uuid();  -- HR team member, plain hr member role
  v_mgronly  uuid := gen_random_uuid();  -- hr module manager, NOT on HR team
  v_peer     uuid := gen_random_uuid();  -- ordinary user to be granted approver
  v_outmgr   uuid := gen_random_uuid();  -- hr manager + HR team in OTHER tenant
  v_emp      uuid;
  v_emp_out  uuid;
begin
  insert into tenants (id, name, status) values
    (v_tenant, 'AuthzReview Co',       'active'),
    (v_other,  'AuthzReview Other Co', 'active');

  insert into tenant_modules (tenant_id, module) values (v_tenant, 'hr'), (v_other, 'hr');

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
    (v_hradmin, 'arl-hr-admin'),
    (v_hrmgr,   'arl-hr-manager'),
    (v_hrteam,  'arl-hr-team'),
    (v_mgronly, 'arl-manager-only'),
    (v_peer,    'arl-peer'),
    (v_outmgr,  'arl-other-manager')
  ) as u(id, handle);

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin) values
    (v_hradmin, v_tenant, 'ARL HR Admin',      'arl-hr-admin@test.local',      false, false),
    (v_hrmgr,   v_tenant, 'ARL HR Manager',    'arl-hr-manager@test.local',    false, false),
    (v_hrteam,  v_tenant, 'ARL HR Team',       'arl-hr-team@test.local',       false, false),
    (v_mgronly, v_tenant, 'ARL Manager Only',  'arl-manager-only@test.local',  false, false),
    (v_peer,    v_tenant, 'ARL Peer',          'arl-peer@test.local',          false, false),
    (v_outmgr,  v_other,  'ARL Other Manager', 'arl-other-manager@test.local', false, false);

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_hradmin,  'hr', 'admin'),
    (v_tenant, v_hrmgr,    'hr', 'manager'),
    (v_tenant, v_mgronly,  'hr', 'manager'),
    (v_other,  v_outmgr,   'hr', 'manager');

  insert into hr_team_members (tenant_id, user_id, role) values
    (v_tenant, v_hrmgr,  'member'),
    (v_tenant, v_hrteam, 'member'),
    (v_other,  v_outmgr, 'member');

  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, is_active)
  values (v_tenant, 'PLACEHOLDER', 'Arl', 'Employee', 'arl-emp@test.local', true)
  returning id into v_emp;
  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, is_active)
  values (v_other, 'PLACEHOLDER', 'Arl', 'Outsider', 'arl-emp-out@test.local', true)
  returning id into v_emp_out;

  create temp table if not exists test_ids(k text primary key, v uuid not null) on commit drop;
  insert into test_ids values
    ('tenant', v_tenant), ('other', v_other),
    ('hradmin', v_hradmin), ('hrmgr', v_hrmgr), ('hrteam', v_hrteam),
    ('mgronly', v_mgronly), ('peer', v_peer), ('outmgr', v_outmgr),
    ('emp', v_emp), ('emp_out', v_emp_out);
  grant select on test_ids to authenticated;
end $$;

create or replace function pg_temp.become(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object(
      'sub',  (select v from test_ids where k = p_key),
      'role', 'authenticated',
      'aal',  'aal1'
    )::text, true);
end $$;

-- ---------------------------------------------------------------------
-- 1. Internal helpers are not executable by API roles
-- ---------------------------------------------------------------------
do $$
declare
  v_sig text;
  v_role text;
begin
  foreach v_sig in array array[
    'public.get_posting_account(uuid,text)',
    'public.supplier_invoice_outstanding(uuid)',
    'public.supplier_invoice_payable_now(uuid)',
    'public.supplier_invoice_receipt_cap(uuid)'
  ] loop
    foreach v_role in array array['authenticated', 'anon'] loop
      if has_function_privilege(v_role, v_sig, 'EXECUTE') then
        raise exception 'FAIL 1: % can still EXECUTE %', v_role, v_sig;
      end if;
    end loop;
  end loop;
  raise notice 'PASS: 1. internal helpers are not executable by authenticated/anon';
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 2. record_employee_compensation: HR team member AND HR manager
-- ---------------------------------------------------------------------
select pg_temp.become('hrteam');
do $$
declare
  v_emp uuid := (select v from test_ids where k = 'emp');
  v_refused boolean := false;
begin
  begin
    perform record_employee_compensation(v_emp, 1000000, current_date);
  exception when others then
    if sqlerrm like 'not authorized%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 2a: HR team member without manager role set a salary'; end if;
  raise notice 'PASS: 2a. HR team member without the manager role is refused';
end $$;

select pg_temp.become('mgronly');
do $$
declare
  v_emp uuid := (select v from test_ids where k = 'emp');
  v_refused boolean := false;
begin
  begin
    perform record_employee_compensation(v_emp, 1000000, current_date);
  exception when others then
    if sqlerrm like 'not authorized%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 2b: HR manager not on the HR team set a salary'; end if;
  raise notice 'PASS: 2b. HR manager who is not an HR team member is refused';
end $$;

select pg_temp.become('hradmin');
do $$
declare
  v_emp uuid := (select v from test_ids where k = 'emp');
  v_refused boolean := false;
begin
  begin
    perform record_employee_compensation(v_emp, 1000000, current_date);
  exception when others then
    if sqlerrm like 'not authorized%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 2c: HR admin (neither team member nor manager) set a salary'; end if;
  raise notice 'PASS: 2c. HR admin without team membership and manager role is refused';
end $$;

select pg_temp.become('hrmgr');
do $$
declare
  v_emp uuid := (select v from test_ids where k = 'emp');
  v_emp_out uuid := (select v from test_ids where k = 'emp_out');
  r hr_employee_compensation;
  v_refused boolean := false;
begin
  select * into r from record_employee_compensation(v_emp, 1500000, current_date, 'ARL-1', 'test');
  if r.employee_id is distinct from v_emp or r.basic_salary <> 1500000 then
    raise exception 'FAIL 2d: unexpected row %', r;
  end if;

  begin
    perform record_employee_compensation(v_emp_out, 1500000, current_date);
  exception when others then
    if sqlerrm like 'employee not found%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 2e: set a salary for an employee of another tenant'; end if;
  raise notice 'PASS: 2d+2e. HR manager on the HR team succeeds; cross-tenant employee is refused';
end $$;

-- ---------------------------------------------------------------------
-- 3. Payroll approvers: an HR admin cannot self-grant
-- ---------------------------------------------------------------------
select pg_temp.become('hradmin');
do $$
declare
  v_admin uuid := (select v from test_ids where k = 'hradmin');
  v_peer  uuid := (select v from test_ids where k = 'peer');
  v_refused boolean := false;
  r payroll_approvers;
  v_rows int;
begin
  -- 3a. self-grant refused, and no row is created
  begin
    perform grant_payroll_approver(v_admin);
  exception when others then
    if sqlerrm like 'not authorized%yourself%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 3a: HR admin granted approver access to themselves'; end if;

  reset role;
  select count(*) into v_rows from payroll_approvers where user_id = v_admin;
  set local role authenticated;
  if v_rows <> 0 then raise exception 'FAIL 3a: refused self-grant still created % row(s)', v_rows; end if;

  -- 3b. granting someone else still works
  select * into r from grant_payroll_approver(v_peer);
  if r.user_id is distinct from v_peer or not r.is_active then
    raise exception 'FAIL 3b: grant to another user returned %', r;
  end if;
  raise notice 'PASS: 3a+3b. self-grant refused, grant to another user works';
end $$;

do $$
declare
  v_admin uuid := (select v from test_ids where k = 'hradmin');
  v_tenant uuid := (select v from test_ids where k = 'tenant');
  v_refused boolean := false;
  r payroll_approvers;
begin
  -- 3c. an inactive approver row for the admin (created out of band) cannot be
  --     re-activated by the admin themselves, but can be left inactive.
  reset role;
  insert into payroll_approvers (tenant_id, user_id, role, is_active)
  values (v_tenant, v_admin, 'approver', false);
  set local role authenticated;

  begin
    perform set_payroll_approver_active(v_admin, true);
  exception when others then
    if sqlerrm like 'not authorized%yourself%' then v_refused := true; else raise; end if;
  end;
  if not v_refused then raise exception 'FAIL 3c: HR admin activated their own approver row'; end if;

  -- 3d. deactivating oneself is allowed (reduces privilege)
  reset role;
  update payroll_approvers set is_active = true where user_id = v_admin;
  set local role authenticated;
  select * into r from set_payroll_approver_active(v_admin, false);
  if r.is_active then raise exception 'FAIL 3d: self-deactivation did not apply'; end if;
  raise notice 'PASS: 3c+3d. self-activation refused, self-deactivation allowed';
end $$;

rollback;
