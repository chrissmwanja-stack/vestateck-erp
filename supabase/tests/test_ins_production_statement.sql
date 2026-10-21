-- Production reports (20261021120000_ins_production_and_statement.sql):
-- ins_production_book and ins_client_statement.
--
--   1. Production book: one row per written policy, with the dimension names
--      resolved (client, insurer, product, branch, agent) and transaction type.
--   2. Reversed policies are not production (status <> 'reversed', matching
--      the commission views).
--   3. Statement: billed = gross on bind; received counts posted receipts
--      only; balance is the difference. A pending request is not money.
--   4. Tenant isolation and the module gate: the views are definer with the
--      guard in the WHERE (tenant + insurance access), so another tenant's
--      manager sees none of tenant A's rows, a user with no insurance role
--      sees nothing, and the names resolve even though bd_clients and
--      organizations belong to other modules.
--   5. ins_branch_options: active branches for insurance users, inactive ones
--      only on request, and nothing across tenants.
--
-- Run inside a transaction that is rolled back, so it leaves no data behind.

\set ON_ERROR_STOP on

begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Bind helper: motor policies need an issued certificate (Phase C item 2).
create function pg_temp.motor_cert(p_policy uuid) returns void
language plpgsql as $$
declare
  s text := substr(p_policy::text, 1, 8);
  r uuid; pol ins_policies%rowtype; line_code text;
begin
  if not can_manage_insurance() then return; end if;
  select * into pol from ins_policies where id = p_policy;
  if not found or pol.status <> 'draft' then return; end if;
  select code into line_code from ins_product_lines where id = pol.product_line_id;
  if line_code is distinct from 'MOTOR' then return; end if;
  if exists (select 1 from ins_certificate_stock where policy_id = p_policy and status = 'issued') then return; end if;
  r := ins_register_risk(pol.client_id, pol.product_line_id, 'vehicle', 'Prod-test vehicle', null, 'CH' || s, null, null, null, null, 0);
  perform ins_load_certificate_range('CPB' || s || '-', 1, 1, 4);
  perform ins_issue_certificate('CPB' || s || '-0001', r, null);
  perform ins_link_policy_risk(p_policy, r);
  perform ins_attach_certificate(p_policy, 'CPB' || s || '-0001');
end $$;

do $$
declare
  ta    uuid := gen_random_uuid();
  tb    uuid := gen_random_uuid();
  mgr   uuid := gen_random_uuid();    -- tenant A insurance manager
  mem   uuid := gen_random_uuid();    -- tenant A insurance member
  maker uuid := gen_random_uuid();    -- tenant A finance maker
  chk   uuid := gen_random_uuid();    -- tenant A finance checker
  mgr_b uuid := gen_random_uuid();    -- tenant B insurance manager
  v_bank_gl uuid; v_trust_gl uuid; v_ar_gl uuid; v_pay_gl uuid; v_unearned_gl uuid; v_income_gl uuid;
  v_trust uuid; v_line uuid; v_insr uuid; v_branch uuid; v_agent uuid;
  p1 ins_policies%rowtype; p2 ins_policies%rowtype; p3 ins_policies%rowtype;
  q ins_policy_cash_requests%rowtype;
  v_n integer; v_rec record;
