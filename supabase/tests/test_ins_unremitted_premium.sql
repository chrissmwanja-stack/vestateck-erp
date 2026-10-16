-- Phase B slice 1: premium received and not yet remitted (ins_unremitted_premium_report)
-- and the remittance deadline (ins_remittance_due_date).
--
-- Covers: no deadline without an approved rules value (no default); working days skip
-- weekends; the report flags overdue, due-today and within-deadline receipts; a policy
-- with no cash is not listed; access is limited to insurance users; tenant isolation.
--
-- Run against a fresh local stack only. One transaction that ROLLBACKs.

\set ON_ERROR_STOP on

begin;

create function pg_temp.assert(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAIL: %', p_label;
  end if;
end $$;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text) returns void language plpgsql as $$
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

create function pg_temp.jwt(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  admin uuid := gen_random_uuid();     -- company admin: proposes the rule value
  checker uuid := gen_random_uuid();   -- finance, assigned to the remittance key: approves it
  maker uuid := gen_random_uuid();     -- finance: prepares the premium receipt
  checker2 uuid := gen_random_uuid();  -- finance: approves the premium receipt
  mgr uuid := gen_random_uuid();       -- insurance manager
  outsider uuid := gen_random_uuid();  -- no insurance role
  other_mgr uuid := gen_random_uuid(); -- insurance manager in another company
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  trust uuid; line_id uuid; insurer uuid; c ins_clients%rowtype;
  p ins_policies%rowtype; p2 ins_policies%rowtype; q ins_policy_cash_requests%rowtype;
  rule_id uuid; v_n integer; v_row record; v_d date;
begin
  insert into tenants(id,name) values(ta,'Unremitted test A'),(tb,'Unremitted test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'unrem-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[admin,checker,maker,checker2,mgr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email,is_company_admin)
    select u, case when u=other_mgr then tb else ta end, 'Unremitted actor', 'unrem-'||u||'@test.local', u=admin
    from unnest(array[admin,checker,maker,checker2,mgr,outsider,other_mgr]) u;
  insert into finance_team_members(tenant_id,user_id,role) values
    (ta,checker,'finance'),(ta,maker,'finance'),(ta,checker2,'finance');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values(ta,mgr,'insurance','manager'),(tb,other_mgr,'insurance','manager');

  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1000','Operating','asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1020','Client money','asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1100','AR','asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2010','Insurer payable','liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2020','Unearned commission','liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4000','Commission income','revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values
    (ta,'bank',bank_gl),(ta,'client_money_bank',trust_gl),(ta,'ar_control',ar_gl),
    (ta,'insurer_payable',pay_gl),(ta,'unearned_commission',unearned_gl),(ta,'commission_income',income_gl);
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id)
    values(ta,'UNREM-TRUST','client_money','UGX',trust_gl) returning id into trust;

  -- Policies, bound as the insurance manager
  perform pg_temp.jwt(mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MOTOR','Motor') returning id into line_id;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c := ins_register_client('Unremitted client','corporate',null,null,null,'low');
  p := ins_create_policy(c.id,insurer,line_id,current_date-60,current_date+305,50000,'UGX',1000,10,null,null);
  p := ins_bind_policy(p.id);
  p2 := ins_create_policy(c.id,insurer,line_id,current_date-60,current_date+305,30000,'UGX',600,10,null,null);
  p2 := ins_bind_policy(p2.id);
  reset role;

  -- A premium receipt dated Thursday 8 October 2026, prepared and approved by two people
  perform pg_temp.jwt(maker); set local role authenticated;
  q := ins_submit_policy_cash_request(p.id,'receipt',trust,400,date '2026-10-08',gen_random_uuid(),'PREMIUM-R1','partial client collection');
  reset role;
  perform pg_temp.jwt(checker2); set local role authenticated;
  q := ins_decide_policy_cash_request(q.id,'approve');
  reset role;
  perform pg_temp.assert(q.status = 'posted', 'the receipt is posted before the deadline test');

  -------------------------------------------------------------------
  -- 1. No approved rule: no deadline, and no default is assumed
  -------------------------------------------------------------------
  v_d := ins_remittance_due_date(ta, date '2026-10-08');
  perform pg_temp.assert(v_d is null, 'no approved rule gives no deadline');
  perform pg_temp.jwt(mgr); set local role authenticated;
  select status, deadline_date into v_row from ins_unremitted_premium_report(date '2026-10-16') r where r.policy_id = p.id;
  reset role;
  perform pg_temp.assert(v_row.status = 'deadline_not_set' and v_row.deadline_date is null,
    'report says deadline not set when no rule is approved');
  raise notice 'PASS: no approved rule means no deadline, and the report says so';

  -------------------------------------------------------------------
  -- 2. Approve the rule (company admin proposes, assigned finance user approves)
  -------------------------------------------------------------------
  perform pg_temp.jwt(admin); set local role authenticated;
  insert into regulatory_parameters(tenant_id,parameter_key,value_num,effective_from,source_ref)
    values(ta,'remittance.deadline_working_days',3,date '2017-01-01','UNVERIFIED: test rule') returning id into rule_id;
  reset role;
  insert into regulatory_approval_assignments(tenant_id,user_id,scope,scope_value,responsibility,effective_from,assigned_by)
    values(ta,checker,'key','remittance.deadline_working_days','Insurer remittance deadline (test)',date '2017-01-01',admin);
  perform pg_temp.jwt(checker); set local role authenticated;
  perform reg_approve_parameter(rule_id);
  reset role;

  -------------------------------------------------------------------
  -- 3. Working-day arithmetic, including the weekend
  -------------------------------------------------------------------
  -- Thu 8 Oct + 3 working days = Tue 13 Oct (Fri 9, Mon 12, Tue 13)
  perform pg_temp.assert(ins_remittance_due_date(ta, date '2026-10-08') = date '2026-10-13', 'Thursday receipt, 3 working days');
  -- Thu 15 Oct + 3 working days = Tue 20 Oct (Fri 16, Mon 19, Tue 20)
  perform pg_temp.assert(ins_remittance_due_date(ta, date '2026-10-15') = date '2026-10-20', 'Thursday 15 Oct, 3 working days');
  -- Fri 16 Oct + 3 working days = Wed 21 Oct, skipping the weekend (Mon 19, Tue 20, Wed 21)
  perform pg_temp.assert(ins_remittance_due_date(ta, date '2026-10-16') = date '2026-10-21', 'Friday receipt skips the weekend');
  perform pg_temp.assert(ins_remittance_due_date(ta, null) is null, 'no receipt date gives no deadline');
  raise notice 'PASS: deadline is N working days after receipt, skipping weekends';

  -------------------------------------------------------------------
  -- 4. The report flags the receipt by its deadline
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  select status, deadline_date, receipt_date, unremitted_amount into v_row
    from ins_unremitted_premium_report(date '2026-10-16') r where r.policy_id = p.id;
  perform pg_temp.assert(v_row.status = 'overdue' and v_row.deadline_date = date '2026-10-13' and v_row.receipt_date = date '2026-10-08',
    'receipt past its deadline is overdue');
  perform pg_temp.assert(v_row.unremitted_amount > 0, 'unremitted amount is the cash held for insurers');
  select status into v_row from ins_unremitted_premium_report(date '2026-10-13') r where r.policy_id = p.id;
  perform pg_temp.assert(v_row.status = 'due_today', 'deadline day is due today');
  select status into v_row from ins_unremitted_premium_report(date '2026-10-12') r where r.policy_id = p.id;
  perform pg_temp.assert(v_row.status = 'within_deadline', 'before the deadline is within deadline');
  -- The policy with no cash is never listed
  select count(*) into v_n from ins_unremitted_premium_report(date '2026-10-16') r where r.policy_id = p2.id;
  perform pg_temp.assert(v_n = 0, 'a policy with no cash held is not listed');
  reset role;
  raise notice 'PASS: overdue, due-today and within-deadline statuses; a policy with no cash is not listed';

  -------------------------------------------------------------------
  -- 5. Access and tenant isolation
  -------------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_unremitted_premium_report(date ''2026-10-16'')', 'INS_FORBIDDEN', 'outsider reads the report');
  reset role;

  perform pg_temp.jwt(other_mgr); set local role authenticated;
  select count(*) into v_n from ins_unremitted_premium_report(date '2026-10-16');
  reset role;
  perform pg_temp.assert(v_n = 0, 'another company sees none of these receipts');
  raise notice 'PASS: outsiders are refused; another company sees no rows';

  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error('select ins_remittance_due_date(' || quote_literal(ta) || ', date ''2026-10-08'')', 'permission denied', 'client calls the deadline helper directly');
  reset role;

  raise notice 'ALL PASS: unremitted premium report and remittance deadline';
end $$;

rollback;
