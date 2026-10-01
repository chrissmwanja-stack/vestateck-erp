-- Authorization test for the RPCs and direct-table paths that had no test.
--
-- Covers:
--   * record_approval_decision (stage permission, anti-collusion, delegation
--     windows, impersonation attribution)
--   * submit_payroll_run / approve_payroll_run / reject_payroll_run /
--     grant_payroll_approver (incl. separation of duties)
--   * share_purchase_order / confirm_po_delivered /
--     complete_purchase_order_manually (who may hand off a PO)
--   * set_staff_module_role / set_finance_role /
--     update_workflow_stage_approver_role / grant_delegation
--   * direct cross-tenant and self-escalation INSERT/UPDATE/DELETE on the
--     underlying tables
--   * company-level vs user-level platform-admin impersonation
--   * departments / organizations ownership: company admin (no module role)
--     writes, module admin / finance team / other tenants do not
--
-- Product decisions this file encodes (2026-09-29):
--   1. Payroll: the preparer of a run must NOT be able to approve it.
--   2. Impersonation: a company-level session (no specific user) is an
--      intentional full bypass for that tenant; a user-level session gets
--      exactly that user's permissions. approved_by / edited_by keep
--      recording the platform admin (the accountable actor).
--   3. PO handoff: only the selected-offer submitter and PO-access holders
--      (incl. their active delegates) may share a PO or confirm delivery.
--      Members of the approval chain get no handoff rights.
--   4. Departments and organizations are company-level configuration owned
--      by the company admin (is_tenant_admin()); finance keeps READ on
--      organizations, every tenant member reads departments (2026-10-01).
--
-- Result model: nothing aborts on the first problem. Every check records
-- PASS, FAIL or GAP in authz_t.results and one summary block at the end
-- raises a single exception listing every FAIL (psql -v ON_ERROR_STOP=1
-- then exits non-zero). GAP is a notice only: it marks behaviour that is
-- looser than the strict reading but that no decision has covered yet
-- (module-not-enabled grants, attribution columns, direct-table writes under
-- a user-level session, anon EXECUTE on public RPCs).
--
-- Local/CI database only (see test_gl_posting_and_period_close.sql header).
-- Everything, including the helper schema, runs in one transaction that
-- ROLLBACKs.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Helper schema (rolled back with everything else)
-- ---------------------------------------------------------------------
create schema authz_t;

create table authz_t.ids (k text primary key, v uuid not null);
create table authz_t.results (
  n bigint generated always as identity primary key,
  status text not null,
  name text not null,
  detail text
);
create table authz_t.snap (tbl text, row_id uuid, h text, primary key (tbl, row_id));

-- Owner-context helpers (SECURITY DEFINER): safe to call while the session
-- role is 'authenticated'/'anon'.
create function authz_t.id(p_key text) returns uuid
language sql stable security definer as $$
  select v from authz_t.ids where k = p_key
$$;

create function authz_t.q(p_sql text) returns text
language plpgsql security definer as $$
declare r text;
begin
  execute p_sql into r;
  return r;
end $$;

create function authz_t.x(p_sql text) returns void
language plpgsql security definer as $$
begin
  execute p_sql;
end $$;

create function authz_t.rec(p_status text, p_name text, p_detail text default null) returns void
language plpgsql security definer as $$
begin
  insert into authz_t.results (status, name, detail) values (p_status, p_name, p_detail);
  raise notice '%: % %', p_status, p_name, coalesce('-- ' || p_detail, '');
end $$;

create function authz_t.check(p_name text, p_ok boolean, p_detail text default null) returns void
language plpgsql as $$
begin
  perform authz_t.rec(case when coalesce(p_ok, false) then 'PASS' else 'FAIL' end, p_name,
                      case when coalesce(p_ok, false) then null else p_detail end);
end $$;

create function authz_t.gap(p_name text, p_detail text) returns void
language plpgsql as $$
begin
  perform authz_t.rec('GAP', p_name, p_detail);
end $$;

-- Caller-context helpers (SECURITY INVOKER on purpose: they must run as the
-- role/claims the test switched to).
create function authz_t.become(p_key text, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', authz_t.id(p_key), 'role', 'authenticated', 'aal', p_aal)::text, true);
end $$;

-- null = the statement succeeded; otherwise 'SQLSTATE message'.
create function authz_t.attempt(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $$;

-- '<rows>' or 'E:<sqlstate> <message>'
create function authz_t.rows_hit(p_sql text) returns text
language plpgsql as $$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n::text;
exception when others then
  return 'E:' || sqlstate || ' ' || sqlerrm;
end $$;

-- Positive control: the legitimate actor must succeed (proves the fixture
-- and the call shape are valid, so the matching denial is not vacuous).
create function authz_t.expect_ok(p_name text, p_sql text) returns void
language plpgsql as $$
declare e text := authz_t.attempt(p_sql);
begin
  perform authz_t.check(p_name, e is null, 'expected success, got: ' || coalesce(e, ''));
end $$;

-- Denied, optionally with a required SQLSTATE and/or message fragment so an
-- unrelated fixture error cannot masquerade as a denial.
create function authz_t.expect_denied(p_name text, p_sql text,
                                      p_state text default null, p_msg text default null) returns void
language plpgsql as $$
declare e text := authz_t.attempt(p_sql);
begin
  if e is null then
    perform authz_t.rec('FAIL', p_name, 'call succeeded but should have been denied');
  elsif p_state is not null and left(e, 5) <> p_state then
    perform authz_t.rec('FAIL', p_name, 'denied with the wrong SQLSTATE (wanted ' || p_state || '): ' || e);
  elsif p_msg is not null and e not ilike '%' || p_msg || '%' then
    perform authz_t.rec('FAIL', p_name, 'denied for the wrong reason (wanted "' || p_msg || '"): ' || e);
  else
    perform authz_t.rec('PASS', p_name);
  end if;
end $$;

-- A write that RLS must neutralise: 0 rows, or an RLS/permission error.
create function authz_t.expect_blocked(p_name text, p_sql text) returns void
language plpgsql as $$
declare r text := authz_t.rows_hit(p_sql);
begin
  if r = '0' or r like 'E:42501%' then
    perform authz_t.rec('PASS', p_name);
  else
    perform authz_t.rec('FAIL', p_name, 'expected 0 rows or 42501, got: ' || r);
  end if;
end $$;

create function authz_t.snapshot(p_tbl text, p_row uuid) returns void
language plpgsql security definer as $$
declare h text;
begin
  execute format('select md5(t::text) from public.%I t where id = %L', p_tbl, p_row) into h;
  insert into authz_t.snap values (p_tbl, p_row, coalesce(h, 'MISSING'))
  on conflict (tbl, row_id) do update set h = excluded.h;
end $$;

create function authz_t.snapshot_unchanged(p_tbl text, p_row uuid) returns boolean
language plpgsql security definer as $$
declare h text; was text;
begin
  select s.h into was from authz_t.snap s where s.tbl = p_tbl and s.row_id = p_row;
  execute format('select md5(t::text) from public.%I t where id = %L', p_tbl, p_row) into h;
  return coalesce(h, 'MISSING') = was;
end $$;

create function authz_t.has_col(p_tbl text, p_col text) returns boolean
language sql stable security definer as $$
  select exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = p_tbl and column_name = p_col)
$$;

create function authz_t.first_id(p_tbl text, p_col text, p_val uuid) returns uuid
language plpgsql security definer as $$
declare r uuid;
begin
  execute format('select id from public.%I where %I = %L order by id limit 1', p_tbl, p_col, p_val) into r;
  return r;
end $$;

create function authz_t.snapshot_by(p_tbl text, p_col text, p_val uuid) returns void
language plpgsql as $$
begin
  perform authz_t.snapshot(p_tbl, authz_t.first_id(p_tbl, p_col, p_val));
end $$;

-- Fixture builders (owner context; bypass RLS).
create function authz_t.mk_user(p_key text, p_tenant_key text, p_company_admin boolean default false) returns uuid
language plpgsql security definer as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v, 'authenticated', 'authenticated',
    'authz-' || p_key || '-' || v || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );
  insert into public.app_users (id, tenant_id, name, email, is_company_admin)
  values (v, authz_t.id(p_tenant_key), 'AuthZ ' || p_key, 'authz-' || p_key || '-' || v || '@test.local', p_company_admin);
  insert into authz_t.ids values (p_key, v);
  return v;
end $$;

create function authz_t.mk_run(p_tenant_key text, p_prepared_by_key text,
                               p_status text default 'pending_approval', p_items boolean default true) returns uuid
language plpgsql security definer as $$
declare v uuid;
begin
  insert into public.hr_payroll_runs (tenant_id, period, prepared_by, status, submitted_at)
  values (authz_t.id(p_tenant_key), 'AZ-' || substr(gen_random_uuid()::text, 1, 8),
          authz_t.id(p_prepared_by_key), p_status,
          case when p_status <> 'draft' then now() end)
  returning id into v;
  if p_items then
    insert into public.hr_payroll_items (payroll_run_id, employee_id, basic_salary)
    values (v, authz_t.id('emp'), 100000);
  end if;
  return v;
end $$;

-- One open request (at S1 / S_T2) with a selected offer; optionally an
-- approval_actions row for `chain` and a PO.
create function authz_t.mk_case(p_side text default 'T1', p_chain boolean default false,
                                p_po boolean default false, out rid uuid, out poid uuid)
language plpgsql security definer as $$
declare t uuid; s uuid; d uuid; rq uuid; sb uuid; ch uuid; v_old text;
begin
  if p_side = 'T1' then
    t := authz_t.id('T1'); s := authz_t.id('S1'); d := authz_t.id('D1');
    rq := authz_t.id('requester'); sb := authz_t.id('offer_sub'); ch := authz_t.id('chain');
  else
    t := authz_t.id('T2'); s := authz_t.id('S_T2'); d := authz_t.id('D2');
    rq := authz_t.id('u2'); sb := authz_t.id('u2'); ch := null;
  end if;

  -- trg_set_request_defaults derives tenant/requester/department/stage from
  -- the caller's JWT, so build the request as its requester and restore the
  -- caller's claims afterwards.
  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', json_build_object('sub', rq)::text, true);

  insert into public.requests (tenant_id, requester_id, department_id, current_stage_id,
                               item_description, status, mr_number)
  values (t, rq, d, s, 'AuthZ item', 'open', 'MR-AZ-' || substr(gen_random_uuid()::text, 1, 8))
  returning id into rid;

  insert into public.request_offers (request_id, vendor_name, quotation_amount, submitted_by, is_selected)
  values (rid, 'AuthZ Vendor', 1000, sb, true);

  if p_chain and ch is not null then
    insert into public.approval_actions (request_id, workflow_stage_id, approver_id, decision)
    values (rid, s, ch, 'approved');
  end if;

  if p_po then
    insert into public.purchase_orders (request_id, po_number, vendor_name, amount, generated_by)
    values (rid, 'PO-AZ-' || substr(gen_random_uuid()::text, 1, 8), 'AuthZ Vendor', 1000, sb)
    returning id into poid;
  end if;

  perform set_config('request.jwt.claims', coalesce(v_old, ''), true);