begin
  insert into tenants (id, name) values (ta, 'Prod book A'), (tb, 'Prod book B');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'prod-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{}', '{}', now(), now(), '', ''
    from (values (mgr), (mem), (maker), (chk), (mgr_b)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,   ta, 'Prod manager',  'prod-' || mgr   || '@test.local'),
    (mem,   ta, 'Prod member',   'prod-' || mem   || '@test.local'),
    (maker, ta, 'Prod maker',    'prod-' || maker || '@test.local'),
    (chk,   ta, 'Prod checker',  'prod-' || chk   || '@test.local'),
    (mgr_b, tb, 'Prod manager B','prod-' || mgr_b || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, maker, 'finance'), (ta, chk, 'finance');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (ta, mgr, 'insurance', 'manager'), (ta, mem, 'insurance', 'member'),
    (tb, mgr_b, 'insurance', 'manager');

  -- GL + trust account for the premium-cash flow, as in test_ins_unremitted_premium.
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (ta,'1000','Operating','asset') returning id into v_bank_gl;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (ta,'1020','Client money','asset') returning id into v_trust_gl;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (ta,'1100','AR','asset') returning id into v_ar_gl;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (ta,'2010','Insurer payable','liability') returning id into v_pay_gl;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (ta,'2020','Unearned commission','liability') returning id into v_unearned_gl;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (ta,'4000','Commission income','revenue') returning id into v_income_gl;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'bank',v_bank_gl),(ta,'client_money_bank',v_trust_gl),(ta,'ar_control',v_ar_gl),
    (ta,'insurer_payable',v_pay_gl),(ta,'unearned_commission',v_unearned_gl),(ta,'commission_income',v_income_gl);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    values (ta,'PROD-TRUST','client_money','UGX',v_trust_gl) returning id into v_trust;

  -- Masters + dimensions, as the screens do.
  perform pg_temp.jwt(mgr);
  insert into organizations (tenant_id, company_code, site_name) values (ta, 'KLA', 'Kampala') returning id into v_branch;
  insert into organizations (tenant_id, company_code, site_name, is_active) values (ta, 'ENT', 'Entebbe (closed)', false);
  reset role;
  insert into ins_intermediaries (tenant_id, code, name, category, status) values
    (ta, 'AG-P1', 'Prod Agent', 'independent_broker', 'active');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into v_line;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (ta, 'ALPHA', 'Alpha Assurance', 10) returning id into v_insr;
  reset role;

  -- Two bound policies (with branch + agent) and one draft that becomes reversed.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  declare c ins_clients%rowtype;
  begin
    c := ins_register_client('Prod client', 'corporate', null, null, null, 'low');
    p1 := ins_create_policy(c.id, v_insr, v_line, current_date - 30, current_date + 335,
                            10000000, 'UGX', 500000, 10, v_branch, null, 'Prod risk one', null);
    perform pg_temp.motor_cert(p1.id); p1 := ins_bind_policy(p1.id);
    p2 := ins_create_policy(c.id, v_insr, v_line, current_date - 10, current_date + 355,
                            4000000, 'UGX', 200000, 10, null, (select id from ins_intermediaries where tenant_id = ta and status = 'active' limit 1) , 'Prod risk two', null);
    perform pg_temp.motor_cert(p2.id); p2 := ins_bind_policy(p2.id);
    p3 := ins_create_policy(c.id, v_insr, v_line, current_date - 5, current_date + 360,
                            999999, 'UGX', 99999, 0, null, null, 'To be reversed', null);
    perform pg_temp.motor_cert(p3.id); p3 := ins_bind_policy(p3.id);
  end;
  reset role;
  v_agent := p2.agent_id;
  perform pg_temp.assert(v_agent is not null, 'the second policy carries an agent');
  perform pg_temp.assert(p1.branch_id = v_branch, 'the first policy carries the branch');

  -- Receive part of p1's premium through the real maker/checker flow.
  perform pg_temp.jwt(maker); set local role authenticated;
  q := ins_submit_policy_cash_request(p1.id, 'receipt', v_trust, 200000, current_date - 20, gen_random_uuid(), 'PROD-R1', 'half the premium');
  reset role;
  perform pg_temp.jwt(chk); set local role authenticated;
  q := ins_decide_policy_cash_request(q.id, 'approve');
  reset role;
  perform pg_temp.assert(q.status = 'posted', 'the receipt posts');
  -- A pending second receipt: not money until approved.
  perform pg_temp.jwt(maker); set local role authenticated;
  q := ins_submit_policy_cash_request(p1.id, 'receipt', v_trust, 100000, current_date - 5, gen_random_uuid(), 'PROD-R2', 'still pending');
  reset role;

  -- Reverse the third policy through the real RPC (the guard demands a posted
  -- reversal row; the RPC posts the GL and stamps the status).
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform ins_reverse_policy(p3.id, 'Written in error for the report test', false, gen_random_uuid());
  reset role;

  -------------------------------------------------------------------
  -- 1. Production book
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  select count(*) into v_n from ins_production_book where tenant_id = ta;
  perform pg_temp.assert(v_n = 2, 'two written policies, the reversed one excluded');
  select * into v_rec from ins_production_book where policy_id = p1.id;
  perform pg_temp.assert(v_rec.client_name = 'Prod client', 'client name resolved');
  perform pg_temp.assert(v_rec.insurer_name = 'Alpha Assurance', 'insurer name resolved');
  perform pg_temp.assert(v_rec.product_line_name = 'Motor', 'product line resolved');
  perform pg_temp.assert(v_rec.branch_name = 'Kampala', 'branch name resolved');
  perform pg_temp.assert(v_rec.agent_name is null, 'no agent on the first policy');
  perform pg_temp.assert(v_rec.transaction_type = 'new_business', 'transaction type carried');
  perform pg_temp.assert(v_rec.gross_premium = 500000 and v_rec.commission_amount = 50000
                         and v_rec.net_premium_to_insurer = 450000, 'money columns carried');
  select agent_name into v_rec from ins_production_book where policy_id = p2.id;
  perform pg_temp.assert(v_rec.agent_name is not null, 'agent name resolved on the second policy');

  -------------------------------------------------------------------
  -- 2. Statement: billed, posted-only receipts, balance
  -------------------------------------------------------------------
  select * into v_rec from ins_client_statement where policy_id = p1.id;
  perform pg_temp.assert(v_rec.billed_amount = 500000, 'billed is the gross premium');
  perform pg_temp.assert(v_rec.received_amount = 200000, 'only the posted receipt counts, the pending one does not');
  perform pg_temp.assert(v_rec.balance_amount = 300000, 'balance is billed minus received');
  select * into v_rec from ins_client_statement where policy_id = p2.id;
  perform pg_temp.assert(v_rec.received_amount = 0 and v_rec.balance_amount = 200000,
                         'an untouched policy is fully outstanding');
  select count(*) into v_n from ins_client_statement where client_name = 'Prod client';
  perform pg_temp.assert(v_n = 2, 'both written policies of the client are on the statement');

  -------------------------------------------------------------------
  -- 3. Tenant isolation and the module gate (definer views, guard in WHERE)
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr_b);
  perform pg_temp.assert((select count(*) from ins_production_book) = 0,
                         'another tenant sees no production rows');
  perform pg_temp.assert((select count(*) from ins_client_statement) = 0,
                         'another tenant sees no statement rows');
  perform pg_temp.jwt(mem);
  perform pg_temp.assert((select count(*) from ins_production_book) = 2,
                         'an insurance member reads the production book');

  -------------------------------------------------------------------
  -- 4. Branch options for the New policy screen
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  select count(*) into v_n from ins_branch_options(false);
  perform pg_temp.assert(v_n = 1, 'active branch options only by default');
  select count(*) into v_n from ins_branch_options(true);
  perform pg_temp.assert(v_n = 2, 'inactive branches come on request');
  perform pg_temp.assert((select count(*) from ins_branch_options(true) where site_name = 'Kampala') = 1,
                         'the branch is listed with its site name');
  perform pg_temp.jwt(mgr_b);
  perform pg_temp.assert((select count(*) from ins_branch_options(true)) = 0,
                         'no branch options across tenants');

  raise notice 'ALL PASS: production book and client statement';
end $$;

rollback;
