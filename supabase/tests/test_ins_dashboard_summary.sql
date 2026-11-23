-- Insurance dashboard summary (20261123030000).
--
-- Tie-out test. The dashboard function adds nothing of its own: every figure is
-- shown to equal the report it comes from, and the figures a person can check by
-- hand are checked by hand.
--
-- Covers: access (no role, other company, anonymous) and input validation; gross
-- premium written, a cancellation and the net figure (gross + endorsements +
-- cancellations + reversals = net); commission earned equals the commission report;
-- a real client receipt equals premium collected; outstanding premium equals the
-- outstanding premium report and overdue is part of it; an open claim equals the
-- claims register; policy count; a period with no business shows nothing; another
-- company sees none of it.
--
-- NOT covered here (implemented, but no scenario yet): a second currency, imported
-- policies and the include-imported switch, an endorsement, a reversed policy, and
-- overdue premium past its due date (everything here is due in the future).
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



do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  maker uuid := gen_random_uuid(); checker uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid(); outsider uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  clearing uuid; ap_gl uuid; line_id uuid; insurer uuid; trust uuid;
  c ins_clients%rowtype;
  pa ins_policies%rowtype; pb ins_policies%rowtype;
  cx ins_policy_cancellations%rowtype; q ins_policy_cash_requests%rowtype; cl ins_claims%rowtype;
  terms jsonb;
  v_prod_nb numeric; v_prod_nw numeric; v_comm numeric; v_coll numeric; v_out numeric; v_claims numeric;
begin
  insert into tenants(id,name) values(ta,'Dashboard test A'),(tb,'Dashboard test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'dash-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[maker,checker,mgr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u, case when u=other_mgr then tb else ta end, 'Dashboard actor', 'dash-'||u||'@test.local'
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
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id) values(ta,'DASH-TRUST','client_money','UGX',trust_gl) returning id into trust;

  perform pg_temp.jwt(mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_id;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c := ins_register_client('Dashboard client','corporate',null,null,null,'low');

  -- pa: 100,000 premium, stays in force.   pb: 60,000 premium, cancelled today with 20,000 returned.
  pa := ins_create_policy(c.id,insurer,line_id,public.ins_local_today(),public.ins_local_today()+365,5000000,'UGX',100000,10,null,null);
  pa := pg_temp.approve_and_bind(pa.id);
  pb := ins_create_policy(c.id,insurer,line_id,public.ins_local_today(),public.ins_local_today()+365,5000000,'UGX',60000,10,null,null);
  pb := pg_temp.approve_and_bind(pb.id);

  -- A claim on pa, reserve 7,000.
  cl := ins_create_claim(pa.id, public.ins_local_today(), public.ins_local_today(), 'Fire damage', null, 7000);
  reset role;

  -- A client receipt of 40,000 on pa.
  perform pg_temp.jwt(maker); set local role authenticated;
  q := ins_submit_policy_cash_request(pa.id,'receipt',trust,40000,public.ins_local_today(),gen_random_uuid(),'DASH-001','part payment');
  perform pg_temp.jwt(checker);
  q := ins_decide_policy_cash_request(q.id,'approve');
  reset role;

  -- pb is cancelled with 20,000 returned.
  terms := jsonb_build_array(jsonb_build_object('insurer_id',insurer,'terms',
    jsonb_build_object('method','manual_review','contract_reference','Alpha agreed cancellation','manual_return_premium','20000')));
  perform pg_temp.jwt(mgr); set local role authenticated;
  cx := ins_submit_policy_cancellation(pb.id,public.ins_local_today(),terms,'[]'::jsonb,'Insurer-approved cancellation',gen_random_uuid());
  perform pg_temp.jwt(maker);
  cx := ins_prepare_policy_cancellation(cx.id,clearing);
  perform pg_temp.jwt(checker);
  cx := ins_decide_policy_cancellation(cx.id,'approve','Reviewed insurer contract terms',true);
  reset role;
  perform pg_temp.assert(cx.status='posted','the cancellation posted');

  -- ---------------------------------------------------------------
  -- Access and validation
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_dashboard_summary(current_date,current_date)','INS_FORBIDDEN','the dashboard needs insurance access');
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),'another company sees none of our figures');
  reset role;
  set local role anon;
  perform pg_temp.expect_error('select * from ins_dashboard_summary(current_date,current_date)','permission denied','anonymous cannot run it');
  reset role;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_dashboard_summary(null,current_date)','INS_REPORT_INPUT','a period is required');
  perform pg_temp.expect_error('select * from ins_dashboard_summary(current_date,current_date-1)','INS_REPORT_INPUT','the period must run forwards');
  reset role;

  -- ---------------------------------------------------------------
  -- The figures
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=1 from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),'one currency, one row');
  perform pg_temp.assert((select currency='UGX' and policy_count=2 from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'two policies were bound in the period');
  perform pg_temp.assert((select gross_written=160000 from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'gross written is the premium bound: 100,000 + 60,000');
  perform pg_temp.assert((select cancellations=-20000 and endorsements=0 and reversals=0 from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'the cancellation shows as 20,000 returned, negative');
  perform pg_temp.assert((select net_written=140000 and gross_written+endorsements+cancellations+reversals=net_written
                            from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'net written is 140,000 and gross plus the movements equals net');
  perform pg_temp.assert((select premium_collected=40000 from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'the 40,000 receipt is premium collected');
  perform pg_temp.assert((select open_claim_count=1 and claims_outstanding=7000 from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'one open claim with 7,000 outstanding');

  -- Every figure equals the report it comes from.
  select coalesce(sum(new_business),0), coalesce(sum(net_written),0) into v_prod_nb, v_prod_nw
    from ins_report_production(public.ins_local_today(),public.ins_local_today(),'month');
  select coalesce(sum(net_earned),0) into v_comm from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today(),'month');
  select coalesce(sum(collected),0) into v_coll from ins_report_premium_collected(public.ins_local_today(),public.ins_local_today(),'month');
  select coalesce(sum(outstanding),0) into v_out from ins_report_outstanding_premium(public.ins_local_today());
  select coalesce(sum(outstanding_amount),0) into v_claims from ins_report_claims_register(public.ins_local_today(),'open');
  perform pg_temp.assert((select gross_written=v_prod_nb and net_written=v_prod_nw from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'written figures equal the production report');
  perform pg_temp.assert((select commission_earned=v_comm from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'commission earned equals the commission report');
  perform pg_temp.assert((select premium_collected=v_coll from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'premium collected equals the collections report');
  perform pg_temp.assert((select outstanding_premium=v_out and overdue_premium<=outstanding_premium and overdue_premium>=0
                            from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'outstanding premium equals the outstanding report, and the overdue part is within it');
  perform pg_temp.assert((select claims_outstanding=v_claims from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'claims outstanding equals the claims register');
  perform pg_temp.assert((select count(*)=0 from ins_dashboard_summary(public.ins_local_today()-10,public.ins_local_today()-1)
                           where gross_written<>0 or commission_earned<>0 or premium_collected<>0),
    'a period before any business shows no movement');
  reset role;

  -- A company with no commission income posting rule still gets everything else.
  delete from gl_posting_rules where tenant_id = ta and account_role = 'commission_income';
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select commission_earned is null and gross_written=160000 and premium_collected=40000 and claims_outstanding=7000
                            from ins_dashboard_summary(public.ins_local_today(),public.ins_local_today())),
    'no commission posting rule: commission is null, not zero, and the other figures still load');
  reset role;

  raise notice 'PASS: ins_dashboard_summary (access, validation, written, cancellation, net, collected, claims, every figure ties to its report)';
end $$;

rollback;