end $$;

grant usage on schema authz_t to authenticated, anon;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_t1 uuid := gen_random_uuid();
  v_t2 uuid := gen_random_uuid();
  v_home uuid := gen_random_uuid();
  v_u uuid;
  v_s1 uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_st2 uuid := gen_random_uuid();
  v_d1 uuid := gen_random_uuid();
  v_d2 uuid := gen_random_uuid();
  v_emp uuid;
  k text;
begin
  insert into tenants (id, name, status) values
    (v_t1, 'AuthZ Suite T1', 'active'),
    (v_t2, 'AuthZ Suite T2', 'active'),
    (v_home, 'AuthZ Suite Platform Home', 'active');
  insert into authz_t.ids values ('T1', v_t1), ('T2', v_t2), ('HOME', v_home),
    ('S1', v_s1), ('S2', v_s2), ('S_T2', v_st2), ('D1', v_d1), ('D2', v_d2);

  -- The partial unique index allows one platform admin in the whole table.
  update app_users set is_platform_admin = false where is_platform_admin;

  -- Tenant 1 people
  foreach k in array array[
    'prep', 'appr', 'appr_off', 'hr2', 'plain', 'hradmin', 'offer_sub', 'chain', 'po_holder',
    'requester', 'late', 'tgt', 'fin', 'dele_ok', 'dele_expired', 'dele_revoked', 'dele_po', 'dele_po_off'
  ] loop
    perform authz_t.mk_user(k, 'T1');
  end loop;
  perform authz_t.mk_user('cadmin', 'T1', true);
  -- Tenant 2 people
  perform authz_t.mk_user('u2', 'T2');
  perform authz_t.mk_user('xadmin', 'T2', true);
  perform authz_t.mk_user('hr_t2', 'T2');
  -- Platform admin (own home tenant)
  v_u := authz_t.mk_user('padmin', 'HOME');
  update app_users set is_platform_admin = true where id = v_u;

  insert into tenant_modules (tenant_id, module) values (v_t1, 'hr'), (v_t2, 'hr');

  -- Payroll roles: prep holds BOTH HR-team and approver roles.
  insert into hr_team_members (tenant_id, user_id, role) values
    (v_t1, authz_t.id('prep'), 'hr'),
    (v_t1, authz_t.id('hr2'), 'hr'),
    (v_t2, authz_t.id('hr_t2'), 'hr');
  insert into payroll_approvers (tenant_id, user_id, role, is_active) values
    (v_t1, authz_t.id('prep'), 'approver', true),
    (v_t1, authz_t.id('appr'), 'approver', true),
    (v_t1, authz_t.id('appr_off'), 'approver', false),
    (v_t2, authz_t.id('xadmin'), 'approver', true);
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_t1, authz_t.id('hradmin'), 'hr', 'admin'),
    (v_t2, authz_t.id('u2'), 'hr', 'member');
  insert into finance_team_members (tenant_id, user_id, role) values
    (v_t1, authz_t.id('fin'), 'finance'),
    (v_t2, authz_t.id('u2'), 'finance');

  insert into hr_employees (tenant_id, employee_no, first_name, last_name, email, is_active)
  values (v_t1, 'PLACEHOLDER', 'Authz', 'Employee', 'authz-emp@test.local', true)
  returning id into v_emp;
  insert into authz_t.ids values ('emp', v_emp);

  -- Workflow: S1 (blocks offer-submitter approval) -> S2 (last stage, no
  -- next stages, so assignees at S2 hold PO access). S2 is deliberately NOT
  -- flagged is_finance_terminal_stage so approvals do not auto-create POs.
  -- set_department_defaults resolves the tenant from the caller's JWT;
  -- request defaults need every requester to have a department.
  perform set_config('request.jwt.claims', json_build_object('sub', authz_t.id('requester'))::text, true);
  insert into departments (id, tenant_id, name) values (v_d1, v_t1, 'AuthZ Dept T1');
  perform set_config('request.jwt.claims', json_build_object('sub', authz_t.id('u2'))::text, true);
  insert into departments (id, tenant_id, name) values (v_d2, v_t2, 'AuthZ Dept T2');
  perform set_config('request.jwt.claims', '', true);
  update app_users set department_id = v_d1 where id = authz_t.id('requester');
  update app_users set department_id = v_d2 where id = authz_t.id('u2');
  insert into workflow_stages (id, tenant_id, name, sequence_order, approver_role)
  values (v_s2, v_t1, 'AuthZ Final', 2, 'finance');
  insert into workflow_stages (id, tenant_id, name, sequence_order, approver_role,
                               next_stage_low_id, blocks_offer_submitter_approval)
  values (v_s1, v_t1, 'AuthZ Review', 1, 'manager', v_s2, true);
  insert into workflow_stages (id, tenant_id, name, sequence_order, approver_role)
  values (v_st2, v_t2, 'AuthZ T2 Stage', 1, 'manager');

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id) values
    (v_t1, authz_t.id('chain'), v_s1),
    (v_t1, authz_t.id('offer_sub'), v_s1),
    (v_t1, authz_t.id('po_holder'), v_s2),
    (v_t2, authz_t.id('u2'), v_st2);

  -- Delegations. dele_ok/expired/revoked delegate from chain at S1;
  -- dele_po/dele_po_off delegate from po_holder across all stages.
  insert into approval_delegations (tenant_id, delegator_user_id, delegate_user_id, workflow_stage_id, starts_at, ends_at, status) values
    (v_t1, authz_t.id('chain'), authz_t.id('dele_ok'), v_s1, now() - interval '1 hour', now() + interval '1 day', 'active'),
    (v_t1, authz_t.id('chain'), authz_t.id('dele_expired'), v_s1, now() - interval '2 days', now() - interval '1 day', 'active'),
    (v_t1, authz_t.id('chain'), authz_t.id('dele_revoked'), v_s1, now() - interval '1 hour', now() + interval '1 day', 'revoked'),
    (v_t1, authz_t.id('po_holder'), authz_t.id('dele_po'), null, now() - interval '1 hour', now() + interval '1 day', 'active'),
    (v_t1, authz_t.id('po_holder'), authz_t.id('dele_po_off'), null, now() - interval '2 days', now() - interval '1 day', 'active');
end $$;

set local role authenticated;

-- =====================================================================
-- A. Payroll: submit / approve / reject / grant, incl. separation of duties
-- =====================================================================
do $$
declare
  v_run uuid;
  v_e text;
  v_st text;
  v_row record;
