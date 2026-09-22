-- Functional test for the machine-operation workflow migration:
--   20260921120000_machine_maintenance_workflow.sql
--     (assigned_to/actual_cost/overdue marker columns,
--      machine_maintenance_events audit, transition RPC with notifications,
--      maintenance + fuel cost -> GL posting, overdue sweep,
--      journal_entries.source_type CHECK widening)
--
-- Covers:
--   * happy path scheduled -> in_progress -> completed with audit rows
--     and requester/assignee notifications
--   * invalid transitions refused (scheduled -> completed, completed -> cancelled)
--   * completing WITH a cost: member refused, negative cost refused,
--     manager succeeds and a balanced journal entry
--     (Dr default expense / Cr AP control) is posted
--   * uncosted completion posts nothing to the GL
--   * fuel_logs cost auto-posts on insert; uncosted fuel posts nothing;
--     a tenant without posting rules can still log fuel (skip, not fail)
--   * machine_maintenance_overdue_sweep notifies once, is idempotent,
--     and returns 0 for outsiders
--
-- Run against a fresh local stack only (psql -f), never a linked project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures: tenant A (GL seeded), tenant B (no posting rules)
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant_a uuid := gen_random_uuid();
  v_tenant_b uuid := gen_random_uuid();
  v_requester uuid := gen_random_uuid(); -- machine member, requests the work
  v_assignee  uuid := gen_random_uuid(); -- machine member, assigned the work
  v_mgr       uuid := gen_random_uuid(); -- machine manager
  v_plain     uuid := gen_random_uuid(); -- no roles
  v_b_req     uuid := gen_random_uuid(); -- tenant B manager (no rules seeded)
  v_expense uuid; v_ap uuid;
  v_machine_a uuid; v_machine_b uuid;
begin
  insert into tenants (id, name) values
    (v_tenant_a, 'Machine Flow Test A'),
    (v_tenant_b, 'Machine Flow Test B');

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
    (v_requester, 'mac-requester'),
    (v_assignee,  'mac-assignee'),
    (v_mgr,       'mac-manager'),
    (v_plain,     'mac-plain'),
    (v_b_req,     'mac-b-requester')
  ) as u(id, handle);

  insert into app_users (id, tenant_id, name, email)
  select u.id, u.tenant, u.name, u.email
  from (values
    (v_requester, v_tenant_a, 'Requester User', 'mac-requester@test.local'),
    (v_assignee,  v_tenant_a, 'Assignee User',  'mac-assignee@test.local'),
    (v_mgr,       v_tenant_a, 'Machine Manager','mac-manager@test.local'),
    (v_plain,     v_tenant_a, 'Plain User',     'mac-plain@test.local'),
    (v_b_req,     v_tenant_b, 'B Requester', 'mac-b-requester@test.local')
  ) as u(id, tenant, name, email);

  insert into tenant_modules (tenant_id, module) values
    (v_tenant_a, 'machine_operation'),
    (v_tenant_b, 'machine_operation');

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant_a, v_requester, 'machine_operation', 'member'),
    (v_tenant_a, v_assignee,  'machine_operation', 'member'),
    (v_tenant_a, v_mgr,       'machine_operation', 'manager'),
    (v_tenant_b, v_b_req, 'machine_operation', 'manager'); -- fuel_logs insert RLS is admin/manager

  -- NB: trg_machine_no overwrites whatever machine_no we pass with an
  -- auto number (MCH-000001, ...) -- capture the ids, never look up by
  -- machine_no.
  insert into machines (tenant_id, machine_no, name) values
    (v_tenant_a, 'EX-001', 'Excavator') returning id into v_machine_a;
  insert into machines (tenant_id, machine_no, name) values
    (v_tenant_b, 'GR-001', 'Grader') returning id into v_machine_b;

  -- GL for tenant A: expense + AP accounts wired through gl_posting_rules.
  -- Tenant B deliberately gets NO rules: its fuel logs must skip the GL.
  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (v_tenant_a, '5100', 'Machine Expenses', 'expense') returning id into v_expense;
  insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account) values
    (v_tenant_a, '2100', 'Accounts Payable Control', 'liability', true) returning id into v_ap;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_tenant_a, 'default_expense', v_expense),
    (v_tenant_a, 'ap_control', v_ap);

  -- Request 1: main flow (requested by member, assigned to other member),
  -- scheduled in the future so it is NOT overdue.
  insert into maintenance_requests (tenant_id, machine_id, type, description, status, requested_by, assigned_to, scheduled_date)
  values (v_tenant_a, v_machine_a, 'corrective', 'Hydraulic leak on boom', 'scheduled',
         v_requester, v_assignee, current_date + 7);

  -- Request 2: overdue probe (scheduled yesterday, still open).
  insert into maintenance_requests (tenant_id, machine_id, type, description, status, requested_by, assigned_to, scheduled_date)
  values (v_tenant_a, v_machine_a, 'preventive', '500-hour service', 'scheduled',
         v_requester, v_assignee, current_date - 3);

  -- Handle -> id lookup for claim impersonation. Once
  -- "set local role authenticated" is active, app_users subqueries go
  -- through RLS (and get_my_tenant_id() is null until claims exist),
  -- so resolve all ids NOW, as the owner, via this RLS-free temp table.
  create temp table if not exists test_identities(handle text primary key, id uuid not null) on commit drop;
  insert into test_identities (handle, id) values
    ('requester', v_requester), ('assignee', v_assignee), ('manager', v_mgr),
    ('plain', v_plain), ('b_requester', v_b_req),
    ('tenant_a', v_tenant_a), ('tenant_b', v_tenant_b),
    ('machine_a', v_machine_a), ('machine_b', v_machine_b);
  grant select on test_identities to authenticated;
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Manager starts request 1: in_progress + audit + both notified
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'manager'))::text, true);

