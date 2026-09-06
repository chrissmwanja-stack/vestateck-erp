-- Workstream F functional test: payroll run creation and item
-- generation/editing (create_payroll_run, generate_payroll_items,
-- update_payroll_item).
--
-- Run against a fresh local stack only (`supabase start` in the
-- db-shadow-replay CI job, or `supabase db reset` locally) -- see
-- test_gl_posting_and_period_close.sql's header for the same caveat
-- about not running this against a linked/remote project.
--
-- Fails loudly: any RAISE EXCEPTION here is a real assertion failure
-- and should fail the CI step (psql -f exits non-zero on an uncaught
-- error).

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tenant_id uuid := gen_random_uuid();
  v_hr_user_id uuid := gen_random_uuid();
  v_outsider_user_id uuid := gen_random_uuid();
  v_emp1 uuid;
  v_emp2 uuid;
  v_emp3 uuid;
  v_emp_inactive uuid;
  v_run_id uuid;
  v_run2_id uuid;
  v_run record;
  v_item record;
  v_item1 record;
  v_item2 record;
  v_calc record;
  v_count int;
  v_new_count int;
  v_caught boolean;
begin
  -------------------------------------------------------------------
  -- Fixtures: one tenant, one HR-team auth user, one auth user with
  -- no hr_team_members row (for the authorization checks), two
  -- active employees with compensation records, and a statutory
  -- rate table (needed for calculate_statutory_deductions() to
  -- return nonzero amounts -- see test_statutory_deductions.sql for
  -- the tax-math correctness tests themselves; this test only checks
  -- that generate_payroll_items()/update_payroll_item() wire that
  -- calculation into the payroll items correctly).
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_tenant_id, 'Payroll Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values
    ('00000000-0000-0000-0000-000000000000', v_hr_user_id, 'authenticated', 'authenticated',
     'payroll-hr-' || v_hr_user_id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''),
    ('00000000-0000-0000-0000-000000000000', v_outsider_user_id, 'authenticated', 'authenticated',
     'payroll-out-' || v_outsider_user_id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '');

  insert into app_users (id, tenant_id, name, email)
  values
    (v_hr_user_id, v_tenant_id, 'Payroll HR User', 'payroll-hr-' || v_hr_user_id || '@test.local'),
    (v_outsider_user_id, v_tenant_id, 'Payroll Outsider User', 'payroll-out-' || v_outsider_user_id || '@test.local');

  insert into hr_team_members (tenant_id, user_id, role)
  values (v_tenant_id, v_hr_user_id, 'hr');
  -- deliberately no hr_team_members row for v_outsider_user_id

  -- Impersonate the HR user from here on so get_my_tenant_id()/
  -- is_hr_team_member() (both auth.uid()-based) resolve correctly.
  -- JWT claims are transaction-scoped, not role-scoped, so they stay
  -- in effect through the reset-role fixture inserts below too.
  perform set_config('request.jwt.claims', json_build_object('sub', v_hr_user_id)::text, true);

  -- hr_employees' INSERT policy requires has_module_role('hr', ...),
  -- and hr_employee_compensation has no INSERT policy at all -- both
  -- are a different authorization axis than is_hr_team_member(), so
  -- these fixtures are inserted with RLS bypassed via reset role.
  -- Their defaulting triggers don't depend on auth context (employee_no
  -- generation uses NEW.tenant_id directly), so this is safe.
  reset role;

  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, is_active)
  values (v_tenant_id, 'PLACEHOLDER', 'Alice', 'Anyanzwa', 'alice@payroll-test.local', true)
  returning id into v_emp1;
  insert into hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, created_by)
  values (v_tenant_id, v_emp1, 300000, current_date - 30, v_hr_user_id);

  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, is_active)
  values (v_tenant_id, 'PLACEHOLDER', 'Brian', 'Byaruhanga', 'brian@payroll-test.local', true)
  returning id into v_emp2;
  insert into hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, created_by)
  values (v_tenant_id, v_emp2, 1200000, current_date - 30, v_hr_user_id);

  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, is_active)
  values (v_tenant_id, 'PLACEHOLDER', 'Carol', 'Chebet', 'carol@payroll-test.local', false)
  returning id into v_emp_inactive;
  insert into hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, created_by)
  values (v_tenant_id, v_emp_inactive, 400000, current_date - 30, v_hr_user_id);

  -- statutory_rate_tables' INSERT policy requires is_finance_team_member(),
  -- also a different axis -- bypassed the same way. Using the same
  -- 4-band PAYE schedule seed_statutory_rate_table() ships (see that
  -- migration's header: unconfirmed against URA, fine for a test fixture).
  insert into statutory_rate_tables (tenant_id, rate_type, effective_date, band_order, lower_bound, upper_bound, rate, base_tax) values
    (v_tenant_id, 'paye', current_date - 60, 1, 0, 335000, 0, 0),
    (v_tenant_id, 'paye', current_date - 60, 2, 335000, 410000, 10, 0),
    (v_tenant_id, 'paye', current_date - 60, 3, 410000, 10000000, 20, 7500),
    (v_tenant_id, 'paye', current_date - 60, 4, 10000000, null, 30, 1927500),
    (v_tenant_id, 'nssf_employee', current_date - 60, 1, 0, null, 5, 0),
    (v_tenant_id, 'nssf_employer', current_date - 60, 1, 0, null, 10, 0);

  set local role authenticated;

  -------------------------------------------------------------------
  -- 0. Authorization: none of the three RPCs should be callable by a
  --    tenant member who isn't on the HR team.
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_outsider_user_id)::text, true);

  v_caught := false;
  begin
    perform create_payroll_run('2026-09-outsider');
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: create_payroll_run was NOT rejected for a non-HR-team user';
  end if;

  v_caught := false;
  begin
    perform generate_payroll_items(gen_random_uuid());
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: generate_payroll_items was NOT rejected for a non-HR-team user';
  end if;

  v_caught := false;
  begin
    perform update_payroll_item(gen_random_uuid(), 0, 0, null);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: update_payroll_item was NOT rejected for a non-HR-team user';
  end if;

  raise notice 'PASS: all three RPCs correctly reject a non-HR-team caller';

  -- Switch back to the HR user for the rest of the test.
  perform set_config('request.jwt.claims', json_build_object('sub', v_hr_user_id)::text, true);

  -------------------------------------------------------------------
  -- 1. create_payroll_run creates a draft run for the caller's tenant.
  -------------------------------------------------------------------
  select * into v_run from create_payroll_run('2026-09');
  if v_run.id is null then
    raise exception 'FAIL: create_payroll_run did not return a row';
  end if;
  if v_run.status != 'draft' then
    raise exception 'FAIL: new payroll run has status %, expected draft', v_run.status;
  end if;
  if v_run.tenant_id != v_tenant_id then
    raise exception 'FAIL: new payroll run has the wrong tenant_id';
  end if;
  v_run_id := v_run.id;

  raise notice 'PASS: create_payroll_run creates a draft run scoped to the caller''s tenant';

  -------------------------------------------------------------------
  -- 2. generate_payroll_items() happy path: picks up both active
  --    employees, skips the inactive one, and computes PAYE/NSSF
  --    correctly via calculate_statutory_deductions().
  -------------------------------------------------------------------
  select count(*) into v_count from generate_payroll_items(v_run_id);
  if v_count != 2 then
    raise exception 'FAIL: generate_payroll_items returned % rows on first run, expected 2 (the two active employees)', v_count;
  end if;

  select count(*) into v_count from hr_payroll_items where payroll_run_id = v_run_id;
  if v_count != 2 then
    raise exception 'FAIL: hr_payroll_items has % rows for the run, expected 2', v_count;
  end if;

  if exists (select 1 from hr_payroll_items where payroll_run_id = v_run_id and employee_id = v_emp_inactive) then
    raise exception 'FAIL: the inactive employee got a payroll item generated';
  end if;

  select * into v_item1 from hr_payroll_items where payroll_run_id = v_run_id and employee_id = v_emp1;
  select * into v_calc from calculate_statutory_deductions(v_item1.basic_salary);
  if v_item1.basic_salary != 300000 then
    raise exception 'FAIL: emp1 item has basic_salary %, expected 300000', v_item1.basic_salary;
  end if;
  if v_item1.paye_amount != v_calc.paye_amount or v_item1.nssf_employee != v_calc.nssf_employee
     or v_item1.nssf_employer != v_calc.nssf_employer then
    raise exception 'FAIL: emp1 item statutory amounts (paye=%, nssf_ee=%, nssf_er=%) do not match calculate_statutory_deductions (paye=%, nssf_ee=%, nssf_er=%)',
      v_item1.paye_amount, v_item1.nssf_employee, v_item1.nssf_employer,
      v_calc.paye_amount, v_calc.nssf_employee, v_calc.nssf_employer;
  end if;
  if v_item1.net_pay != v_item1.basic_salary + v_item1.allowances - v_item1.deductions - v_item1.paye_amount - v_item1.nssf_employee then
    raise exception 'FAIL: emp1 item net_pay % does not match the documented formula', v_item1.net_pay;
  end if;

  select * into v_item2 from hr_payroll_items where payroll_run_id = v_run_id and employee_id = v_emp2;
  select * into v_calc from calculate_statutory_deductions(v_item2.basic_salary);
  if v_item2.paye_amount != v_calc.paye_amount or v_item2.nssf_employee != v_calc.nssf_employee
     or v_item2.nssf_employer != v_calc.nssf_employer then
    raise exception 'FAIL: emp2 item statutory amounts do not match calculate_statutory_deductions';
  end if;
  -- emp2's gross (1,200,000) sits in the 20%-band with a nonzero
  -- base_tax, so this also exercises the base_tax addition, not just
  -- the zero-tax band emp1 falls into.
  if v_item2.paye_amount = 0 then
    raise exception 'FAIL: emp2 (gross 1,200,000) has paye_amount = 0, expected a nonzero band-3 amount';
  end if;

  raise notice 'PASS: generate_payroll_items creates correct items for active employees and skips the inactive one';

  -------------------------------------------------------------------
  -- 3. generate_payroll_items() is additive across calls: a
  --    newly-added active employee is picked up on a second call,
  --    without duplicating or recomputing the existing items.
  -------------------------------------------------------------------
  reset role;
  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, is_active)
  values (v_tenant_id, 'PLACEHOLDER', 'David', 'Draku', 'david@payroll-test.local', true)
  returning id into v_emp3;
  insert into hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, created_by)
  values (v_tenant_id, v_emp3, 2000000, current_date - 30, v_hr_user_id);
  set local role authenticated;

  select count(*) into v_new_count from generate_payroll_items(v_run_id);
  if v_new_count != 1 then
    raise exception 'FAIL: second generate_payroll_items call returned % new rows, expected 1 (just the new employee)', v_new_count;
  end if;

  select count(*) into v_count from hr_payroll_items where payroll_run_id = v_run_id;
  if v_count != 3 then
    raise exception 'FAIL: hr_payroll_items has % rows for the run after the second call, expected 3', v_count;
  end if;

  if not exists (select 1 from hr_payroll_items where payroll_run_id = v_run_id and employee_id = v_emp3) then
    raise exception 'FAIL: the newly-added employee did not get a payroll item on the second call';
  end if;

  -- emp1/emp2's items must be untouched by the second call (same
  -- computed amounts, not re-inserted or recomputed).
  if not exists (
    select 1 from hr_payroll_items
    where payroll_run_id = v_run_id and employee_id = v_emp1
      and paye_amount = v_item1.paye_amount and nssf_employee = v_item1.nssf_employee
  ) then
    raise exception 'FAIL: emp1''s existing item changed after the second generate_payroll_items call';
  end if;

  raise notice 'PASS: generate_payroll_items is additive -- picks up new employees without touching existing items';

  -------------------------------------------------------------------
  -- 4. generate_payroll_items() rejects a run that's no longer draft.
  -------------------------------------------------------------------
  reset role;
  update hr_payroll_runs set status = 'pending_approval' where id = v_run_id;
  set local role authenticated;

  v_caught := false;
  begin
    perform generate_payroll_items(v_run_id);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: generate_payroll_items on a non-draft run was NOT rejected';
  end if;

  raise notice 'PASS: generate_payroll_items correctly rejects a non-draft run';

  -------------------------------------------------------------------
  -- 5. generate_payroll_items() rejects a run id that doesn't exist
  --    (or doesn't belong to the caller's tenant).
  -------------------------------------------------------------------
  v_caught := false;
  begin
    perform generate_payroll_items(gen_random_uuid());
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: generate_payroll_items on a nonexistent run id was NOT rejected';
  end if;

  raise notice 'PASS: generate_payroll_items correctly rejects a nonexistent run id';

  -------------------------------------------------------------------
  -- 6. update_payroll_item() happy path: editing allowances
  --    recomputes PAYE/NSSF on (basic_salary + allowances), and
  --    net_pay reflects the new figures.
  -------------------------------------------------------------------
  select * into v_run from create_payroll_run('2026-10');
  v_run2_id := v_run.id;
  perform generate_payroll_items(v_run2_id);

  select * into v_item from hr_payroll_items where payroll_run_id = v_run2_id and employee_id = v_emp1;
  select * into v_calc from calculate_statutory_deductions(v_item.basic_salary + 50000);

  select * into v_item from update_payroll_item(v_item.id, 50000, 20000, 'test note');

  if v_item.allowances != 50000 or v_item.deductions != 20000 or v_item.note != 'test note' then
    raise exception 'FAIL: update_payroll_item did not persist allowances/deductions/note correctly';
  end if;
  if v_item.paye_amount != v_calc.paye_amount or v_item.nssf_employee != v_calc.nssf_employee
     or v_item.nssf_employer != v_calc.nssf_employer then
    raise exception 'FAIL: update_payroll_item did not recompute statutory amounts on (basic_salary + allowances)';
  end if;
  if v_item.net_pay != v_item.basic_salary + v_item.allowances - v_item.deductions - v_item.paye_amount - v_item.nssf_employee then
    raise exception 'FAIL: updated item net_pay % does not match the documented formula', v_item.net_pay;
  end if;

  raise notice 'PASS: update_payroll_item updates fields and recomputes statutory deductions on basic+allowances';

  -------------------------------------------------------------------
  -- 7. update_payroll_item() rejects editing an item whose run is no
  --    longer draft (v_run_id was moved to pending_approval above).
  -------------------------------------------------------------------
  v_caught := false;
  begin
    perform update_payroll_item(v_item1.id, 0, 0, null);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: update_payroll_item on an item in a non-draft run was NOT rejected';
  end if;

  raise notice 'PASS: update_payroll_item correctly rejects an item whose run is no longer draft';

  -------------------------------------------------------------------
  -- 8. update_payroll_item() rejects a nonexistent item id.
  -------------------------------------------------------------------
  v_caught := false;
  begin
    perform update_payroll_item(gen_random_uuid(), 0, 0, null);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: update_payroll_item on a nonexistent item id was NOT rejected';
  end if;

  raise notice 'PASS: update_payroll_item correctly rejects a nonexistent item id';

  raise notice 'ALL PAYROLL GENERATION/UPDATE RPC TESTS PASSED';
end $$;

rollback;
