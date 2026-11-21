-- Insurance reports, batch 4 (20261121120000): cancellation register, renewals, renewal retention.
--
-- Tie-out test. The cancellation register is compared with the cancellations summary and with the
-- cancellations column of production; renewal retention is compared with the renewals rows it is
-- built on.
--
-- Covers: access (no role, other company, anonymous); input validation; the cancellation register
-- (one posted cancellation, its amounts, its dates, an empty period); register sums equal the
-- cancellations summary and production; renewals for a window (a renewed policy with its renewal
-- policy and premium, a policy recorded as lost with its reason, an upcoming policy, a policy
-- outside the window left out); retention counts and percentages, by insurer and by product line;
-- retention counts equal the renewals rows.
--
-- NOT covered here (implemented, but no scenario yet): the 'unresolved' outcome (a policy past its
-- expiry with nothing recorded; the API does not allow bringing an expiry date into the past, so it
-- needs a back-dated fixture), declined and lapsed outcomes, imported policies and the
-- include-imported switch, co-insured cancellations splitting by insurer, and a cancellation
-- posted in a different period from its effective date.
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
  clearing uuid; ap_gl uuid; line_id uuid; line2 uuid; insurer uuid;
  c ins_clients%rowtype;
  r1 ins_policies%rowtype; r2 ins_policies%rowtype; r3 ins_policies%rowtype; r4 ins_policies%rowtype;
  rn ins_policies%rowtype; pc ins_policies%rowtype;
  cx ins_policy_cancellations%rowtype; terms jsonb;
  v_reg_n integer; v_due integer; v_renewed integer;