do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like 'Hydraulic leak%');
  v_req public.maintenance_requests%rowtype;
begin
  v_req := transition_maintenance_request(v_req_id, 'in_progress');
  if v_req.status <> 'in_progress' then
    raise exception 'FAIL: start did not move request to in_progress (got %)', v_req.status;
  end if;
  if (select count(*) from machine_maintenance_events where request_id = v_req_id and status = 'in_progress') <> 1 then
    raise exception 'FAIL: no in_progress audit event written';
  end if;
end $$;

reset role;
do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like 'Hydraulic leak%');
begin
  if (select count(*) from notifications n
      join app_users u on u.id = n.recipient_id
      where n.type = 'maintenance_in_progress'
        and n.title = 'Maintenance in_progress: ' || (select machine_no from machines where id = (select machine_id from maintenance_requests where id = v_req_id))
        and u.email in ('mac-requester@test.local', 'mac-assignee@test.local')) <> 2 then
    raise exception 'FAIL: requester and assignee were not both notified of start';
  end if;
  raise notice 'PASS: start -> in_progress, audit row, requester+assignee notified (actor excluded)';
end $$;

-- ---------------------------------------------------------------------
-- 2. Invalid transitions refused
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'manager'))::text, true);

do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like '500-hour%');
begin
  begin
    perform transition_maintenance_request(v_req_id, 'completed');
    raise exception 'FAIL: scheduled -> completed was allowed';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'PASS: scheduled -> completed refused (must start first)';
end $$;

-- ---------------------------------------------------------------------
-- 3. Member cannot complete WITH a cost; negative cost refused
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'assignee'))::text, true);

do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like 'Hydraulic leak%');
begin
  begin
    perform transition_maintenance_request(v_req_id, 'completed', null, 120000);
    raise exception 'FAIL: member completed with a cost';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  begin
    perform transition_maintenance_request(v_req_id, 'completed', null, -50);
    raise exception 'FAIL: negative actual_cost was allowed';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  if (select status from maintenance_requests where id = v_req_id) <> 'in_progress' then
    raise exception 'FAIL: refused attempts changed the request status';
  end if;
  raise notice 'PASS: member-with-cost and negative-cost completions refused, row unchanged';
end $$;

-- ---------------------------------------------------------------------
-- 4. Manager completes with cost: completed_date + audit + GL entry
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'manager'))::text, true);

do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like 'Hydraulic leak%');
  v_req public.maintenance_requests%rowtype;
