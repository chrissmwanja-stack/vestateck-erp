-- Insurance reports, batch 1 (20261121090000): production, premium collected,
-- outstanding premium.
--
-- The point of this file is the tie-out. Every report total is compared with the
-- AR control account in the ledger, because the reports are only worth having if
-- they cannot drift from it (see 20261117260000 for the drift this guards).
--
-- Covers: access (no role, other company); production netted for a posted
-- cancellation; grouping and input validation; premium collected from an approved
-- receipt; outstanding premium as at a date, after a receipt, after a cancellation
-- credit, and after the receipt is voided; each total equals the ledger.
--
-- NOT covered here (implemented, but no scenario yet): endorsements and E4
-- endorsement cancellation in production, policy reversal, the "voided after the
-- as-at date still counts" branch (needs back-dated documents), imported policies.
--
-- Run against a fresh local stack only. One transaction that ROLLBACKs.

\set ON_ERROR_STOP on

begin;

create function pg_temp.approve_and_bind(p_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.ins_policies;
  v_tenant uuid;
  v_claims text := current_setting('request.jwt.claims', true);
  v_appr uuid;
begin
  select tenant_id into v_tenant from public.ins_policies where id = p_id;
  v_appr := ('a9900000-0000-4000-8000-' || substr(replace(v_tenant::text, '-', ''), 1, 12))::uuid;
  perform public.ins_submit_policy_for_approval(p_id);
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (v_appr, 'approver-' || v_appr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
    on conflict (id) do nothing;
  insert into public.app_users(id, tenant_id, name, email)
    values (v_appr, v_tenant, 'Test policy approver', 'approver-' || v_appr || '@test.local')
    on conflict (id) do nothing;
  insert into public.staff_roles(tenant_id, user_id, module, role)
    select v_tenant, v_appr, 'insurance', 'manager'
    where not exists (select 1 from public.staff_roles
                      where tenant_id = v_tenant and user_id = v_appr and module = 'insurance');
  perform set_config('request.jwt.claims', json_build_object('sub', v_appr, 'role', 'authenticated')::text, true);
  perform public.ins_decide_policy(p_id, 'approved');
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  p := public.ins_bind_policy(p_id);
  return p;
end $$;

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

-- AR control balance, counting a voided entry and its reversal together so a
-- void nets to zero instead of double counting.
create function pg_temp.ar_balance(p_gl uuid) returns numeric language sql as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.journal_entry_lines l
   where l.gl_account_id = p_gl;
$$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  maker uuid := gen_random_uuid(); checker uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid(); outsider uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  clearing uuid; ap_gl uuid; trust uuid; line_id uuid; line2 uuid; insurer uuid;
  c ins_clients%rowtype; p1 ins_policies%rowtype; p2 ins_policies%rowtype;
  q ins_policy_cash_requests%rowtype; cx ins_policy_cancellations%rowtype;
  r record; n integer; v_sum numeric; terms jsonb;
begin
  insert into tenants(id,name) values(ta,'Reports test A'),(tb,'Reports test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'rep-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[maker,checker,mgr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u, case when u=other_mgr then tb else ta end, 'Reports actor', 'rep-'||u||'@test.local'
    from unnest(array[maker,checker,mgr,outsider,other_mgr]) u;
  insert into finance_team_members(tenant_id,user_id,role) values (ta,maker,'finance'),(ta,checker,'finance');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role)
    values(ta,mgr,'insurance','manager'),(tb,other_mgr,'insurance','manager');

  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1000','Operating','asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1020','Client money','asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1100','AR','asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2010','Insurer payable','liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2020','Unearned commission','liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4000','Commission income','revenue') returning id into income_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1199','Cancellation clearing','asset') returning id into clearing;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2090','Refund/AP control','liability') returning id into ap_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values
    (ta,'bank',bank_gl),(ta,'client_money_bank',trust_gl),(ta,'ar_control',ar_gl),
    (ta,'insurer_payable',pay_gl),(ta,'unearned_commission',unearned_gl),(ta,'commission_income',income_gl),
    (ta,'ap_control',ap_gl);
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id)
    values(ta,'REP-TRUST','client_money','UGX',trust_gl) returning id into trust;

  -- Two policies on different product lines, so grouping has something to split.
  perform pg_temp.jwt(mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_id;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MARINE','Marine') returning id into line2;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c := ins_register_client('Reports client','corporate',null,null,null,'low');
  p1 := ins_create_policy(c.id,insurer,line_id,public.ins_local_today(),public.ins_local_today()+365,50000,'UGX',1000,10,null,null);
  p1 := pg_temp.approve_and_bind(p1.id);
  p2 := ins_create_policy(c.id,insurer,line2,public.ins_local_today(),public.ins_local_today()+365,30000,'UGX',600,10,null,null);
  p2 := pg_temp.approve_and_bind(p2.id);
  reset role;

  -- ---------------------------------------------------------------
  -- Access
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_production(public.ins_local_today(),public.ins_local_today())','INS_FORBIDDEN','production needs insurance access');
  perform pg_temp.expect_error('select * from ins_report_premium_collected(public.ins_local_today(),public.ins_local_today())','INS_FORBIDDEN','collected needs insurance access');
  perform pg_temp.expect_error('select * from ins_report_outstanding_premium(public.ins_local_today())','INS_FORBIDDEN','outstanding needs insurance access');
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_report_production(public.ins_local_today(),public.ins_local_today()))=0,'another company sees none of this production');
  perform pg_temp.assert((select count(*) from ins_report_outstanding_premium(public.ins_local_today()))=0,'another company sees none of these debtors');
  reset role;
  set local role anon;
  perform pg_temp.expect_error('select * from ins_report_production(public.ins_local_today(),public.ins_local_today())','permission denied','anonymous cannot run reports');
  reset role;

  -- ---------------------------------------------------------------
  -- Production: bind only
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=2 and sum(new_business)=1600 and sum(net_written)=1600 and sum(policy_count)=2
                            from ins_report_production(public.ins_local_today(),public.ins_local_today(),'product_line')),
    'two product lines, 1,600 written, two policies');
  perform pg_temp.assert((select count(*)=1 and sum(net_written)=1600 and sum(policy_count)=2 from ins_report_production(public.ins_local_today(),public.ins_local_today(),'client')),
    'grouped by client: one row');
  perform pg_temp.assert((select count(*)=1 and min(group_key)=to_char(public.ins_local_today(),'YYYY-MM') from ins_report_production(public.ins_local_today(),public.ins_local_today(),'month')),
    'grouped by month');
  perform pg_temp.assert((select count(*)=0 from ins_report_production(public.ins_local_today()+1,public.ins_local_today()+2)),'nothing written outside the period');
  perform pg_temp.expect_error('select * from ins_report_production(public.ins_local_today(),public.ins_local_today(),''insurer'')','INS_REPORT_INPUT','insurer grouping is not offered yet');
  perform pg_temp.expect_error('select * from ins_report_production(public.ins_local_today()+1,public.ins_local_today())','INS_REPORT_INPUT','period must run forwards');
  reset role;

  -- ---------------------------------------------------------------
  -- Outstanding premium before any cash: ties to the ledger
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  select count(*), coalesce(sum(outstanding),0) into n, v_sum from ins_report_outstanding_premium(public.ins_local_today());
  reset role;
  perform pg_temp.assert(n=2 and v_sum=1600,'before cash: two debtors, 1,600 outstanding');
  perform pg_temp.assert(v_sum = pg_temp.ar_balance(ar_gl),'outstanding premium equals the AR control balance');
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_outstanding_premium(public.ins_local_today()-1)),'as at the day before binding nothing was billed');
  perform pg_temp.assert((select bool_and(age_bucket='current' and days_overdue=0) from ins_report_outstanding_premium(public.ins_local_today())),'a fresh invoice is current');
  reset role;

  -- ---------------------------------------------------------------
  -- Premium collected: an approved receipt
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(maker); set local role authenticated;
  q := ins_submit_policy_cash_request(p1.id,'receipt',trust,400,public.ins_local_today(),gen_random_uuid(),'REP-R1','partial client collection');
  reset role;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_premium_collected(public.ins_local_today(),public.ins_local_today())),'a pending receipt is not collected');
  reset role;
  perform pg_temp.jwt(checker); set local role authenticated;
  q := ins_decide_policy_cash_request(q.id,'approve',null);
  reset role;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=1 and sum(collected)=400 and sum(receipt_count)=1 from ins_report_premium_collected(public.ins_local_today(),public.ins_local_today(),'month')),
    'an approved receipt is collected: 400, one receipt');
  perform pg_temp.assert((select count(*)=1 and sum(collected)=400 from ins_report_premium_collected(public.ins_local_today(),public.ins_local_today(),'product_line')),
    'collected by product line: only the line that was paid');
  perform pg_temp.assert((select count(*)=0 from ins_report_premium_collected(public.ins_local_today()+1,public.ins_local_today()+2)),'nothing collected outside the period');
  perform pg_temp.assert((select received_amount=400 from ins_client_statement where policy_id=p1.id),'collected agrees with the client statement');
  select count(*), coalesce(sum(outstanding),0) into n, v_sum from ins_report_outstanding_premium(public.ins_local_today());
  reset role;
  perform pg_temp.assert(n=2 and v_sum=1200,'after the receipt: 1,200 outstanding');
  perform pg_temp.assert(v_sum = pg_temp.ar_balance(ar_gl),'outstanding still equals the AR control balance after a receipt');

  -- ---------------------------------------------------------------
  -- A posted cancellation: production nets it, outstanding takes the credit
  -- ---------------------------------------------------------------
  terms := jsonb_build_array(jsonb_build_object('insurer_id',insurer,'terms',
    jsonb_build_object('method','manual_review','contract_reference','Alpha agreed cancellation','manual_return_premium','200')));
  perform pg_temp.jwt(mgr); set local role authenticated;
  cx := ins_submit_policy_cancellation(p2.id,public.ins_local_today(),terms,'[]'::jsonb,'Insurer-approved cancellation',gen_random_uuid());
  perform pg_temp.jwt(maker);
  cx := ins_prepare_policy_cancellation(cx.id,clearing);
  perform pg_temp.jwt(checker);
  cx := ins_decide_policy_cancellation(cx.id,'approve','Reviewed insurer contract terms',true);
  reset role;
  perform pg_temp.assert(cx.status='posted','the cancellation posted');

  perform pg_temp.jwt(mgr); set local role authenticated;
  select * into r from ins_report_production(public.ins_local_today(),public.ins_local_today(),'client');
  perform pg_temp.assert(r.new_business=1600 and r.cancellations=-200 and r.net_written=1400 and r.policy_count=2,
    'production nets the return premium: 1,600 written, 200 returned, 1,400 net');
  perform pg_temp.assert((select count(*)=2 from ins_report_production(public.ins_local_today(),public.ins_local_today(),'product_line')),'both lines still listed');
  perform pg_temp.assert((select net_written=400 from ins_report_production(public.ins_local_today(),public.ins_local_today(),'product_line') where group_label='Marine'),
    'the cancelled line nets to 400');

  -- Batch 4 (20261121120000): the cancellations report reads the same posted
  -- cancellation, so its return premium must equal what production deducted.
  perform pg_temp.assert((select cancellation_count=1 and return_premium=200
                            from ins_report_cancellations(public.ins_local_today(),public.ins_local_today(),'client')),
    'cancellations report: one cancellation, 200 return premium');
  perform pg_temp.assert((select sum(return_premium) from ins_report_cancellations(public.ins_local_today(),public.ins_local_today(),'product_line'))
                         = -(select sum(cancellations) from ins_report_production(public.ins_local_today(),public.ins_local_today(),'product_line')),
    'cancellations report return premium equals the cancellations column of production');
  perform pg_temp.assert((select count(*)=1 and sum(return_premium)=200 from ins_report_cancellations(public.ins_local_today(),public.ins_local_today(),'insurer')),
    'insurer grouping: the one insurer carries the 200');
  perform pg_temp.assert((select count(*)=0 from ins_report_cancellations(public.ins_local_today()+1,public.ins_local_today()+1,'month')),
    'a period with no posted cancellation returns nothing');
  perform pg_temp.expect_error('select * from ins_report_cancellations(public.ins_local_today(),public.ins_local_today(),''nonsense'')',
    'INS_REPORT_INPUT','cancellations: invalid grouping is rejected');
  select count(*), coalesce(sum(outstanding),0) into n, v_sum from ins_report_outstanding_premium(public.ins_local_today());
  reset role;
  perform pg_temp.assert(v_sum=1000,'after the cancellation credit: 1,000 outstanding (600 + 400)');
  perform pg_temp.assert(v_sum = pg_temp.ar_balance(ar_gl),'outstanding equals the AR control balance after a credit note');

  -- ---------------------------------------------------------------
  -- Voiding the receipt puts the debt back and removes the collection
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(checker); set local role authenticated;
  perform fin_void_settlement(q.settlement_id,'Receipt entered in error',public.ins_local_today());
  reset role;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_premium_collected(public.ins_local_today(),public.ins_local_today())),'a receipt voided the same day is not collected');
  select coalesce(sum(outstanding),0) into v_sum from ins_report_outstanding_premium(public.ins_local_today());
  reset role;
  perform pg_temp.assert(v_sum=1400,'after the void: 1,400 outstanding (1,000 + 400)');
  perform pg_temp.assert(v_sum = pg_temp.ar_balance(ar_gl),'outstanding equals the AR control balance after a void');

  raise notice 'PASS: ins_reports_batch1 (access, production net of cancellation, collected, outstanding, ledger tie-out)';
end $$;

rollback;
