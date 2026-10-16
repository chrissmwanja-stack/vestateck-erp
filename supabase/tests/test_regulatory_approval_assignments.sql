-- Phase A1 follow-up: regulatory approval by assignment (regulatory_approval_assignments,
-- reg_assign_approver, reg_withdraw_approver, reg_approve_parameter).
--
-- Covers: the Insurance Admin prepares drafts but cannot approve; a company admin
-- cannot approve by role; approval follows an assignment by key or by category;
-- assignments must be in force today; withdrawal needs a reason and is kept on
-- record; only a company admin assigns or withdraws; the proposer can never approve
-- their own draft; scope and company are validated; clients cannot write the
-- assignment table; tenant isolation and anon denial.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs, so no fixture data is left behind. Any RAISE EXCEPTION is a real
-- assertion failure and makes psql exit non-zero.

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then
      return;
    end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

-- Switches the session to a given user (authenticated role).
create function pg_temp.as_user(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_adm   uuid := gen_random_uuid();   -- company admin A (no insurance role)
  v_ins   uuid := gen_random_uuid();   -- insurance admin A (drafts only)
  v_mgr   uuid := gen_random_uuid();   -- insurance manager A (no approval authority)
  v_chk   uuid := gen_random_uuid();   -- finance checker A
  v_out   uuid := gen_random_uuid();   -- no role at all
  v_adm_b uuid := gen_random_uuid();   -- company admin of tenant B

  v_vat uuid; v_rem uuid; v_stamp uuid; v_wht_broker uuid; v_wht_agent uuid; v_b uuid;
  v_as_chk_tax uuid; v_as_mgr_rem uuid; v_as_future uuid; v_as_expired uuid;
  v_row regulatory_parameters%rowtype;
  v_asg regulatory_approval_assignments%rowtype;
  v_n integer;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Reg Assign Co A'), (v_tb, 'Reg Assign Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'regasg-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_adm), (v_ins), (v_mgr), (v_chk), (v_out), (v_adm_b)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (v_adm,   v_ta, 'Assign Admin',   'regasg-' || v_adm   || '@test.local', true),
    (v_ins,   v_ta, 'Insurance Admin','regasg-' || v_ins   || '@test.local', false),
    (v_mgr,   v_ta, 'Insurance Mgr',  'regasg-' || v_mgr   || '@test.local', false),
    (v_chk,   v_ta, 'Finance Checker','regasg-' || v_chk   || '@test.local', false),
    (v_out,   v_ta, 'Outsider',       'regasg-' || v_out   || '@test.local', false),
    (v_adm_b, v_tb, 'Admin B',        'regasg-' || v_adm_b || '@test.local', true);

  insert into tenant_modules (tenant_id, module) values (v_ta, 'insurance'), (v_tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_ta, v_ins, 'insurance', 'admin'),
    (v_ta, v_mgr, 'insurance', 'manager');
  insert into finance_team_members (tenant_id, user_id, role) values (v_ta, v_chk, 'finance');

  -------------------------------------------------------------------
  -- 1. The Insurance Admin prepares drafts but cannot approve them
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_ins);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'tax.vat_standard_percent', 18, date '2026-01-01', 'UNVERIFIED: VAT rate')
  returning id into v_vat;
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_vat), 'REG_SELF_APPROVAL',
    'insurance admin approves own draft');
  reset role;

  perform pg_temp.as_user(v_adm);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_vat), 'REG_NOT_APPROVER',
    'company admin approves without an assignment');
  reset role;

  perform pg_temp.as_user(v_mgr);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_vat), 'REG_NOT_APPROVER',
    'insurance manager approves without an assignment');
  reset role;

  perform pg_temp.as_user(v_out);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_vat), 'REG_NOT_APPROVER',
    'outsider approves');
  reset role;

  select * into v_row from regulatory_parameters where id = v_vat;
  if v_row.status <> 'draft' then
    raise exception 'FAIL: refused approvals must leave the draft as a draft (status %)', v_row.status;
  end if;
  raise notice 'PASS: Insurance Admin cannot approve; company admin and others without an assignment are refused';

  -------------------------------------------------------------------
  -- 2. Only a company admin assigns approvers; the table cannot be written directly
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_ins);
  perform pg_temp.expect_error(
    format($q$select reg_assign_approver(%L, 'category', 'tax', 'Tax submissions', date '2026-01-01', null)$q$, v_chk),
    'REG_FORBIDDEN', 'insurance admin assigns an approver');
  reset role;

  perform pg_temp.as_user(v_chk);
  perform pg_temp.expect_error(
    format($q$select reg_assign_approver(%L, 'category', 'tax', 'Tax submissions', date '2026-01-01', null)$q$, v_chk),
    'REG_FORBIDDEN', 'finance user assigns self');
  reset role;

  perform pg_temp.as_user(v_adm);
  perform pg_temp.expect_error(
    format($q$insert into regulatory_approval_assignments (tenant_id, user_id, scope, scope_value, responsibility, effective_from, assigned_by)
              values (%L, %L, 'category', 'tax', 'direct', date '2026-01-01', %L)$q$, v_ta, v_chk, v_adm),
    'permission denied', 'company admin writes the assignment table directly');
  reset role;
  raise notice 'PASS: only a company admin can assign; the assignment table is not writable by clients';

  -------------------------------------------------------------------
  -- 3. Assignment input is validated
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_adm);
  perform pg_temp.expect_error(
    format($q$select reg_assign_approver(%L, 'category', 'tax', '   ', date '2026-01-01', null)$q$, v_chk),
    'REG_INPUT', 'blank responsibility');
  perform pg_temp.expect_error(
    format($q$select reg_assign_approver(%L, 'key', 'no.such.key', 'Test', date '2026-01-01', null)$q$, v_chk),
    'REG_NOT_FOUND', 'unknown key');
  perform pg_temp.expect_error(
    format($q$select reg_assign_approver(%L, 'category', 'no_such_category', 'Test', date '2026-01-01', null)$q$, v_chk),
    'REG_NOT_FOUND', 'unknown category');
  perform pg_temp.expect_error(
    format($q$select reg_assign_approver(%L, 'category', 'tax', 'Test', date '2026-01-01', null)$q$, v_adm_b),
    'REG_NOT_FOUND', 'approver from another company');
  perform pg_temp.expect_error(
    format($q$select reg_assign_approver(%L, 'category', 'tax', 'Test', date '2026-06-01', date '2026-05-01')$q$, v_chk),
    'reg_approval_assignment_dates', 'end date before start date');
  reset role;
  raise notice 'PASS: blank responsibility, unknown key or category, other-company approver and bad dates are refused';

  -------------------------------------------------------------------
  -- 4. Assign the checker to the tax category, the manager to one key
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_adm);
  select * into v_asg from reg_assign_approver(v_chk, 'category', 'tax',
    'Tax submissions to URA (test)', date '2017-01-01', null);
  reset role;
  v_as_chk_tax := v_asg.id;
  if v_asg.withdrawn_at is not null or v_asg.assigned_by <> v_adm or v_asg.scope_value <> 'tax' then
    raise exception 'FAIL: assignment fields wrong (withdrawn %, assigned_by %)', v_asg.withdrawn_at, v_asg.assigned_by;
  end if;

  perform pg_temp.as_user(v_adm);
  select * into v_asg from reg_assign_approver(v_mgr, 'key', 'remittance.deadline_working_days',
    'Insurer remittance deadline (test)', current_date - 10, null);
  reset role;
  v_as_mgr_rem := v_asg.id;

  -- Assignments that must not be in force today
  perform pg_temp.as_user(v_adm);
  select * into v_asg from reg_assign_approver(v_chk, 'category', 'stamp_duty',
    'Stamp duty (future, test)', current_date + 30, null);
  v_as_future := v_asg.id;
  select * into v_asg from reg_assign_approver(v_mgr, 'category', 'stamp_duty',
    'Stamp duty (expired, test)', current_date - 100, current_date - 1);
  v_as_expired := v_asg.id;
  reset role;
  raise notice 'PASS: category and key assignments created by a company admin';

  -------------------------------------------------------------------
  -- 5. Approval follows the assignment
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_chk);
  select * into v_row from reg_approve_parameter(v_vat);
  reset role;
  if v_row.status <> 'approved' or v_row.approved_by <> v_chk or v_row.approved_at is null then
    raise exception 'FAIL: assigned checker approval fields wrong (status %, approved_by %)', v_row.status, v_row.approved_by;
  end if;
  raise notice 'PASS: assigned checker approves a tax draft by category';

  -- A key assignment covers its key only; the checker has no authority over remittance
  perform pg_temp.as_user(v_ins);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'remittance.deadline_working_days', 3, date '2026-01-01', 'UNVERIFIED: remittance')
  returning id into v_rem;
  reset role;

  perform pg_temp.as_user(v_chk);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_rem), 'REG_NOT_APPROVER',
    'tax-category approver approves a remittance draft');
  reset role;

  perform pg_temp.as_user(v_mgr);
  select * into v_row from reg_approve_parameter(v_rem);
  reset role;
  if v_row.status <> 'approved' or v_row.approved_by <> v_mgr then
    raise exception 'FAIL: key-assigned manager approval wrong (status %)', v_row.status;
  end if;
  raise notice 'PASS: key assignment covers its key; category assignment does not cover other categories';

  -- Future and expired assignments do not grant authority today
  perform pg_temp.as_user(v_ins);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, currency, effective_from, source_ref)
  values (v_ta, 'stamp_duty.policy', 3000, 'UGX', date '2026-01-01', 'UNVERIFIED: stamp duty')
  returning id into v_stamp;
  reset role;

  perform pg_temp.as_user(v_chk);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_stamp), 'REG_NOT_APPROVER',
    'checker approves before the assignment starts');
  reset role;

  perform pg_temp.as_user(v_mgr);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_stamp), 'REG_NOT_APPROVER',
    'manager approves after the assignment ended');
  reset role;
  raise notice 'PASS: future-dated and expired assignments do not grant approval today';

  -------------------------------------------------------------------
  -- 6. Withdrawal: needs a reason, is kept on record, and ends authority
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_ins);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'tax.wht_broker_commission_percent', 5, date '2026-01-01', 'UNVERIFIED: WHT broker')
  returning id into v_wht_broker;
  perform pg_temp.expect_error(format('select reg_withdraw_approver(%L, %L)', v_as_chk_tax, 'x'), 'REG_FORBIDDEN',
    'insurance admin withdraws an approver');
  reset role;

  perform pg_temp.as_user(v_adm);
  perform pg_temp.expect_error(format('select reg_withdraw_approver(%L, %L)', v_as_chk_tax, '  '), 'REG_INPUT',
    'withdrawal without a reason');
  reset role;

  perform pg_temp.as_user(v_adm_b);
  perform pg_temp.expect_error(format('select reg_withdraw_approver(%L, %L)', v_as_chk_tax, 'Other company'), 'REG_NOT_FOUND',
    'other company admin withdraws an assignment');
  reset role;

  perform pg_temp.as_user(v_adm);
  select * into v_asg from reg_withdraw_approver(v_as_chk_tax, 'Checker moved to another role (test)');
  perform pg_temp.expect_error(format('select reg_withdraw_approver(%L, %L)', v_as_chk_tax, 'again'), 'REG_NOT_FOUND',
    'withdraw twice');
  reset role;
  if v_asg.withdrawn_at is null or v_asg.withdrawn_by <> v_adm or v_asg.withdrawn_reason is null then
    raise exception 'FAIL: withdrawal not recorded';
  end if;

  select count(*) into v_n from regulatory_approval_assignments
   where id = v_as_chk_tax and withdrawn_at is not null;
  if v_n <> 1 then
    raise exception 'FAIL: withdrawn assignment must be kept on record';
  end if;

  perform pg_temp.as_user(v_chk);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_wht_broker), 'REG_NOT_APPROVER',
    'checker approves after withdrawal');
  reset role;
  raise notice 'PASS: withdrawal needs a reason, is kept on record, and ends the approver''s authority';

  -------------------------------------------------------------------
  -- 7. The proposer never approves their own draft, even when assigned
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_adm);
  select * into v_asg from reg_assign_approver(v_chk, 'category', 'tax',
    'Tax submissions, second term (test)', date '2017-01-01', null);
  reset role;

  perform pg_temp.as_user(v_chk);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'tax.wht_agent_commission_percent', 6, date '2026-01-01', 'UNVERIFIED: WHT agent')
  returning id into v_wht_agent;
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_wht_agent), 'REG_SELF_APPROVAL',
    'assigned checker approves own draft');
  reset role;
  raise notice 'PASS: proposer self-approval refused even with an assignment';

  -------------------------------------------------------------------
  -- 8. Assignment rows are immutable except for withdrawal (guard)
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format('update regulatory_approval_assignments set responsibility = %L where id = %L', 'changed', v_as_mgr_rem),
    'REG_ASSIGNMENT_IMMUTABLE', 'edit an assignment in place');
  raise notice 'PASS: assignment rows cannot be edited in place';

  -------------------------------------------------------------------
  -- 9. Tenant isolation and anon denial (positive control first)
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_adm);
  select count(*) into v_n from regulatory_approval_assignments where tenant_id = v_ta;
  reset role;
  if v_n < 3 then
    raise exception 'FAIL: positive control: company admin should see the company assignments (found %)', v_n;
  end if;

  perform pg_temp.as_user(v_adm_b);
  select count(*) into v_n from regulatory_approval_assignments where tenant_id = v_ta;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL: another company sees assignments (found %)', v_n;
  end if;
  raise notice 'PASS: assignments are not visible across companies';

  set local role anon;
  perform pg_temp.expect_error('select count(*) from regulatory_approval_assignments', 'permission denied',
    'anon reads assignments');
  reset role;

  raise notice 'ALL PASS: regulatory approval by assignment';
end $$;

rollback;