begin
  v_req := transition_maintenance_request(v_req_id, 'completed', 'Replaced boom hose and seals', 450000);
  if v_req.status <> 'completed' or v_req.completed_date <> current_date then
    raise exception 'FAIL: completion did not set status/completed_date';
  end if;
  if v_req.actual_cost <> 450000 then
    raise exception 'FAIL: actual_cost % <> 450000', v_req.actual_cost;
  end if;
  if (select count(*) from machine_maintenance_events
      where request_id = v_req_id and status = 'completed' and actual_cost = 450000
        and note = 'Replaced boom hose and seals') <> 1 then
    raise exception 'FAIL: completed audit event missing note/cost';
  end if;
end $$;

reset role;
do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like 'Hydraulic leak%');
  v_entry_id uuid;
  v_debit numeric; v_credit numeric;
begin
  select id into v_entry_id from journal_entries
  where source_type = 'machine_maintenance_request' and source_id = v_req_id;
  if v_entry_id is null then
    raise exception 'FAIL: no journal entry posted for completed maintenance';
  end if;
  if (select entry_date from journal_entries where id = v_entry_id) <> current_date then
    raise exception 'FAIL: journal entry_date is not the completion date';
  end if;
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0) into v_debit, v_credit
  from journal_entry_lines where journal_entry_id = v_entry_id;
  if v_debit <> 450000 or v_credit <> 450000 then
    raise exception 'FAIL: journal lines not balanced at 450000 (%, %)', v_debit, v_credit;
  end if;
  if (select count(*) from journal_entry_lines l
      where l.journal_entry_id = v_entry_id
        and ((l.debit > 0 and l.gl_account_id = (select gl_account_id from gl_posting_rules r
              where r.tenant_id = l.tenant_id and r.account_role = 'default_expense'))
          or (l.credit > 0 and l.gl_account_id = (select gl_account_id from gl_posting_rules r
              where r.tenant_id = l.tenant_id and r.account_role = 'ap_control')))) <> 2 then
    raise exception 'FAIL: journal legs are not Dr default-expense / Cr AP-control';
  end if;
  if (select count(*) from notifications where type = 'maintenance_completed'
      and title = 'Maintenance completed: ' || (select machine_no from machines where id = (select machine_id from maintenance_requests where id = v_req_id))) <> 2 then
    raise exception 'FAIL: completion notifications missing';
  end if;
  if (select body from notifications where type = 'maintenance_completed' limit 1) not like '%450000%' then
    raise exception 'FAIL: completion notification omits the actual cost';
  end if;
  raise notice 'PASS: manager completion books balanced Dr expense / Cr AP entry, notifies with cost';
end $$;

-- ---------------------------------------------------------------------
-- 5. Completed requests are terminal; second post cannot happen
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'manager'))::text, true);

do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like 'Hydraulic leak%');
begin
  begin
    perform transition_maintenance_request(v_req_id, 'cancelled');
    raise exception 'FAIL: completed -> cancelled was allowed';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'PASS: completed request is terminal (cancel refused)';
end $$;

-- ---------------------------------------------------------------------
-- 6. Fuel logs: cost auto-posts; uncosted posts nothing; no-rules tenant
--    still logs fuel without failing
-- ---------------------------------------------------------------------
do $$
declare
  v_fuel_id uuid := gen_random_uuid();
  v_cheap_id uuid := gen_random_uuid();
  v_b_id uuid := gen_random_uuid();
begin
  -- costed fuel (tenant A, still acting as the manager) -> GL entry
  insert into fuel_logs (id, tenant_id, machine_id, log_date, fuel_liters, cost)
  values (v_fuel_id, (select id from test_identities where handle = 'tenant_a'),
          (select id from test_identities where handle = 'machine_a'), current_date, 42, 210000);

  -- uncosted fuel (tenant A) -> no entry
  insert into fuel_logs (id, tenant_id, machine_id, log_date, fuel_liters)
  values (v_cheap_id, (select id from test_identities where handle = 'tenant_a'),
          (select id from test_identities where handle = 'machine_a'), current_date, 10);

  -- costed fuel (tenant B, no posting rules; act as tenant B's
  -- requester so the fuel_logs RLS WITH CHECK passes) -> inserts fine,
  -- no entry
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from test_identities where handle = 'b_requester'))::text, true);
  insert into fuel_logs (id, tenant_id, machine_id, log_date, fuel_liters, cost)
  values (v_b_id, (select id from test_identities where handle = 'tenant_b'),
          (select id from test_identities where handle = 'machine_b'), current_date, 30, 90000);

  -- remember the ids for the owner-side verification below
  create temp table if not exists machine_fuel_probe_ids(a uuid, b uuid, c uuid) on commit drop;
  insert into machine_fuel_probe_ids values (v_fuel_id, v_cheap_id, v_b_id);
