-- Insurance reports: insurer performance (20261123020000).
--
-- Tie-out test. Premium and commission are each insurer's recorded share, claims
-- are attributed pro rata by share, and the insurers' parts are shown to add up
-- to the whole: premium to the policies, claims to the claims register.
--
-- Covers: access (no role, other company, anonymous) and input validation; a
-- single-insurer policy and a 60/40 co-insured policy; each insurer's premium and
-- commission share; claims split pro rata with cent allocation (an odd reserve, a
-- part-paid approved claim); counts of policies, claims and open claims; the loss
-- ratio; premium adds up to the policies and claims add up to the register; a
-- period with no policies lists nothing; another company sees none of it.
--
-- NOT covered here (implemented, but no scenario yet): cancelled policies and
-- their count, imported policies and the include-imported switch, more than one
-- currency, a claim notified after the end date, and a policy with three or more
-- insurers.
--
-- Run against a fresh local stack only. One transaction that ROLLBACKs.

\set ON_ERROR_STOP on

begin;

create or replace function pg_temp.seed_commission_terms() returns void
language sql security definer set search_path = public, auth, pg_temp as $$
  insert into public.ins_insurer_commission_terms
    (tenant_id, insurer_id, mode, effective_from, status, agreed_ref, rationale,
     proposed_by, approved_by, approved_at)
  select i.tenant_id, i.id, 'on_insurer_settlement', date '2000-01-01', 'approved',
         'TEST-FIXTURE', 'test fixture default commission terms',
         (select id from auth.users order by id limit 1),
         (select id from auth.users order by id offset 1 limit 1),
         now()
    from public.ins_insurers i
   where not exists (
     select 1 from public.ins_insurer_commission_terms t
      where t.tenant_id = i.tenant_id and t.insurer_id = i.id and t.status = 'approved'
   );
$$;

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

create function pg_temp.bound_policy(p_client uuid, p_line uuid, p_gross numeric, p_shares jsonb)
returns public.ins_policies language plpgsql as $$
declare
  p public.ins_policies;
begin
  p := ins_create_policy(p_client, (p_shares -> 0 ->> 'insurer_id')::uuid, p_line, public.ins_local_today(),
                         public.ins_local_today() + 365, 5000000, 'UGX', p_gross, 10, null, null);
  perform ins_set_policy_financial_configuration(p.id, p_shares, '[]'::jsonb);
  return pg_temp.approve_and_bind(p.id);
end $$;

create function pg_temp.approved(p_claim uuid, p_amount numeric, p_appr uuid)
returns public.ins_claims language plpgsql as $$
declare c public.ins_claims;
  v_prev text := current_setting('request.jwt.claims', true);
begin
  perform public.ins_transition_claim(p_claim, 'assessing', null);
  perform set_config('request.jwt.claims', json_build_object('sub', p_appr, 'role', 'authenticated')::text, true);
  c := public.ins_transition_claim(p_claim, 'approved', 'ok', p_amount);
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return c;
end $$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid(); appr uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid; bank_gl uuid; trust_gl uuid;
  line_id uuid; alpha uuid; beta uuid;
  c ins_clients%rowtype;
  p1 ins_policies%rowtype; p2 ins_policies%rowtype;
  c1 ins_claims%rowtype; c2 ins_claims%rowtype; c3 ins_claims%rowtype;
  pay ins_claim_payments%rowtype;
  v_reg_out numeric; v_reg_paid numeric;