begin
  raise notice '--- A. payroll ---';

  -- A1. submit_payroll_run
  v_run := authz_t.mk_run('T1', 'prep', 'draft');
  perform authz_t.become('plain');
  perform authz_t.expect_denied('submit_payroll_run: plain tenant user refused',
    format('select * from submit_payroll_run(%L)', v_run), null, 'not authorized');
  perform authz_t.become('appr');
  perform authz_t.expect_denied('submit_payroll_run: approver who is not on the HR team refused',
    format('select * from submit_payroll_run(%L)', v_run), null, 'not authorized');
  perform authz_t.become('hr_t2');
  perform authz_t.expect_denied('submit_payroll_run: HR user from another tenant cannot submit this tenant''s run',
    format('select * from submit_payroll_run(%L)', v_run));
  perform authz_t.check('submit_payroll_run: run still draft after the refused attempts',
    authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'draft');
  perform authz_t.become('hr2');
  perform authz_t.expect_ok('submit_payroll_run: HR-team member can submit (control)',
    format('select * from submit_payroll_run(%L)', v_run));
  perform authz_t.check('submit_payroll_run: control moved the run to pending_approval',
    authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'pending_approval');

  v_run := authz_t.mk_run('T1', 'prep', 'draft', false);
  perform authz_t.expect_denied('submit_payroll_run: run with no line items refused',
    format('select * from submit_payroll_run(%L)', v_run), null, 'no line items');

  -- A2. approve_payroll_run: non-approvers
  v_run := authz_t.mk_run('T1', 'prep');
  foreach v_e in array array['plain', 'hr2', 'hradmin', 'appr_off', 'hr_t2', 'xadmin', 'cadmin'] loop
    perform authz_t.become(v_e);
    perform authz_t.expect_denied('approve_payroll_run: ' || v_e || ' refused',
      format('select * from approve_payroll_run(%L)', v_run));
    perform authz_t.check('approve_payroll_run: run untouched after ' || v_e || '''s attempt',
      authz_t.q(format('select status || coalesce(approved_by::text, %L) from hr_payroll_runs where id = %L', '', v_run)) = 'pending_approval');
  end loop;

  -- A2b. approve_payroll_run: legitimate approver who is not the preparer
  perform authz_t.become('appr');
  perform authz_t.expect_ok('approve_payroll_run: active approver who did not prepare the run (control)',
    format('select * from approve_payroll_run(%L)', v_run));
  select * into v_row from hr_payroll_runs where id = v_run;
  perform authz_t.check('approve_payroll_run: control sets status=approved and approved_by=approver',
    authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'approved'
    and authz_t.q(format('select approved_by::text from hr_payroll_runs where id = %L', v_run)) = authz_t.id('appr')::text);
  perform authz_t.check('approve_payroll_run: control records effective_user_id = approver (direct call)',
    authz_t.has_col('hr_payroll_runs', 'effective_user_id')
    and authz_t.q(format('select effective_user_id::text from hr_payroll_runs where id = %L', v_run)) = authz_t.id('appr')::text
    and authz_t.q(format('select (impersonation_session_id is null)::text from hr_payroll_runs where id = %L', v_run)) = 'true');
  perform authz_t.expect_denied('approve_payroll_run: already-approved run cannot be approved again',
    format('select * from approve_payroll_run(%L)', v_run), null, 'not pending');

  -- A2c. SEPARATION OF DUTIES (decision 1): preparer holds both roles.
  v_run := authz_t.mk_run('T1', 'prep');
  perform authz_t.become('prep');
  v_e := authz_t.attempt(format('select * from approve_payroll_run(%L)', v_run));
  v_st := authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run));
  perform authz_t.check('approve_payroll_run: preparer cannot approve their own run (decision 1)',
    v_e is not null and v_st = 'pending_approval',
    format('call %s; run status is now %s', coalesce(v_e, 'succeeded'), v_st));

  -- A2d. active approver revoked mid-flight: appr_off has is_active=false (covered above)

  -- A3. reject_payroll_run
  v_run := authz_t.mk_run('T1', 'prep');
  foreach v_e in array array['plain', 'hr2', 'appr_off', 'hr_t2'] loop
    perform authz_t.become(v_e);
    perform authz_t.expect_denied('reject_payroll_run: ' || v_e || ' refused',
      format('select * from reject_payroll_run(%L, %L)', v_run, 'nope'));
  end loop;
  perform authz_t.become('appr');
  perform authz_t.expect_denied('reject_payroll_run: blank reason refused',
    format('select * from reject_payroll_run(%L, %L)', v_run, '   '), null, 'reason');
  perform authz_t.expect_ok('reject_payroll_run: active approver with a reason (control)',
    format('select * from reject_payroll_run(%L, %L)', v_run, 'figures do not reconcile'));
  perform authz_t.check('reject_payroll_run: control sets status=rejected and rejected_by=approver',
    authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'rejected'
    and authz_t.q(format('select rejected_by::text from hr_payroll_runs where id = %L', v_run)) = authz_t.id('appr')::text);
  perform authz_t.check('reject_payroll_run: control records effective_user_id = approver (direct call)',
    authz_t.has_col('hr_payroll_runs', 'effective_user_id')
    and authz_t.q(format('select effective_user_id::text from hr_payroll_runs where id = %L', v_run)) = authz_t.id('appr')::text
    and authz_t.q(format('select (impersonation_session_id is null)::text from hr_payroll_runs where id = %L', v_run)) = 'true');

  -- A3b. revise_payroll_run: HR only, and it clears the decision attribution
  foreach v_e in array array['plain', 'appr', 'hr_t2'] loop
    perform authz_t.become(v_e);
    perform authz_t.expect_denied('revise_payroll_run: ' || v_e || ' refused',
      format('select * from revise_payroll_run(%L)', v_run));
  end loop;
  perform authz_t.check('revise_payroll_run: run still rejected after the refused attempts',
    authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'rejected');
  perform authz_t.become('hr2');
  perform authz_t.expect_ok('revise_payroll_run: HR-team member (control)',
    format('select * from revise_payroll_run(%L)', v_run));
  perform authz_t.check('revise_payroll_run: control returns the run to draft and clears the decision fields',
    authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'draft'
    and authz_t.q(format('select (rejected_by is null and rejected_at is null and rejection_reason is null)::text from hr_payroll_runs where id = %L', v_run)) = 'true');
  perform authz_t.check('revise_payroll_run: control clears effective_user_id and impersonation_session_id',
    authz_t.has_col('hr_payroll_runs', 'effective_user_id')
    and authz_t.q(format('select (effective_user_id is null and impersonation_session_id is null)::text from hr_payroll_runs where id = %L', v_run)) = 'true');

  -- A4. grant_payroll_approver
  foreach v_e in array array['plain', 'appr', 'hr2', 'hr_t2'] loop
    perform authz_t.become(v_e);
    perform authz_t.expect_denied('grant_payroll_approver: ' || v_e || ' refused',
      format('select * from grant_payroll_approver(%L)', authz_t.id('late')), null, 'not authorized');
  end loop;
  perform authz_t.check('grant_payroll_approver: no approver row created by the refused attempts',
    authz_t.q(format('select count(*)::text from payroll_approvers where user_id = %L', authz_t.id('late'))) = '0');
  perform authz_t.become('hradmin');
  perform authz_t.expect_denied('grant_payroll_approver: HR admin cannot grant to a user in another tenant',
    format('select * from grant_payroll_approver(%L)', authz_t.id('u2')), null, 'not found in this tenant');
  perform authz_t.expect_ok('grant_payroll_approver: HR module admin (control)',
    format('select * from grant_payroll_approver(%L)', authz_t.id('late')));
  v_run := authz_t.mk_run('T1', 'prep');
  perform authz_t.become('late');
  perform authz_t.expect_ok('approve_payroll_run: a freshly granted approver can approve',
    format('select * from approve_payroll_run(%L)', v_run));

  -- A5. anon
  set local role anon;
  perform set_config('request.jwt.claims', '', true);
  v_run := authz_t.mk_run('T1', 'prep');
  perform authz_t.expect_denied('approve_payroll_run: anon refused',
    format('select * from approve_payroll_run(%L)', v_run));
  perform authz_t.expect_denied('submit_payroll_run: anon refused',
    format('select * from submit_payroll_run(%L)', v_run));
  set local role authenticated;
end $$;

-- =====================================================================
-- B. Purchase-order handoff (decision 3)
-- =====================================================================
do $$
declare
  v_c record;
  v_e text;
  v_who text;
begin
  raise notice '--- B. PO handoff ---';

  -- B1. share_purchase_order: everyone who must be refused
  foreach v_who in array array['plain', 'requester', 'chain', 'hr2', 'u2', 'dele_po_off'] loop
    select * into v_c from authz_t.mk_case('T1', true, true);
    perform authz_t.become(v_who);
    v_e := authz_t.attempt(format('select * from share_purchase_order(%L)', v_c.poid));
    perform authz_t.check(
      'share_purchase_order: ' || v_who || ' refused' ||
        case v_who when 'chain' then ' (approval-chain member, decision 3)'
                   when 'dele_po_off' then ' (expired delegation)'
                   when 'u2' then ' (other tenant)' else '' end,
      v_e is not null and authz_t.q(format('select shared_with_supplier::text from purchase_orders where id = %L', v_c.poid)) = 'false',
      format('call %s; shared_with_supplier=%s', coalesce(v_e, 'succeeded'),
             authz_t.q(format('select shared_with_supplier::text from purchase_orders where id = %L', v_c.poid))));
  end loop;

  -- B2. share_purchase_order: who must succeed (controls)
  foreach v_who in array array['offer_sub', 'po_holder', 'dele_po'] loop
    select * into v_c from authz_t.mk_case('T1', true, true);
    perform authz_t.become(v_who);
    perform authz_t.expect_ok('share_purchase_order: ' || v_who || ' allowed (control)',
      format('select * from share_purchase_order(%L)', v_c.poid));
    perform authz_t.check('share_purchase_order: ' || v_who || ' actually flipped shared_with_supplier',
      authz_t.q(format('select shared_with_supplier::text from purchase_orders where id = %L', v_c.poid)) = 'true');
  end loop;

  -- B3. confirm_po_delivered
  foreach v_who in array array['plain', 'requester', 'chain', 'hr2', 'u2', 'dele_po_off'] loop
    select * into v_c from authz_t.mk_case('T1', true, true);
    perform authz_t.x(format('update purchase_orders set shared_with_supplier = true where id = %L', v_c.poid));
    perform authz_t.become(v_who);
    v_e := authz_t.attempt(format('select * from confirm_po_delivered(%L)', v_c.poid));
    perform authz_t.check(
      'confirm_po_delivered: ' || v_who || ' refused' ||
        case v_who when 'chain' then ' (approval-chain member, decision 3)' else '' end,
      v_e is not null and authz_t.q(format('select delivered_at is null from purchase_orders where id = %L', v_c.poid)) = 'true',
      format('call %s; delivered_at is %s', coalesce(v_e, 'succeeded'),
             coalesce(authz_t.q(format('select delivered_at::text from purchase_orders where id = %L', v_c.poid)), 'null')));
  end loop;

  foreach v_who in array array['offer_sub', 'po_holder', 'dele_po'] loop
    select * into v_c from authz_t.mk_case('T1', true, true);
    perform authz_t.x(format('update purchase_orders set shared_with_supplier = true where id = %L', v_c.poid));
    perform authz_t.become(v_who);
    perform authz_t.expect_ok('confirm_po_delivered: ' || v_who || ' allowed (control)',
      format('select * from confirm_po_delivered(%L)', v_c.poid));
    perform authz_t.check('confirm_po_delivered: ' || v_who || ' actually set delivered_at',
      authz_t.q(format('select (delivered_at is not null)::text from purchase_orders where id = %L', v_c.poid)) = 'true');
  end loop;

  select * into v_c from authz_t.mk_case('T1', true, true);
  perform authz_t.become('offer_sub');
  perform authz_t.expect_denied('confirm_po_delivered: refused before the PO is shared with the supplier',
    format('select * from confirm_po_delivered(%L)', v_c.poid), null, 'before the PO has been shared');

  -- B4. complete_purchase_order_manually: PO-access holders only
  foreach v_who in array array['plain', 'offer_sub', 'chain', 'requester', 'u2'] loop
    select * into v_c from authz_t.mk_case('T1', true, true);
    perform authz_t.x(format('update purchase_orders set shared_with_supplier = true, delivered_at = now() where id = %L', v_c.poid));
    perform authz_t.become(v_who);
    v_e := authz_t.attempt(format('select * from complete_purchase_order_manually(%L, %L)', v_c.poid, 'settled offline'));
    perform authz_t.check('complete_purchase_order_manually: ' || v_who || ' refused',
      v_e is not null and authz_t.q(format('select (completed_at is null)::text from purchase_orders where id = %L', v_c.poid)) = 'true',
      format('call %s', coalesce(v_e, 'succeeded')));
  end loop;

  select * into v_c from authz_t.mk_case('T1', true, true);
  perform authz_t.x(format('update purchase_orders set shared_with_supplier = true where id = %L', v_c.poid));
  perform authz_t.become('po_holder');
  perform authz_t.expect_denied('complete_purchase_order_manually: refused before delivery',
    format('select * from complete_purchase_order_manually(%L, %L)', v_c.poid, 'x'), null, 'before it has been delivered');
  perform authz_t.x(format('update purchase_orders set delivered_at = now() where id = %L', v_c.poid));
  perform authz_t.expect_denied('complete_purchase_order_manually: blank reason refused',
    format('select * from complete_purchase_order_manually(%L, %L)', v_c.poid, ' '), null, 'reason');
  perform authz_t.expect_ok('complete_purchase_order_manually: PO-access holder (control)',
    format('select * from complete_purchase_order_manually(%L, %L)', v_c.poid, 'settled offline'));
  perform authz_t.check('complete_purchase_order_manually: control set completed_at and logged po_edits.edited_by',
    authz_t.q(format('select (completed_at is not null)::text from purchase_orders where id = %L', v_c.poid)) = 'true'
    and authz_t.q(format('select edited_by::text from po_edits where purchase_order_id = %L', v_c.poid)) = authz_t.id('po_holder')::text);

  -- B5. anon
  select * into v_c from authz_t.mk_case('T1', true, true);
  set local role anon;
  perform set_config('request.jwt.claims', '', true);
  perform authz_t.expect_denied('share_purchase_order: anon refused',
    format('select * from share_purchase_order(%L)', v_c.poid));
  perform authz_t.expect_denied('confirm_po_delivered: anon refused',
    format('select * from confirm_po_delivered(%L)', v_c.poid));
  perform authz_t.expect_denied('complete_purchase_order_manually: anon refused',
    format('select * from complete_purchase_order_manually(%L, %L)', v_c.poid, 'x'));
  set local role authenticated;
end $$;

-- =====================================================================
-- C. Role / delegation administration RPCs
-- =====================================================================
do $$
declare
  v_e text;
  v_who text;
  v_stage uuid := authz_t.id('S1');
begin
  raise notice '--- C. role administration ---';

  -- C1. set_staff_module_role
  foreach v_who in array array['plain', 'hr2', 'appr', 'xadmin'] loop
    perform authz_t.become(v_who);
    perform authz_t.expect_denied('set_staff_module_role: ' || v_who || ' refused',
      format('select * from set_staff_module_role(%L, %L, %L)', authz_t.id('tgt'), 'hr', 'admin'));
  end loop;
  perform authz_t.check('set_staff_module_role: no staff_roles row created by the refused attempts',
    authz_t.q(format('select count(*)::text from staff_roles where user_id = %L', authz_t.id('tgt'))) = '0');

  perform authz_t.become('cadmin');
  perform authz_t.expect_denied('set_staff_module_role: target in another tenant refused',
    format('select * from set_staff_module_role(%L, %L, %L)', authz_t.id('u2'), 'hr', 'admin'), null, 'not found in this tenant');
  perform authz_t.expect_denied('set_staff_module_role: unknown module rejected by CHECK',
    format('select * from set_staff_module_role(%L, %L, %L)', authz_t.id('tgt'), 'bogus', 'member'), '23514');
  perform authz_t.expect_denied('set_staff_module_role: unknown role rejected by CHECK',
    format('select * from set_staff_module_role(%L, %L, %L)', authz_t.id('tgt'), 'hr', 'owner'), '23514');
  perform authz_t.expect_ok('set_staff_module_role: company admin (control)',
    format('select * from set_staff_module_role(%L, %L, %L)', authz_t.id('tgt'), 'hr', 'member'));
  perform authz_t.expect_ok('set_staff_module_role: same user+module upserts the role',
    format('select * from set_staff_module_role(%L, %L, %L)', authz_t.id('tgt'), 'hr', 'manager'));
  perform authz_t.check('set_staff_module_role: upsert leaves exactly one row with the new role',
    authz_t.q(format('select count(*)::text || role from staff_roles where user_id = %L and module = %L group by role', authz_t.id('tgt'), 'hr')) = '1manager');

  -- Module not enabled for the tenant (T1 only has 'hr'). Not covered by a
  -- decision yet: reported as a GAP, not a failure.
  v_e := authz_t.attempt(format('select * from set_staff_module_role(%L, %L, %L)', authz_t.id('tgt'), 'legal', 'admin'));
  if v_e is null then
    perform authz_t.gap('set_staff_module_role: role in a module the tenant has not enabled',
      'granting legal/admin to a tenant that only has hr enabled was ACCEPTED (inert until the module is enabled, but it will silently activate then)');
  else
    perform authz_t.check('set_staff_module_role: role in a module the tenant has not enabled is refused', true);
  end if;

  -- C2. set_finance_role
  foreach v_who in array array['plain', 'hr2', 'hradmin', 'xadmin'] loop
    perform authz_t.become(v_who);
    perform authz_t.expect_denied('set_finance_role: ' || v_who || ' refused',
      format('select * from set_finance_role(%L, %L)', authz_t.id('tgt'), 'finance'));
  end loop;
  perform authz_t.check('set_finance_role: no finance row created by the refused attempts',
    authz_t.q(format('select count(*)::text from finance_team_members where user_id = %L', authz_t.id('tgt'))) = '0');
  perform authz_t.become('cadmin');
  perform authz_t.expect_denied('set_finance_role: target in another tenant refused',
    format('select * from set_finance_role(%L, %L)', authz_t.id('u2'), 'finance'), null, 'not found in this tenant');
  perform authz_t.expect_ok('set_finance_role: company admin (control)',
    format('select * from set_finance_role(%L, %L)', authz_t.id('tgt'), 'finance'));
  perform authz_t.expect_ok('set_finance_role: switching role replaces the previous one',
    format('select * from set_finance_role(%L, %L)', authz_t.id('tgt'), 'cost_control'));
  perform authz_t.check('set_finance_role: exactly one row remains and it is cost_control',
    authz_t.q(format('select count(*)::text || string_agg(role, %L) from finance_team_members where user_id = %L', ',', authz_t.id('tgt'))) = '1cost_control');
  perform authz_t.expect_denied('set_finance_role: invalid role rejected by CHECK',
    format('select * from set_finance_role(%L, %L)', authz_t.id('tgt'), 'bogus'), '23514');
  perform authz_t.check('set_finance_role: a rejected call does not strip the existing role',
    authz_t.q(format('select string_agg(role, %L) from finance_team_members where user_id = %L', ',', authz_t.id('tgt'))) = 'cost_control');

  -- C3. update_workflow_stage_approver_role (platform admin only)
  foreach v_who in array array['plain', 'cadmin', 'xadmin', 'hradmin'] loop
    perform authz_t.become(v_who);
    perform authz_t.expect_denied('update_workflow_stage_approver_role: ' || v_who || ' refused',
      format('select update_workflow_stage_approver_role(%L, %L)', v_stage, 'Hijacked'), '42501');
  end loop;
  perform authz_t.check('update_workflow_stage_approver_role: label unchanged after refused attempts',
    authz_t.q(format('select approver_role from workflow_stages where id = %L', v_stage)) = 'manager');
  perform authz_t.become('padmin');
  perform authz_t.expect_denied('update_workflow_stage_approver_role: blank label refused',
    format('select update_workflow_stage_approver_role(%L, %L)', v_stage, '  '), null, 'blank');
  perform authz_t.expect_denied('update_workflow_stage_approver_role: unknown stage refused',
    format('select update_workflow_stage_approver_role(%L, %L)', gen_random_uuid(), 'X'), null, 'not found');
  perform authz_t.expect_ok('update_workflow_stage_approver_role: platform admin (control)',
    format('select update_workflow_stage_approver_role(%L, %L)', v_stage, 'senior manager'));
  perform authz_t.check('update_workflow_stage_approver_role: control changed the label and wrote an audit event',
    authz_t.q(format('select approver_role from workflow_stages where id = %L', v_stage)) = 'senior manager'
    and authz_t.q(format('select count(*)::text from platform_audit_events where action = %L and target_id = %L',
                         'workflow.approver_role.update', v_stage::text)) = '1');
  perform authz_t.x(format('update workflow_stages set approver_role = %L where id = %L', 'manager', v_stage));

  -- C4. grant_delegation
  perform authz_t.become('plain');
  perform authz_t.expect_denied('grant_delegation: user without approval authority refused',
    format('select * from grant_delegation(%L, null, now(), now() + interval %L)', authz_t.id('tgt'), '1 day'), null, 'approval assignments');
  perform authz_t.become('chain');
  perform authz_t.expect_denied('grant_delegation: cannot delegate to yourself',
    format('select * from grant_delegation(%L, null, now(), now() + interval %L)', authz_t.id('chain'), '1 day'), null, 'yourself');
  perform authz_t.expect_denied('grant_delegation: ends_at is required',
    format('select * from grant_delegation(%L, null, now(), null)', authz_t.id('tgt')));
  perform authz_t.expect_denied('grant_delegation: ends_at must be after starts_at',
    format('select * from grant_delegation(%L, null, now(), now() - interval %L)', authz_t.id('tgt'), '1 hour'), null, 'after starts_at');
  perform authz_t.expect_denied('grant_delegation: delegate in another tenant refused',
    format('select * from grant_delegation(%L, null, now(), now() + interval %L)', authz_t.id('u2'), '1 day'), null, 'same tenant');
  perform authz_t.expect_denied('grant_delegation: cannot delegate a stage you do not hold',
    format('select * from grant_delegation(%L, %L, now(), now() + interval %L)', authz_t.id('tgt'), authz_t.id('S2'), '1 day'), null, 'do not hold approval authority');
  perform authz_t.expect_ok('grant_delegation: assignee delegating their own stage (control)',
    format('select * from grant_delegation(%L, %L, now(), now() + interval %L)', authz_t.id('tgt'), authz_t.id('S1'), '1 day'));
  perform authz_t.check('grant_delegation: control row is active, in tenant 1, delegator = caller',
    authz_t.q(format('select count(*)::text from approval_delegations where delegate_user_id = %L and delegator_user_id = %L and tenant_id = %L and status = %L',
                     authz_t.id('tgt'), authz_t.id('chain'), authz_t.id('T1'), 'active')) = '1');
  -- direct-table forgeries around the RPC
  perform authz_t.expect_denied('approval_delegations: direct INSERT naming a cross-tenant delegate refused',
    format('insert into approval_delegations (tenant_id, delegator_user_id, delegate_user_id, workflow_stage_id, starts_at, ends_at) values (%L, %L, %L, %L, now(), now() + interval %L)',
           authz_t.id('T1'), authz_t.id('chain'), authz_t.id('u2'), authz_t.id('S1'), '1 day'), '42501');
  perform authz_t.expect_denied('approval_delegations: direct INSERT forging another user as delegator refused',
    format('insert into approval_delegations (tenant_id, delegator_user_id, delegate_user_id, workflow_stage_id, starts_at, ends_at) values (%L, %L, %L, null, now(), now() + interval %L)',
           authz_t.id('T1'), authz_t.id('po_holder'), authz_t.id('chain'), '1 day'), '42501');
end $$;

-- =====================================================================
-- D. record_approval_decision
-- =====================================================================
do $$
declare
  v_c record;
  v_e text;
  v_who text;
begin
  raise notice '--- D. record_approval_decision ---';

  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.become('chain');
  perform authz_t.expect_denied('record_approval_decision: invalid decision refused',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'maybe'), null, 'invalid decision');

  foreach v_who in array array['plain', 'requester', 'hr2', 'po_holder', 'dele_expired', 'dele_revoked', 'u2', 'xadmin'] loop
    select * into v_c from authz_t.mk_case('T1');
    perform authz_t.become(v_who);
    v_e := authz_t.attempt(format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'));
    perform authz_t.check('record_approval_decision: ' || v_who || ' refused at S1' ||
        case v_who when 'dele_expired' then ' (expired delegation)' when 'dele_revoked' then ' (revoked delegation)'
                   when 'u2' then ' (other tenant)' when 'xadmin' then ' (other-tenant admin)' else '' end,
      v_e is not null
        and authz_t.q(format('select current_stage_id::text from requests where id = %L', v_c.rid)) = authz_t.id('S1')::text
        and authz_t.q(format('select count(*)::text from approval_actions where request_id = %L', v_c.rid)) = '0',
      format('call %s', coalesce(v_e, 'succeeded')));
  end loop;

  -- request no longer open
  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.x(format('update requests set status = %L where id = %L', 'closed', v_c.rid));
  perform authz_t.become('chain');
  perform authz_t.expect_denied('record_approval_decision: closed request refused',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'), null, 'not open');

  -- anti-collusion: offer submitter holds S1 but the stage blocks them
  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.become('offer_sub');
  perform authz_t.expect_denied('record_approval_decision: offer submitter cannot approve at a blocking stage',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'), null, 'submitted an offer');
  perform authz_t.become('chain');
  perform authz_t.expect_ok('record_approval_decision: a different assignee can approve the same request (control)',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'));
  perform authz_t.check('record_approval_decision: control advanced the request to S2',
    authz_t.q(format('select current_stage_id::text from requests where id = %L', v_c.rid)) = authz_t.id('S2')::text);
  perform authz_t.check('record_approval_decision: direct call records actor = approver = effective user',
    authz_t.q(format('select (approver_id = actor_id and actor_id = effective_user_id and impersonation_session_id is null)::text from approval_actions where request_id = %L and approver_id = %L',
                     v_c.rid, authz_t.id('chain'))) = 'true');

  -- active delegate
  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.become('dele_ok');
  perform authz_t.expect_ok('record_approval_decision: active delegate can act (control)',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'));
  perform authz_t.check('record_approval_decision: delegate is recorded as the approver',
    authz_t.q(format('select approver_id::text from approval_actions where request_id = %L', v_c.rid)) = authz_t.id('dele_ok')::text);

  -- rejection
  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.become('chain');
  perform authz_t.expect_ok('record_approval_decision: assignee can reject (control)',
    format('select * from record_approval_decision(%L, %L, %L)', v_c.rid, 'rejected', 'no'));
  perform authz_t.check('record_approval_decision: rejection sets the request to rejected',
    authz_t.q(format('select status from requests where id = %L', v_c.rid)) = 'rejected');
  perform authz_t.expect_denied('record_approval_decision: cannot act again on the rejected request',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'), null, 'not open');

  -- anon
  select * into v_c from authz_t.mk_case('T1');
  set local role anon;
  perform set_config('request.jwt.claims', '', true);
  perform authz_t.expect_denied('record_approval_decision: anon refused',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'));
  set local role authenticated;
end $$;

-- =====================================================================
-- E. Impersonation (decision 2)
-- =====================================================================
do $$
declare
  v_c record;
  v_run uuid;
  v_sess uuid;
  v_padmin uuid := authz_t.id('padmin');
  v_e text;
  v_events int;
begin
  raise notice '--- E. impersonation ---';

  -- E0. no session: a platform admin is NOT a member of tenant 1
  v_run := authz_t.mk_run('T1', 'prep');
  perform authz_t.become('padmin');
  perform authz_t.expect_denied('impersonation: platform admin with no active session cannot approve a tenant-1 payroll run',
    format('select * from approve_payroll_run(%L)', v_run));
  select * into v_c from authz_t.mk_case('T1', true, true);
  perform authz_t.expect_denied('impersonation: platform admin with no active session cannot share a tenant-1 PO',
    format('select * from share_purchase_order(%L)', v_c.poid));

  -- E1. company-level session = intentional full bypass for that tenant
  perform authz_t.expect_ok('impersonation: platform admin can start a company-level session',
    format('select * from start_impersonation(%L, %L)', authz_t.id('T1'), 'authz suite company-level'));
  v_sess := authz_t.q(format('select id::text from impersonation_sessions where platform_admin_id = %L and ended_at is null order by started_at desc limit 1', v_padmin))::uuid;

  perform authz_t.expect_ok('company-level session: approves a payroll run prepared by someone else (bypass is intended)',
    format('select * from approve_payroll_run(%L)', v_run));
  perform authz_t.check('company-level session: approved_by records the platform admin (the actor)',
    authz_t.q(format('select approved_by::text from hr_payroll_runs where id = %L', v_run)) = v_padmin::text);
  perform authz_t.expect_ok('company-level session: can share a PO',
    format('select * from share_purchase_order(%L)', v_c.poid));
  perform authz_t.expect_ok('company-level session: can confirm delivery',
    format('select * from confirm_po_delivered(%L)', v_c.poid));
  perform authz_t.expect_ok('company-level session: can settle a PO manually',
    format('select * from complete_purchase_order_manually(%L, %L)', v_c.poid, 'authz impersonation settle'));
  perform authz_t.check('company-level session: po_edits.edited_by records the platform admin (the actor)',
    authz_t.q(format('select edited_by::text from po_edits where purchase_order_id = %L', v_c.poid)) = v_padmin::text);
  perform authz_t.expect_ok('company-level session: can set a finance role (tenant-admin bypass)',
    format('select * from set_finance_role(%L, %L)', authz_t.id('late'), 'finance'));
  perform authz_t.expect_denied('company-level session: bypass stops at the tenant boundary (other-tenant user is not addressable)',
    format('select * from set_finance_role(%L, %L)', authz_t.id('u2'), 'finance'), null, 'not found in this tenant');

  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.expect_ok('company-level session: can decide an approval at the current stage',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'));
  perform authz_t.check('company-level session: approval_actions records actor = approver = effective = admin, with the session id',
    authz_t.q(format('select (approver_id = %L and actor_id = %L and effective_user_id = %L and impersonation_session_id = %L)::text from approval_actions where request_id = %L',
                     v_padmin, v_padmin, v_padmin, v_sess, v_c.rid)) = 'true');

  perform authz_t.expect_denied('company-level session: cannot mint delegations (grant_delegation is bound to the caller''s own assignments)',
    format('select * from grant_delegation(%L, null, now(), now() + interval %L)', authz_t.id('tgt'), '1 day'), null, 'approval assignments');

  -- E2. expired session gives no bypass
  perform authz_t.x(format('update impersonation_sessions set expires_at = now() - interval %L where id = %L', '1 minute', v_sess));
  v_run := authz_t.mk_run('T1', 'prep');
  perform authz_t.expect_denied('impersonation: expired session grants no payroll bypass',
    format('select * from approve_payroll_run(%L)', v_run));
  perform authz_t.x(format('update impersonation_sessions set ended_at = now() where id = %L', v_sess));

  -- E3. user-level session on an ordinary user = exactly that user's permissions
  perform authz_t.expect_ok('impersonation: platform admin can start a user-level session (ordinary user)',
    format('select * from start_impersonation(%L, %L, %L)', authz_t.id('T1'), 'authz suite user-level plain', authz_t.id('plain')));
  v_run := authz_t.mk_run('T1', 'prep');
  perform authz_t.expect_denied('user-level session (plain user): cannot approve payroll',
    format('select * from approve_payroll_run(%L)', v_run));
  select * into v_c from authz_t.mk_case('T1', true, true);
  perform authz_t.expect_denied('user-level session (plain user): cannot share a PO',
    format('select * from share_purchase_order(%L)', v_c.poid));
  perform authz_t.expect_denied('user-level session (plain user): cannot set a finance role',
    format('select * from set_finance_role(%L, %L)', authz_t.id('tgt'), 'finance'));
  perform authz_t.expect_denied('user-level session (plain user): cannot decide an approval',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'));

  -- GAP: direct-table policies check the raw is_platform_admin flag, so a
  -- user-level session still writes staff_roles directly.
  v_e := authz_t.attempt(format('insert into staff_roles (tenant_id, user_id, module, role) values (%L, %L, %L, %L)',
                                authz_t.id('T1'), authz_t.id('plain'), 'hr', 'admin'));
  if v_e is null then
    perform authz_t.gap('user-level session: direct staff_roles INSERT',
      'a user-level session on an ordinary user could still INSERT staff_roles directly (policy checks raw is_platform_admin, not platform_admin_bypass/effective user)');
    perform authz_t.x(format('delete from staff_roles where user_id = %L and module = %L and role = %L', authz_t.id('plain'), 'hr', 'admin'));
  else
    perform authz_t.check('user-level session: direct staff_roles INSERT refused', true);
  end if;

  -- E4. user-level session on an approver: acts as that user, attributed to the admin
  perform authz_t.expect_ok('impersonation: switching to a user-level session on an approver',
    format('select * from start_impersonation(%L, %L, %L)', authz_t.id('T1'), 'authz suite user-level approver', authz_t.id('appr')));
  v_sess := authz_t.q(format('select id::text from impersonation_sessions where platform_admin_id = %L and ended_at is null order by started_at desc limit 1', v_padmin))::uuid;
  v_run := authz_t.mk_run('T1', 'prep');
  perform authz_t.expect_ok('user-level session (approver): can approve a run the approver could approve',
    format('select * from approve_payroll_run(%L)', v_run));
  perform authz_t.check('user-level session: approved_by records the platform admin (the actor)',
    authz_t.q(format('select approved_by::text from hr_payroll_runs where id = %L', v_run)) = v_padmin::text);
  -- Effective-user attribution on payroll: needs a column to hold it.
  if authz_t.has_col('hr_payroll_runs', 'effective_user_id') then
    perform authz_t.check('user-level session: hr_payroll_runs.effective_user_id holds the impersonated user',
      authz_t.q(format('select effective_user_id::text from hr_payroll_runs where id = %L', v_run)) = authz_t.id('appr')::text);
    perform authz_t.check('user-level session: hr_payroll_runs.impersonation_session_id holds the session',
      authz_t.q(format('select impersonation_session_id::text from hr_payroll_runs where id = %L', v_run)) = v_sess::text);
  else
    perform authz_t.gap('user-level session: payroll approval attribution',
      'hr_payroll_runs has no effective_user_id/impersonation_session_id, so the impersonated approver is not recorded on the run (only platform_audit_events could show it)');
  end if;

  -- separation of duties must hold for the real actor too: a run the platform
  -- admin prepared (prepared_by = actor) cannot be approved by that admin while
  -- viewing as a different approver.
  v_run := authz_t.mk_run('T1', 'padmin');
  v_e := authz_t.attempt(format('select * from approve_payroll_run(%L)', v_run));
  perform authz_t.check('user-level session (approver): cannot approve a run the platform admin (actor) prepared (decision 1)',
    v_e is not null and authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'pending_approval',
    format('call %s', coalesce(v_e, 'succeeded')));

  -- separation of duties must hold for the effective identity too
  perform authz_t.expect_ok('impersonation: switching to a user-level session on the preparer',
    format('select * from start_impersonation(%L, %L, %L)', authz_t.id('T1'), 'authz suite user-level preparer', authz_t.id('prep')));
  v_run := authz_t.mk_run('T1', 'prep');
  v_e := authz_t.attempt(format('select * from approve_payroll_run(%L)', v_run));
  perform authz_t.check('user-level session (preparer): cannot approve the run the impersonated user prepared (decision 1)',
    v_e is not null and authz_t.q(format('select status from hr_payroll_runs where id = %L', v_run)) = 'pending_approval',
    format('call %s', coalesce(v_e, 'succeeded')));

  -- user-level session on an assignee: attribution and audit
  perform authz_t.expect_ok('impersonation: switching to a user-level session on an approval assignee',
    format('select * from start_impersonation(%L, %L, %L)', authz_t.id('T1'), 'authz suite user-level chain', authz_t.id('chain')));
  v_sess := authz_t.q(format('select id::text from impersonation_sessions where platform_admin_id = %L and ended_at is null order by started_at desc limit 1', v_padmin))::uuid;
  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.expect_ok('user-level session (assignee): can decide an approval',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'));
  perform authz_t.check('user-level session: approval_actions has approver = impersonated user, actor = admin, effective = impersonated user, session id set',
    authz_t.q(format('select (approver_id = %L and actor_id = %L and effective_user_id = %L and impersonation_session_id = %L)::text from approval_actions where request_id = %L',
                     authz_t.id('chain'), v_padmin, authz_t.id('chain'), v_sess, v_c.rid)) = 'true');

  select count(*) into v_events from platform_audit_events where action = 'request.reject.during_impersonation';
  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.expect_ok('user-level session (assignee): can reject a request',
    format('select * from record_approval_decision(%L, %L, %L)', v_c.rid, 'rejected', 'authz reject'));
  perform authz_t.check('user-level session: a rejection during impersonation writes a platform audit event',
    (select count(*) from platform_audit_events where action = 'request.reject.during_impersonation') = v_events + 1);

  -- anti-collusion applies to the effective identity
  perform authz_t.expect_ok('impersonation: switching to a user-level session on the offer submitter',
    format('select * from start_impersonation(%L, %L, %L)', authz_t.id('T1'), 'authz suite user-level submitter', authz_t.id('offer_sub')));
  select * into v_c from authz_t.mk_case('T1');
  perform authz_t.expect_denied('user-level session (offer submitter): anti-collusion block applies to the impersonated user',
    format('select * from record_approval_decision(%L, %L)', v_c.rid, 'approved'), null, 'submitted an offer');

  -- PO handoff under a user-level session on an approval-chain member
  perform authz_t.expect_ok('impersonation: switching to a user-level session on an approval-chain member',
    format('select * from start_impersonation(%L, %L, %L)', authz_t.id('T1'), 'authz suite user-level chain member', authz_t.id('chain')));
  select * into v_c from authz_t.mk_case('T1', true, true);
  v_e := authz_t.attempt(format('select * from share_purchase_order(%L)', v_c.poid));
  perform authz_t.check('user-level session (approval-chain member): cannot share the PO (decision 3)',
    v_e is not null, format('call %s', coalesce(v_e, 'succeeded')));

  -- close out
  perform authz_t.x(format('update impersonation_sessions set ended_at = now() where platform_admin_id = %L and ended_at is null', v_padmin));
end $$;

-- =====================================================================
-- F. Direct table access: cross-tenant and self-escalation
-- =====================================================================
do $$
declare
  v_t2c record;
  v_t1c record;
  v_t2_run uuid;
  v_t1_run uuid;
  v_ids jsonb := '{}'::jsonb;
  v_who text;
  v_tbl text;
  v_row uuid;
  v_t1 text := authz_t.id('T1')::text;
  v_t2 text := authz_t.id('T2')::text;
  r record;
  v_e text;
begin
  raise notice '--- F. direct table access ---';

  -- Targets (owner context)
  select * into v_t2c from authz_t.mk_case('T2', false, true);
  select * into v_t1c from authz_t.mk_case('T1', true, true);
  v_t2_run := authz_t.mk_run('T2', 'u2', 'pending_approval', false);
  v_t1_run := authz_t.mk_run('T1', 'prep');

  -- (table, row id) pairs that must never change under any attack below
  perform authz_t.snapshot_by('staff_roles', 'tenant_id', v_t2::uuid);
  perform authz_t.snapshot_by('finance_team_members', 'tenant_id', v_t2::uuid);
  perform authz_t.snapshot_by('payroll_approvers', 'tenant_id', v_t2::uuid);
  perform authz_t.snapshot('hr_payroll_runs', v_t2_run);
  perform authz_t.snapshot('workflow_stages', authz_t.id('S_T2'));
  perform authz_t.snapshot_by('approval_assignments', 'tenant_id', v_t2::uuid);
  perform authz_t.snapshot('requests', v_t2c.rid);
  perform authz_t.snapshot('purchase_orders', v_t2c.poid);
  perform authz_t.snapshot_by('hr_team_members', 'tenant_id', v_t2::uuid);
  -- tenant-1 rows the same-tenant attackers go after
  perform authz_t.snapshot_by('staff_roles', 'user_id', authz_t.id('hradmin'));
  perform authz_t.snapshot_by('finance_team_members', 'user_id', authz_t.id('fin'));
  perform authz_t.snapshot_by('payroll_approvers', 'user_id', authz_t.id('appr'));
  perform authz_t.snapshot('hr_payroll_runs', v_t1_run);
  perform authz_t.snapshot('workflow_stages', authz_t.id('S1'));
  perform authz_t.snapshot_by('approval_assignments', 'user_id', authz_t.id('chain'));
  perform authz_t.snapshot_by('hr_team_members', 'user_id', authz_t.id('hr2'));

  -- F1. INSERT into another tenant / self-escalation. Each must hit RLS (42501).
  foreach v_who in array array['cadmin', 'po_holder', 'hradmin'] loop
    perform authz_t.become(v_who);
    perform authz_t.expect_denied('cross-tenant INSERT staff_roles as ' || v_who,
      format('insert into staff_roles (tenant_id, user_id, module, role) values (%L, %L, %L, %L)', v_t2, authz_t.id('u2'), 'pmo', 'admin'), '42501');
    perform authz_t.expect_denied('cross-tenant INSERT finance_team_members as ' || v_who,
      format('insert into finance_team_members (tenant_id, user_id, role) values (%L, %L, %L)', v_t2, authz_t.id('u2'), 'cost_control'), '42501');
    perform authz_t.expect_denied('cross-tenant INSERT payroll_approvers as ' || v_who,
      format('insert into payroll_approvers (tenant_id, user_id, role) values (%L, %L, %L)', v_t2, authz_t.id('u2'), 'approver'), '42501');
    perform authz_t.expect_denied('cross-tenant INSERT hr_payroll_runs as ' || v_who,
      format('insert into hr_payroll_runs (tenant_id, period, prepared_by) values (%L, %L, %L)', v_t2, 'AZ-X', authz_t.id(v_who)), '42501');
    perform authz_t.expect_denied('cross-tenant INSERT approval_assignments as ' || v_who,
      format('insert into approval_assignments (tenant_id, user_id, workflow_stage_id) values (%L, %L, %L)', v_t2, authz_t.id('u2'), authz_t.id('S_T2')), '42501');
    perform authz_t.expect_denied('cross-tenant INSERT workflow_stages as ' || v_who,
      format('insert into workflow_stages (tenant_id, name, sequence_order, approver_role) values (%L, %L, 9, %L)', v_t2, 'AZ Injected', 'x'), '42501');
    -- trg_set_request_defaults overwrites tenant_id with the caller's own
    -- tenant, so this path can be refused by the trigger (no department) or
    -- land the row in the caller's tenant; what must never happen is a row
    -- appearing in tenant 2.
    v_e := authz_t.attempt(format('insert into requests (tenant_id, requester_id, department_id, item_description, mr_number) values (%L, %L, %L, %L, %L)',
             v_t2, authz_t.id(v_who), authz_t.id('D2'), 'AZ injected ' || v_who, 'MR-AZ-X-' || v_who));
    perform authz_t.check('cross-tenant INSERT requests as ' || v_who || ' creates no tenant-2 row',
      authz_t.q(format('select count(*)::text from requests where tenant_id = %L and item_description = %L', v_t2, 'AZ injected ' || v_who)) = '0',
      format('insert result: %s', coalesce(v_e, 'succeeded')));
  end loop;

  foreach v_who in array array['plain', 'hr2', 'offer_sub'] loop
    perform authz_t.become(v_who);
    perform authz_t.expect_denied('self-grant INSERT staff_roles admin as ' || v_who,
      format('insert into staff_roles (tenant_id, user_id, module, role) values (%L, %L, %L, %L)', v_t1, authz_t.id(v_who), 'hr', 'admin'), '42501');
    perform authz_t.expect_denied('self-grant INSERT finance_team_members as ' || v_who,
      format('insert into finance_team_members (tenant_id, user_id, role) values (%L, %L, %L)', v_t1, authz_t.id(v_who), 'finance'), '42501');
    perform authz_t.expect_denied('self-grant INSERT payroll_approvers as ' || v_who,
      format('insert into payroll_approvers (tenant_id, user_id, role) values (%L, %L, %L)', v_t1, authz_t.id(v_who), 'approver'), '42501');
    perform authz_t.expect_denied('self-grant INSERT approval_assignments as ' || v_who,
      format('insert into approval_assignments (tenant_id, user_id, workflow_stage_id) values (%L, %L, %L)', v_t1, authz_t.id(v_who), authz_t.id('S2')), '42501');
    perform authz_t.expect_denied('self-grant INSERT hr_team_members as ' || v_who,
      format('insert into hr_team_members (tenant_id, user_id, role) values (%L, %L, %L)', v_t1, authz_t.id(v_who), 'hr'), '42501');
    perform authz_t.expect_denied('direct INSERT hr_payroll_runs as ' || v_who || ' (must go through create_payroll_run)',
      format('insert into hr_payroll_runs (tenant_id, period, prepared_by) values (%L, %L, %L)', v_t1, 'AZ-Y', authz_t.id(v_who)), '42501');
  end loop;

  -- F2. UPDATE / DELETE against tenant-2 rows from tenant-1 privileged users
  foreach v_who in array array['cadmin', 'po_holder', 'hradmin'] loop
    perform authz_t.become(v_who);
    perform authz_t.expect_blocked('cross-tenant UPDATE staff_roles as ' || v_who,
      format('update staff_roles set role = %L, tenant_id = %L where tenant_id = %L', 'admin', v_t1, v_t2));
    perform authz_t.expect_blocked('cross-tenant DELETE staff_roles as ' || v_who,
      format('delete from staff_roles where tenant_id = %L', v_t2));
    perform authz_t.expect_blocked('cross-tenant UPDATE finance_team_members as ' || v_who,
      format('update finance_team_members set tenant_id = %L where tenant_id = %L', v_t1, v_t2));
    perform authz_t.expect_blocked('cross-tenant DELETE finance_team_members as ' || v_who,
      format('delete from finance_team_members where tenant_id = %L', v_t2));
    perform authz_t.expect_blocked('cross-tenant UPDATE payroll_approvers as ' || v_who,
      format('update payroll_approvers set is_active = false, tenant_id = %L where tenant_id = %L', v_t1, v_t2));
    perform authz_t.expect_blocked('cross-tenant DELETE payroll_approvers as ' || v_who,
      format('delete from payroll_approvers where tenant_id = %L', v_t2));
    perform authz_t.expect_blocked('cross-tenant UPDATE hr_payroll_runs as ' || v_who,
      format('update hr_payroll_runs set status = %L, approved_by = %L where id = %L', 'approved', authz_t.id(v_who), v_t2_run));
    perform authz_t.expect_blocked('cross-tenant DELETE hr_payroll_runs as ' || v_who,
      format('delete from hr_payroll_runs where id = %L', v_t2_run));
    perform authz_t.expect_blocked('cross-tenant UPDATE workflow_stages as ' || v_who,
      format('update workflow_stages set approver_role = %L, tenant_id = %L where id = %L', 'hijack', v_t1, authz_t.id('S_T2')));
    perform authz_t.expect_blocked('cross-tenant DELETE workflow_stages as ' || v_who,
      format('delete from workflow_stages where id = %L', authz_t.id('S_T2')));
    perform authz_t.expect_blocked('cross-tenant UPDATE approval_assignments as ' || v_who,
      format('update approval_assignments set tenant_id = %L where tenant_id = %L', v_t1, v_t2));
    perform authz_t.expect_blocked('cross-tenant DELETE approval_assignments as ' || v_who,
      format('delete from approval_assignments where tenant_id = %L', v_t2));
    perform authz_t.expect_blocked('cross-tenant UPDATE requests as ' || v_who,
      format('update requests set status = %L where id = %L', 'closed', v_t2c.rid));
    perform authz_t.expect_blocked('cross-tenant DELETE requests as ' || v_who,
      format('delete from requests where id = %L', v_t2c.rid));
    perform authz_t.expect_blocked('cross-tenant UPDATE purchase_orders as ' || v_who,
      format('update purchase_orders set shared_with_supplier = true, delivered_at = now(), amount = 1 where id = %L', v_t2c.poid));
    perform authz_t.expect_blocked('cross-tenant DELETE purchase_orders as ' || v_who,
      format('delete from purchase_orders where id = %L', v_t2c.poid));
    perform authz_t.expect_blocked('cross-tenant DELETE hr_team_members as ' || v_who,
      format('delete from hr_team_members where tenant_id = %L', v_t2));
  end loop;

  -- F3. Same-tenant direct writes that must go through the RPCs
  foreach v_who in array array['plain', 'hr2', 'prep', 'offer_sub'] loop
    perform authz_t.become(v_who);
    perform authz_t.expect_blocked('direct UPDATE hr_payroll_runs status as ' || v_who || ' (bypassing approve_payroll_run)',
      format('update hr_payroll_runs set status = %L, approved_by = %L where id = %L', 'approved', authz_t.id(v_who), v_t1_run));
    perform authz_t.expect_blocked('direct DELETE hr_payroll_runs as ' || v_who,
      format('delete from hr_payroll_runs where id = %L', v_t1_run));
    perform authz_t.expect_blocked('direct UPDATE payroll_approvers as ' || v_who,
      format('update payroll_approvers set is_active = false where user_id = %L', authz_t.id('appr')));
    perform authz_t.expect_blocked('direct DELETE payroll_approvers as ' || v_who,
      format('delete from payroll_approvers where user_id = %L', authz_t.id('appr')));
    perform authz_t.expect_blocked('direct UPDATE staff_roles as ' || v_who,
      format('update staff_roles set role = %L where user_id = %L', 'member', authz_t.id('hradmin')));
    perform authz_t.expect_blocked('direct DELETE staff_roles as ' || v_who,
      format('delete from staff_roles where user_id = %L', authz_t.id('hradmin')));
    perform authz_t.expect_blocked('direct UPDATE finance_team_members as ' || v_who,
      format('update finance_team_members set role = %L where user_id = %L', 'cost_control', authz_t.id('fin')));
    perform authz_t.expect_blocked('direct DELETE finance_team_members as ' || v_who,
      format('delete from finance_team_members where user_id = %L', authz_t.id('fin')));
    perform authz_t.expect_blocked('direct UPDATE workflow_stages as ' || v_who,
      format('update workflow_stages set approver_role = %L, blocks_offer_submitter_approval = false where id = %L', 'x', authz_t.id('S1')));
    perform authz_t.expect_blocked('direct DELETE approval_assignments as ' || v_who,
      format('delete from approval_assignments where user_id = %L', authz_t.id('chain')));
    perform authz_t.expect_blocked('direct UPDATE hr_team_members as ' || v_who,
      format('update hr_team_members set role = %L where user_id = %L', 'admin', authz_t.id('hr2')));
  end loop;

  -- F4. Nothing changed: every snapshotted row is byte-identical
  reset role;
  for r in select tbl, row_id from authz_t.snap order by tbl loop
    perform authz_t.check('row unchanged after all attacks: ' || r.tbl || ' ' || left(r.row_id::text, 8),
      authz_t.snapshot_unchanged(r.tbl, r.row_id));
  end loop;
end $$;

-- =====================================================================
-- G. Public RPC surface: anon EXECUTE (GAP only; behaviour is covered above)
-- =====================================================================
do $$
declare
  v_sig text;
begin
  raise notice '--- G. anon EXECUTE on public RPCs ---';
  foreach v_sig in array array[
    'public.record_approval_decision(uuid,text,text,uuid,uuid)',
    'public.submit_payroll_run(uuid)',
    'public.approve_payroll_run(uuid)',
    'public.reject_payroll_run(uuid,text)',
    'public.grant_payroll_approver(uuid)',
    'public.share_purchase_order(uuid)',
    'public.confirm_po_delivered(uuid)',
    'public.complete_purchase_order_manually(uuid,text)',
    'public.set_staff_module_role(uuid,text,text)',
    'public.set_finance_role(uuid,text)',
    'public.update_workflow_stage_approver_role(uuid,text)',
    'public.grant_delegation(uuid,uuid,timestamptz,timestamptz)'
  ] loop
    if has_function_privilege('anon', v_sig, 'EXECUTE') then
      perform authz_t.gap('anon EXECUTE on ' || v_sig,
        'anon holds EXECUTE (refused at runtime, but the privilege should not exist)');
    else
      perform authz_t.check('anon has no EXECUTE on ' || v_sig, true);
    end if;
  end loop;
end $$;

-- =====================================================================
-- H. Company admin owns departments and organizations (2026-10-01)
--    Writes are keyed to is_tenant_admin(): a company admin with no module
--    role and no finance row can write; a module admin and the finance team
--    cannot; nobody crosses tenants; a platform admin outside View-as cannot
--    touch a customer tenant's rows; a user-level View-as gets exactly that
--    user's rights (decision 2). Reads: everyone in the tenant reads
--    departments; organizations are read by finance, PO-access holders and
--    the company admin only.
-- =====================================================================
do $$
declare
  v_t1 uuid := authz_t.id('T1');
  v_dept uuid;
  v_org uuid;
  k text;
begin
  raise notice '--- H. departments / organizations ownership ---';

  -- Section F ends with `reset role`; without this the checks below would run as
  -- the table owner (a superuser in CI), which bypasses RLS, and every denial
  -- would look like a policy hole.
  set local role authenticated;

  -- Fixture sanity (owner context): the personas are what the checks assume.
  perform authz_t.check('fixture: cadmin is a company admin with no module role and no finance row',
    authz_t.q(format('select (a.is_company_admin and not exists (select 1 from staff_roles s where s.user_id = a.id) and not exists (select 1 from finance_team_members f where f.user_id = a.id))::text from app_users a where a.id = %L', authz_t.id('cadmin'))) = 'true');
  perform authz_t.check('fixture: hradmin holds an hr admin role and is not a company admin',
    authz_t.q(format('select (exists (select 1 from staff_roles s where s.user_id = a.id and s.module = %L and s.role = %L) and not a.is_company_admin)::text from app_users a where a.id = %L', 'hr', 'admin', authz_t.id('hradmin'))) = 'true');
  perform authz_t.check('fixture: fin is on the finance team and is not a company admin',
    authz_t.q(format('select (exists (select 1 from finance_team_members f where f.user_id = a.id and f.role = %L) and not a.is_company_admin)::text from app_users a where a.id = %L', 'finance', authz_t.id('fin'))) = 'true');

  -- ---- departments ---------------------------------------------------
  perform authz_t.become('cadmin');
  perform authz_t.expect_ok('departments: company admin (no module role) can create a department',
    format('insert into departments (tenant_id, name) values (%L, %L)', v_t1, 'AuthZ H dept'));
  v_dept := authz_t.q(format('select id::text from departments where tenant_id = %L and name = %L', v_t1, 'AuthZ H dept'))::uuid;
  perform authz_t.check('departments: company admin can rename a department',
    authz_t.rows_hit(format('update departments set name = %L where id = %L', 'AuthZ H dept 2', v_dept)) = '1');

  foreach k in array array['hradmin', 'fin', 'plain'] loop
    perform authz_t.become(k);
    perform authz_t.expect_blocked(format('departments: %s cannot create a department', k),
      format('insert into departments (tenant_id, name) values (%L, %L)', v_t1, 'AuthZ H denied ' || k));
    perform authz_t.expect_blocked(format('departments: %s cannot update a department', k),
      format('update departments set name = %L where id = %L', 'AuthZ H hijack', v_dept));
    perform authz_t.expect_blocked(format('departments: %s cannot delete a department', k),
      format('delete from departments where id = %L', v_dept));
    perform authz_t.check(format('departments: %s can still read the list', k),
      authz_t.rows_hit(format('select 1 from departments where id = %L', v_dept)) = '1');
  end loop;
  perform authz_t.check('departments: the denied attempts changed nothing',
    authz_t.q(format('select name from departments where id = %L', v_dept)) = 'AuthZ H dept 2');

  perform authz_t.become('xadmin');
  -- The BEFORE INSERT defaults triggers rewrite tenant_id to the caller's own tenant,
  -- so a cross-tenant insert may "succeed" -- but the row lands in the caller's tenant.
  -- The invariant is that nothing is created in THIS tenant.
  perform authz_t.attempt(format('insert into departments (tenant_id, name) values (%L, %L)', v_t1, 'AuthZ H cross-tenant'));
  perform authz_t.check('departments: another tenant''s company admin cannot create here (nothing lands in this tenant)',
    authz_t.q(format('select count(*)::text from departments where tenant_id = %L and name = %L', v_t1, 'AuthZ H cross-tenant')) = '0');
  perform authz_t.expect_blocked('departments: another tenant''s company admin cannot update here',
    format('update departments set name = %L where id = %L', 'AuthZ H hijack', v_dept));
  perform authz_t.expect_blocked('departments: another tenant''s company admin cannot delete here',
    format('delete from departments where id = %L', v_dept));
  perform authz_t.check('departments: another tenant''s company admin cannot read this tenant''s list',
    authz_t.rows_hit(format('select 1 from departments where id = %L', v_dept)) = '0');

  perform authz_t.become('cadmin');
  perform authz_t.check('departments: company admin can delete a department',
    authz_t.rows_hit(format('delete from departments where id = %L', v_dept)) = '1');

  -- ---- organizations -------------------------------------------------
  perform authz_t.become('cadmin');
  perform authz_t.expect_ok('organizations: company admin (no finance row) can create an organization',
    format('insert into organizations (tenant_id, company_code, site_name) values (%L, %L, %L)', v_t1, 'AZ-H1', 'AuthZ Org H1'));
  v_org := authz_t.q(format('select id::text from organizations where tenant_id = %L and company_code = %L', v_t1, 'AZ-H1'))::uuid;
  perform authz_t.check('organizations: company admin can read the list',
    authz_t.rows_hit(format('select 1 from organizations where id = %L', v_org)) = '1');
  perform authz_t.check('organizations: company admin can update an organization',
    authz_t.rows_hit(format('update organizations set site_name = %L where id = %L', 'AuthZ Org H1 renamed', v_org)) = '1');

  -- finance keeps READ (company-code pickers) but no longer writes
  perform authz_t.become('fin');
  perform authz_t.check('organizations: finance team can still read the list',
    authz_t.rows_hit(format('select 1 from organizations where id = %L', v_org)) = '1');
  perform authz_t.expect_blocked('organizations: finance team cannot create an organization',
    format('insert into organizations (tenant_id, company_code, site_name) values (%L, %L, %L)', v_t1, 'AZ-H2', 'AuthZ Org H2'));
  perform authz_t.expect_blocked('organizations: finance team cannot update an organization',
    format('update organizations set site_name = %L where id = %L', 'AuthZ hijack', v_org));
  perform authz_t.expect_blocked('organizations: finance team cannot delete an organization',
    format('delete from organizations where id = %L', v_org));

  -- an hr module admin and a plain member neither read nor write
  foreach k in array array['hradmin', 'plain'] loop
    perform authz_t.become(k);
    perform authz_t.check(format('organizations: %s cannot read the list', k),
      authz_t.rows_hit(format('select 1 from organizations where id = %L', v_org)) = '0');
    perform authz_t.expect_blocked(format('organizations: %s cannot create an organization', k),
      format('insert into organizations (tenant_id, company_code, site_name) values (%L, %L, %L)', v_t1, 'AZ-H3', 'AuthZ Org H3'));
  end loop;

  perform authz_t.become('xadmin');
  perform authz_t.check('organizations: another tenant''s company admin cannot read this tenant''s list',
    authz_t.rows_hit(format('select 1 from organizations where id = %L', v_org)) = '0');
  perform authz_t.attempt(format('insert into organizations (tenant_id, company_code, site_name) values (%L, %L, %L)', v_t1, 'AZ-H4', 'AuthZ Org H4'));
  perform authz_t.check('organizations: another tenant''s company admin cannot create here (nothing lands in this tenant)',
    authz_t.q(format('select count(*)::text from organizations where tenant_id = %L and company_code = %L', v_t1, 'AZ-H4')) = '0');
  perform authz_t.expect_blocked('organizations: another tenant''s company admin cannot update here',
    format('update organizations set site_name = %L where id = %L', 'AuthZ hijack', v_org));

  perform authz_t.check('organizations: the denied attempts changed nothing',
    authz_t.q(format('select site_name from organizations where id = %L', v_org)) = 'AuthZ Org H1 renamed');

  perform authz_t.become('cadmin');
  perform authz_t.check('organizations: company admin can delete an organization',
    authz_t.rows_hit(format('delete from organizations where id = %L', v_org)) = '1');

  -- ---- platform admin: outside View-as, user-level, company-level -------
  perform authz_t.x(format('update impersonation_sessions set ended_at = now() where platform_admin_id = %L and ended_at is null', authz_t.id('padmin')));
  perform authz_t.become('padmin');
  perform authz_t.expect_blocked('departments: platform admin outside View-as cannot write a customer tenant''s departments',
    format('insert into departments (tenant_id, name) values (%L, %L)', v_t1, 'AuthZ H operator no-session'));
  perform authz_t.attempt(format('insert into organizations (tenant_id, company_code, site_name) values (%L, %L, %L)', v_t1, 'AZ-H5', 'AuthZ Org H5'));
  perform authz_t.check('organizations: platform admin outside View-as cannot write a customer tenant''s organizations (nothing lands in this tenant)',
    authz_t.q(format('select count(*)::text from organizations where tenant_id = %L and company_code = %L', v_t1, 'AZ-H5')) = '0');

  perform authz_t.expect_ok('departments: platform admin can start a user-level session on a plain member',
    format('select * from start_impersonation(%L, %L, %L)', v_t1, 'authz H user-level', authz_t.id('plain')));
  perform authz_t.expect_blocked('departments: a user-level session on a plain member gets no company-admin rights',
    format('insert into departments (tenant_id, name) values (%L, %L)', v_t1, 'AuthZ H operator as plain'));
  perform authz_t.x(format('update impersonation_sessions set ended_at = now() where platform_admin_id = %L and ended_at is null', authz_t.id('padmin')));

  perform authz_t.expect_ok('departments: platform admin can start a company-level session',
    format('select * from start_impersonation(%L, %L)', v_t1, 'authz H company-level'));
  perform authz_t.expect_ok('departments: a company-level session may write the company''s departments',
    format('insert into departments (tenant_id, name) values (%L, %L)', v_t1, 'AuthZ H operator dept'));
  perform authz_t.x(format('update impersonation_sessions set ended_at = now() where platform_admin_id = %L and ended_at is null', authz_t.id('padmin')));
end $$;

-- =====================================================================
-- Summary
-- =====================================================================
reset role;

do $$
declare
  v_pass int; v_fail int; v_gap int;
  r record;
  v_msg text := '';
begin
  select count(*) filter (where status = 'PASS'),
         count(*) filter (where status = 'FAIL'),
         count(*) filter (where status = 'GAP')
    into v_pass, v_fail, v_gap
  from authz_t.results;

  raise notice '----------------------------------------------------------------';
  raise notice 'security_authorization: % passed, % failed, % gap notice(s)', v_pass, v_fail, v_gap;

  for r in select name, detail from authz_t.results where status = 'GAP' order by n loop
    raise notice 'GAP: % -- %', r.name, r.detail;
  end loop;

  if v_fail > 0 then
    for r in select name, detail from authz_t.results where status = 'FAIL' order by n loop
      v_msg := v_msg || E'\n - ' || r.name || coalesce(' -- ' || r.detail, '');
    end loop;
    raise exception 'SECURITY AUTHORIZATION FAILURES (% of % checks):%', v_fail, v_pass + v_fail, v_msg;
  end if;

  raise notice 'ALL SECURITY AUTHORIZATION CHECKS PASSED';
end $$;

rollback;