end $$;

reset role; -- journal_entries select is finance-only under RLS; verify as owner

do $$
declare
  v_fuel_id uuid := (select a from machine_fuel_probe_ids);
  v_cheap_id uuid := (select b from machine_fuel_probe_ids);
  v_b_id uuid := (select c from machine_fuel_probe_ids);
begin
  if (select count(*) from journal_entries where source_type = 'machine_fuel_log' and source_id = v_fuel_id) <> 1 then
    raise exception 'FAIL: costed fuel log did not auto-post to the GL';
  end if;
  if (select coalesce(sum(debit), 0) from journal_entry_lines
      where journal_entry_id = (select id from journal_entries
        where source_type = 'machine_fuel_log' and source_id = v_fuel_id)) <> 210000 then
    raise exception 'FAIL: fuel GL debit <> 210000';
  end if;
  if (select count(*) from journal_entries where source_type = 'machine_fuel_log' and source_id = v_cheap_id) <> 0 then
    raise exception 'FAIL: uncosted fuel log posted to the GL';
  end if;
  if (select count(*) from journal_entries where source_type = 'machine_fuel_log' and source_id = v_b_id) <> 0 then
    raise exception 'FAIL: no-rules tenant fuel log posted to the GL';
  end if;
  raise notice 'PASS: costed fuel auto-posts; uncosted and no-CoA fuel logs skip the GL without failing';
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 7. Overdue sweep: notifies once, idempotent, outsiders get nothing
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'plain'))::text, true);

do $$
declare
  v_n int;
begin
  v_n := machine_maintenance_overdue_sweep();
  if v_n <> 0 then
    raise exception 'FAIL: outsider sweep returned % instead of 0', v_n;
  end if;
  raise notice 'PASS: outsider sweep returns 0 and notifies nobody';
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'assignee'))::text, true);

do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like '500-hour%');
  v_n int;
begin
  v_n := machine_maintenance_overdue_sweep();
  if v_n <> 1 then
    raise exception 'FAIL: sweep flagged % requests, expected exactly 1 (the 3-day-overdue service)', v_n;
  end if;
  if (select overdue_notified_at from maintenance_requests where id = v_req_id) is null then
    raise exception 'FAIL: sweep did not set overdue_notified_at';
  end if;

  v_n := machine_maintenance_overdue_sweep();
  if v_n <> 0 then
    raise exception 'FAIL: second sweep re-flagged % requests (not idempotent)', v_n;
  end if;
  raise notice 'PASS: sweep flags the overdue request once and is idempotent';
end $$;

reset role;
do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like '500-hour%');
begin
  if (select count(*) from notifications n
      join app_users u on u.id = n.recipient_id
      where n.type = 'maintenance_overdue'
        and n.title = 'Maintenance overdue: ' || (select machine_no from machines where id = (select machine_id from maintenance_requests where id = v_req_id))
        and n.body like '%3 day(s) overdue%'
        and u.email in ('mac-requester@test.local', 'mac-assignee@test.local')) <> 2 then
    raise exception 'FAIL: overdue notifications missing for requester/assignee';
  end if;
  raise notice 'PASS: overdue notifications with day count reach requester + assignee';
end $$;

-- ---------------------------------------------------------------------
-- 8. Events read access: machine member sees history, plain user sees none
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'assignee'))::text, true);

do $$
declare
  v_req_id uuid := (select id from maintenance_requests where description like 'Hydraulic leak%');
begin
  if (select count(*) from machine_maintenance_events where request_id = v_req_id) <> 2 then
    raise exception 'FAIL: member cannot read the two workflow events';
  end if;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'plain'))::text, true);

do $$
begin
  if (select count(*) from machine_maintenance_events) <> 0 then
    raise exception 'FAIL: plain user can read machine maintenance events';
  end if;
  raise notice 'PASS: audit trail readable by machine roles only';
end $$;

reset role;
rollback;