begin
  insert into tenants(id,name) values(ta,'Batch 4 test A'),(tb,'Batch 4 test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'b4-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[maker,checker,mgr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u, case when u=other_mgr then tb else ta end, 'Batch 4 actor', 'b4-'||u||'@test.local'
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

  perform pg_temp.jwt(mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_id;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MARINE','Marine') returning id into line2;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c := ins_register_client('Batch 4 client','corporate',null,null,null,'low');

  -- Renewal fixtures: three policies expiring inside the 60-day window, one outside it.
  --   r1 Fire   1,000 expires in 30 days -> renewed (a renewal is bound)
  --   r2 Marine 2,000 expires in 40 days -> recorded as lost
  --   r3 Fire     500 expires in 50 days -> upcoming, nothing recorded
  --   r4 Fire   9,000 expires in 200 days -> outside the window
  r1 := ins_create_policy(c.id,insurer,line_id,public.ins_local_today()-300,public.ins_local_today()+30,5000000,'UGX',1000,10,null,null);
  r1 := pg_temp.approve_and_bind(r1.id);
  r2 := ins_create_policy(c.id,insurer,line2,public.ins_local_today()-290,public.ins_local_today()+40,5000000,'UGX',2000,10,null,null);
  r2 := pg_temp.approve_and_bind(r2.id);
  r3 := ins_create_policy(c.id,insurer,line_id,public.ins_local_today()-280,public.ins_local_today()+50,5000000,'UGX',500,10,null,null);
  r3 := pg_temp.approve_and_bind(r3.id);
  r4 := ins_create_policy(c.id,insurer,line_id,public.ins_local_today()-165,public.ins_local_today()+200,5000000,'UGX',9000,10,null,null);
  r4 := pg_temp.approve_and_bind(r4.id);

  rn := ins_create_renewal_draft(r1.id);
  rn := pg_temp.approve_and_bind(rn.id);
  perform ins_record_renewal_outcome(r2.id,'lost','Went to a competitor');

  -- Cancellation fixture: one policy bound today and cancelled today, 200 returned.
  pc := ins_create_policy(c.id,insurer,line2,public.ins_local_today(),public.ins_local_today()+365,5000000,'UGX',600,10,null,null);
  pc := pg_temp.approve_and_bind(pc.id);
  reset role;

  terms := jsonb_build_array(jsonb_build_object('insurer_id',insurer,'terms',
    jsonb_build_object('method','manual_review','contract_reference','Alpha agreed cancellation','manual_return_premium','200')));
  perform pg_temp.jwt(mgr); set local role authenticated;
  cx := ins_submit_policy_cancellation(pc.id,public.ins_local_today(),terms,'[]'::jsonb,'Insurer-approved cancellation',gen_random_uuid());
  perform pg_temp.jwt(maker);
  cx := ins_prepare_policy_cancellation(cx.id,clearing);
  perform pg_temp.jwt(checker);
  cx := ins_decide_policy_cancellation(cx.id,'approve','Reviewed insurer contract terms',true);
  reset role;
  perform pg_temp.assert(cx.status='posted','the cancellation posted');

  -- ---------------------------------------------------------------
  -- Access
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_cancellation_register(public.ins_local_today(),public.ins_local_today())','INS_FORBIDDEN','register needs insurance access');
  perform pg_temp.expect_error('select * from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60)','INS_FORBIDDEN','renewals need insurance access');
  perform pg_temp.expect_error('select * from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60)','INS_FORBIDDEN','retention needs insurance access');
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_cancellation_register(public.ins_local_today(),public.ins_local_today())),'another company sees none of our cancellations');
  perform pg_temp.assert((select count(*)=0 from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+365)),'another company sees none of our renewals');
  perform pg_temp.assert((select count(*)=0 from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+365)),'another company sees no retention rows of ours');
  reset role;
  set local role anon;
  perform pg_temp.expect_error('select * from ins_report_cancellation_register(public.ins_local_today(),public.ins_local_today())','permission denied','anonymous cannot run the register');
  perform pg_temp.expect_error('select * from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60)','permission denied','anonymous cannot run renewals');
  perform pg_temp.expect_error('select * from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60)','permission denied','anonymous cannot run retention');
  reset role;

  -- ---------------------------------------------------------------
  -- Input validation
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_cancellation_register(public.ins_local_today()+1,public.ins_local_today())','INS_REPORT_INPUT','register period must run forwards');
  perform pg_temp.expect_error('select * from ins_report_cancellation_register(null,public.ins_local_today())','INS_REPORT_INPUT','register needs a start date');
  perform pg_temp.expect_error('select * from ins_report_renewals(public.ins_local_today()+1,public.ins_local_today())','INS_REPORT_INPUT','renewals period must run forwards');
  perform pg_temp.expect_error('select * from ins_report_renewal_retention(public.ins_local_today()+1,public.ins_local_today())','INS_REPORT_INPUT','retention period must run forwards');
  perform pg_temp.expect_error('select * from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60,''bogus'')','INS_REPORT_INPUT','retention grouping must be one offered');
  reset role;

  -- ---------------------------------------------------------------
  -- Cancellation register
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=1 from ins_report_cancellation_register(public.ins_local_today(),public.ins_local_today())),
    'register: one posted cancellation today');
  perform pg_temp.assert((select policy_no=pc.policy_no and currency='UGX' and return_premium=200 and posting_date=public.ins_local_today()
                            and cancellation_no is not null and insurer_name='Alpha' and product_line_name='Marine' and client_name is not null
                            from ins_report_cancellation_register(public.ins_local_today(),public.ins_local_today())),
    'register row names the policy, insurer, product line and client, and carries 200 return premium');
  perform pg_temp.assert((select count(*)=0 from ins_report_cancellation_register(public.ins_local_today()+1,public.ins_local_today()+1)),
    'register: nothing in a period with no posted cancellation');
  perform pg_temp.assert((select row(sum(return_premium),sum(commission_clawback),sum(retained_commission),sum(total_insurer_credit))
                            from ins_report_cancellation_register(public.ins_local_today(),public.ins_local_today()))
                         is not distinct from
                         (select row(sum(return_premium),sum(commission_clawback),sum(retained_commission),sum(total_insurer_credit))
                            from ins_report_cancellations(public.ins_local_today(),public.ins_local_today(),'insurer')),
    'register totals equal the cancellations summary: return premium, clawback, retained commission, insurer credit');
  perform pg_temp.assert((select sum(return_premium) from ins_report_cancellation_register(public.ins_local_today(),public.ins_local_today()))
                         = -(select sum(cancellations) from ins_report_production(public.ins_local_today(),public.ins_local_today(),'month')),
    'register return premium equals the cancellations column of production');
  reset role;

  -- ---------------------------------------------------------------
  -- Renewals
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=3 from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60)),
    'renewals: three policies expire in the next 60 days, the one expiring in 200 days is left out');
  perform pg_temp.assert((select count(*)=4 from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+250)),
    'renewals: a wider window adds the policy expiring in 200 days');
  perform pg_temp.assert((select outcome='renewed' and renewal_policy_no=rn.policy_no and renewal_premium=1000 and expiring_premium=1000
                            and days_to_expiry=30 and currency='UGX'
                            from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60) where policy_id=r1.id),
    'renewed policy: outcome renewed, linked to the bound renewal and its premium');
  perform pg_temp.assert((select outcome='lost' and outcome_reason='Went to a competitor' and renewal_policy_no is null and renewal_premium is null
                            from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60) where policy_id=r2.id),
    'policy recorded as lost: outcome lost with the reason, no renewal');
  perform pg_temp.assert((select outcome='upcoming' and outcome_reason is null and renewal_policy_no is null
                            from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60) where policy_id=r3.id),
    'policy not yet expired and with nothing recorded is upcoming');
  perform pg_temp.assert((select count(*)=0 from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60) where policy_id=rn.id),
    'the renewal policy itself expires later and is not in this window');
  perform pg_temp.assert((select count(*)=0 from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60) where policy_id=pc.id),
    'the cancelled policy never reaches expiry and is not listed');
  reset role;

  -- ---------------------------------------------------------------
  -- Retention
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=1 and min(due_count)=3 and min(renewed_count)=1 and min(lost_count)=1
                            and min(unresolved_count)=0 and min(upcoming_count)=1
                            and min(expiring_premium)=3500 and min(renewed_premium)=1000
                            from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60,'insurer')),
    'retention by insurer: 3 due, 1 renewed, 1 lost, 1 upcoming, 3,500 expiring, 1,000 renewed');
  perform pg_temp.assert((select retention_count_pct=50.0 and retention_premium_pct=33.3
                            from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60,'insurer')),
    'retention by insurer: 1 of the 2 matured policies renewed (50.0%), 1,000 of 3,000 matured premium (33.3%)');
  perform pg_temp.assert((select due_count=2 and renewed_count=1 and upcoming_count=1 and expiring_premium=1500
                            and retention_count_pct=100.0 and retention_premium_pct=100.0
                            from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60,'product_line') where group_label='Fire'),
    'retention for Fire: upcoming policy is left out of both denominators, so 100.0% and 100.0%');
  perform pg_temp.assert((select due_count=1 and lost_count=1 and retention_count_pct=0.0 and retention_premium_pct=0.0
                            from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60,'product_line') where group_label='Marine'),
    'retention for Marine: the only policy was lost, so 0.0% and 0.0%');
  select count(*) into v_reg_n from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60);
  select coalesce(sum(due_count),0), coalesce(sum(renewed_count),0) into v_due, v_renewed
    from ins_report_renewal_retention(public.ins_local_today(),public.ins_local_today()+60,'product_line');
  perform pg_temp.assert(v_due = v_reg_n, 'retention due counts add up to the renewals rows');
  perform pg_temp.assert(v_renewed = (select count(*) from ins_report_renewals(public.ins_local_today(),public.ins_local_today()+60) where outcome='renewed'),
    'retention renewed counts equal the renewed rows');
  perform pg_temp.assert((select retention_count_pct is null and retention_premium_pct is null and due_count=1 and upcoming_count=1
                            from ins_report_renewal_retention(public.ins_local_today()+45,public.ins_local_today()+55,'insurer')),
    'a window where nothing has expired yet has no percentage, not 0%');
  reset role;

  raise notice 'PASS: ins_reports_batch4 (access, validation, cancellation register tie-out, renewals, retention ties to renewals)';
end $$;

rollback;