begin
  insert into tenants(id,name) values(ta,'Insurer performance test A'),(tb,'Insurer performance test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'ip-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[mgr,appr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u, case when u=other_mgr then tb else ta end, 'Insurer performance actor', 'ip-'||u||'@test.local'
    from unnest(array[mgr,appr,outsider,other_mgr]) u;
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role)
    values(ta,mgr,'insurance','manager'),(ta,appr,'insurance','manager'),(tb,other_mgr,'insurance','manager');

  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1000','Operating','asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1020','Client money','asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1100','AR','asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2010','Insurer payable','liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2020','Unearned commission','liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4000','Commission income','revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values
    (ta,'bank',bank_gl),(ta,'client_money_bank',trust_gl),(ta,'ar_control',ar_gl),
    (ta,'insurer_payable',pay_gl),(ta,'unearned_commission',unearned_gl),(ta,'commission_income',income_gl);

  perform pg_temp.jwt(mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_id;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into alpha; perform pg_temp.seed_commission_terms();
  insert into ins_insurers(tenant_id,code,name) values(ta,'BETA','Beta') returning id into beta; perform pg_temp.seed_commission_terms();
  c := ins_register_client('Insurer performance client','corporate',null,null,null,'low');

  -- p1: Alpha alone, 100,000 premium.   p2: Alpha 60 / Beta 40, 50,000 premium.
  p1 := pg_temp.bound_policy(c.id, line_id, 100000,
          jsonb_build_array(jsonb_build_object('insurer_id',alpha,'is_lead',true,'share_pct',100,'commission_rate_pct',10,'reviewed',true)));
  p2 := pg_temp.bound_policy(c.id, line_id, 50000,
          jsonb_build_array(jsonb_build_object('insurer_id',alpha,'is_lead',true,'share_pct',60,'commission_rate_pct',10,'reviewed',true),
                            jsonb_build_object('insurer_id',beta,'is_lead',false,'share_pct',40,'commission_rate_pct',10,'reviewed',true)));

  -- c1: p1, reserve 10,000.   c2: p2, an odd reserve of 1,001.01 (does not split evenly 60/40).
  -- c3: p2, approved for 20,000 and part paid 5,000.
  c1 := ins_create_claim(p1.id, public.ins_local_today(), public.ins_local_today(), 'Fire damage', null, 10000);
  c2 := ins_create_claim(p2.id, public.ins_local_today(), public.ins_local_today(), 'Water damage', null, 1001.01);
  c3 := ins_create_claim(p2.id, public.ins_local_today(), public.ins_local_today(), 'Cargo loss', null, 20000);
  c3 := pg_temp.approved(c3.id, 20000, appr);
  pay := ins_record_claim_payment(c3.id, 5000, public.ins_local_today(), 'ALPHA-CLM-001');
  reset role;

  -- ---------------------------------------------------------------
  -- Access and validation
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_insurer_performance(current_date-1,current_date+1)','INS_FORBIDDEN','insurance access is required');
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_insurer_performance(public.ins_local_today()-1,public.ins_local_today()+1)),
    'another company sees none of our insurers');
  reset role;
  set local role anon;
  perform pg_temp.expect_error('select * from ins_report_insurer_performance(current_date-1,current_date+1)','permission denied','anonymous cannot run it');
  reset role;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_insurer_performance(null,current_date)','INS_REPORT_INPUT','a period is required');
  perform pg_temp.expect_error('select * from ins_report_insurer_performance(current_date,current_date-1)','INS_REPORT_INPUT','the period must run forwards');
  reset role;

  -- ---------------------------------------------------------------
  -- Placed premium and commission: each insurer's own recorded share
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=2 from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today())),
    'two insurers placed business today');
  perform pg_temp.assert((select policy_count=2 and premium_placed=130000 and commission=13000 and commission_pct=10.0 and cancelled_policy_count=0
                            from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today()) where insurer_name='Alpha'),
    'Alpha: both policies, 100,000 + 60% of 50,000 premium, 10% commission');
  perform pg_temp.assert((select policy_count=1 and premium_placed=20000 and commission=2000
                            from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today()) where insurer_name='Beta'),
    'Beta: the co-insured policy only, 40% of 50,000 premium');
  perform pg_temp.assert((select sum(premium_placed) from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today()))
                         = (select sum(gross_premium) from ins_policies where id in (p1.id,p2.id)),
    'the insurers'' premium shares add up to the policies'' premium');
  perform pg_temp.assert((select count(*)=0 from ins_report_insurer_performance(public.ins_local_today()-10,public.ins_local_today()-1)),
    'a period before the policies were bound lists nothing');

  -- ---------------------------------------------------------------
  -- Claims, pro rata by share
  -- ---------------------------------------------------------------
  -- Alpha: c1 outstanding 10,000; c2 outstanding 600.61; c3 paid 3,000 and outstanding 9,000.
  perform pg_temp.assert((select claim_count=3 and open_claim_count=3 and claims_paid=3000 and claims_outstanding=19600.61
                            and claims_incurred=22600.61 and loss_ratio_pct=17.4
                            from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today()) where insurer_name='Alpha'),
    'Alpha: carries all of c1 and 60% of c2 and c3; incurred 22,600.61 is 17.4% of premium');
  -- Beta: c2 outstanding 400.40; c3 paid 2,000 and outstanding 6,000.
  perform pg_temp.assert((select claim_count=2 and open_claim_count=2 and claims_paid=2000 and claims_outstanding=6400.40
                            and claims_incurred=8400.40 and loss_ratio_pct=42.0
                            from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today()) where insurer_name='Beta'),
    'Beta: 40% of c2 and c3; incurred 8,400.40 is 42.0% of its premium share');
  select coalesce(sum(outstanding_amount),0), coalesce(sum(paid_as_at),0) into v_reg_out, v_reg_paid
    from ins_report_claims_register(public.ins_local_today(),'all');
  perform pg_temp.assert((select sum(claims_outstanding) from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today())) = v_reg_out,
    'the insurers'' outstanding claims add up to the claims register, to the cent');
  perform pg_temp.assert((select sum(claims_paid) from ins_report_insurer_performance(public.ins_local_today(),public.ins_local_today())) = v_reg_paid,
    'the insurers'' paid claims add up to the claims register');
  reset role;

  raise notice 'PASS: ins_reports_insurer_performance (access, validation, premium and commission shares, pro rata claims with cent allocation, loss ratio, ties to policies and claims register)';
end $$;

rollback;
