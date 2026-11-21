-- Insurance reports, batch 3 (20261121110000): claims register, claims ageing.
--
-- The point of this file is the tie-out. The register is compared with the claim
-- records themselves: the paid amount on the claim, and the reserve revision
-- history. The ageing report is checked against the register it is built on.
--
-- Covers: access (no role, other company, anonymous); input validation; the open
-- scope (notified, assessing and approved claims are open, a repudiated claim is
-- not); reserve as at (initial reserve and a revision); an approved claim shows
-- approved less paid; paid as at ties to the claim's paid amount; as-at a date
-- before the claims were notified shows nothing; scope 'all' adds the closed
-- claim; the ageing total equals the register total, grouped by insurer and by
-- product line; another company sees none of these claims.
--
-- Same-timestamp ordering: the fixture writes every event and revision in one
-- transaction, so they tie on now(). The register must still pick the latest status
-- and the final reserve (a chain of two revisions, then a status chain).
--
-- NOT covered here (implemented, but no scenario yet): a claim notified with a
-- back-dated notified date, a payment voided after the as-at date, brokerage-
-- managed claims (insurer receipt and client payout), ageing beyond the first
-- bucket (events are dated by when they are recorded, so older buckets need
-- back-dated fixtures), and co-insured policies (lead insurer only).
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
  maker uuid := gen_random_uuid(); checker uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid(); appr uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  clearing uuid; ap_gl uuid; line_id uuid; line2 uuid; insurer uuid;
  c ins_clients%rowtype; p1 ins_policies%rowtype; p2 ins_policies%rowtype;
  ca ins_claims%rowtype; cb ins_claims%rowtype; cc ins_claims%rowtype; cd ins_claims%rowtype;
  pay ins_claim_payments%rowtype;
  v_reg numeric; v_age numeric; v_paid_claim numeric;
begin
  insert into tenants(id,name) values(ta,'Claims reports test A'),(tb,'Claims reports test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'clrep-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[maker,checker,mgr,appr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u, case when u=other_mgr then tb else ta end, 'Claims reports actor', 'clrep-'||u||'@test.local'
    from unnest(array[maker,checker,mgr,appr,outsider,other_mgr]) u;
  insert into finance_team_members(tenant_id,user_id,role) values (ta,maker,'finance'),(ta,checker,'finance');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role)
    values(ta,mgr,'insurance','manager'),(ta,appr,'insurance','manager'),(tb,other_mgr,'insurance','manager');

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
  c := ins_register_client('Claims reports client','corporate',null,null,null,'low');
  p1 := ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,5000000,'UGX',1000,10,null,null);
  p1 := pg_temp.approve_and_bind(p1.id);
  p2 := ins_create_policy(c.id,insurer,line2,current_date,current_date+365,5000000,'UGX',600,10,null,null);
  p2 := pg_temp.approve_and_bind(p2.id);

  -- ca: notified, reserve 500,000 (policy 1, Fire)
  ca := ins_create_claim(p1.id, current_date, current_date, 'Fire damage', null, 500000);
  -- cb: assessing, reserve revised 300,000 -> 400,000 (policy 1, Fire)
  cb := ins_create_claim(p1.id, current_date, current_date, 'Water damage', null, 300000);
  -- two revisions in one transaction share a timestamp: the latest is found by the
  -- chain (previous_amount), not by the random id (20261121130000)
  cb := ins_revise_claim_reserve(cb.id, 350000, 'First loss adjuster estimate');
  cb := ins_revise_claim_reserve(cb.id, 400000, 'Loss adjuster estimate');
  cb := ins_transition_claim(cb.id, 'assessing', null);
  -- cc: approved for 200,000 and part paid 50,000 (policy 2, Marine)
  cc := ins_create_claim(p2.id, current_date, current_date, 'Cargo loss', null, 250000);
  cc := pg_temp.approved(cc.id, 200000, appr);
  pay := ins_record_claim_payment(cc.id, 50000, current_date, 'ALPHA-CLM-001');
  -- cd: repudiated (policy 2, Marine)
  cd := ins_create_claim(p2.id, current_date, current_date, 'Late notification', null, 100000);
  cd := ins_transition_claim(cd.id, 'assessing', null);
  perform set_config('request.jwt.claims', json_build_object('sub', appr, 'role', 'authenticated')::text, true);
  cd := ins_transition_claim(cd.id, 'repudiated', 'Excluded peril');
  reset role;

  -- ---------------------------------------------------------------
  -- Access
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_claims_register(current_date)','INS_FORBIDDEN','register needs insurance access');
  perform pg_temp.expect_error('select * from ins_report_claims_ageing(current_date)','INS_FORBIDDEN','ageing needs insurance access');
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_claims_register(current_date,'all')),'another company sees none of our claims');
  perform pg_temp.assert((select count(*)=0 from ins_report_claims_ageing(current_date)),'another company sees no ageing rows of ours');
  reset role;
  set local role anon;
  perform pg_temp.expect_error('select * from ins_report_claims_register(current_date)','permission denied','anonymous cannot run the register');
  perform pg_temp.expect_error('select * from ins_report_claims_ageing(current_date)','permission denied','anonymous cannot run the ageing report');
  reset role;

  -- ---------------------------------------------------------------
  -- Input validation
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_claims_register(null)','INS_REPORT_INPUT','an as-at date is required');
  perform pg_temp.expect_error('select * from ins_report_claims_register(current_date,''bogus'')','INS_REPORT_INPUT','scope must be open or all');
  perform pg_temp.expect_error('select * from ins_report_claims_ageing(current_date,''client'')','INS_REPORT_INPUT','client grouping is not offered');
  reset role;

  -- ---------------------------------------------------------------
  -- Register
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=3 from ins_report_claims_register(current_date)),
    'open scope: notified, assessing and approved claims are open, the repudiated one is not');
  perform pg_temp.assert((select count(*)=4 from ins_report_claims_register(current_date,'all')),
    'scope all adds the repudiated claim');
  perform pg_temp.assert((select reserve_as_at=500000 and outstanding_amount=500000 and status_as_at='notified'
                            from ins_report_claims_register(current_date) where claim_id=ca.id),
    'notified claim: outstanding is its reserve');
  perform pg_temp.assert((select reserve_as_at=400000 and outstanding_amount=400000 and status_as_at='assessing'
                            from ins_report_claims_register(current_date) where claim_id=cb.id),
    'assessing claim: outstanding is the revised reserve, not the initial one');
  perform pg_temp.assert((select status_as_at='approved' and approved_amount=200000 and paid_as_at=50000 and outstanding_amount=150000
                            from ins_report_claims_register(current_date) where claim_id=cc.id),
    'approved claim: outstanding is approved less paid');
  perform pg_temp.assert((select status_as_at='repudiated' and outstanding_amount=0 and not is_open and age_bucket='closed'
                            from ins_report_claims_register(current_date,'all') where claim_id=cd.id),
    'repudiated claim owes nothing and is not open');
  select paid_amount into v_paid_claim from ins_claims where id=cc.id;
  perform pg_temp.assert((select paid_as_at = v_paid_claim from ins_report_claims_register(current_date) where claim_id=cc.id),
    'paid as at ties to the paid amount on the claim');
  perform pg_temp.assert((select policy_no=p1.policy_no and insurer_name='Alpha' and product_line_name='Fire' and currency='UGX' and client_name is not null
                            from ins_report_claims_register(current_date) where claim_id=ca.id),
    'the row names the policy, insurer, product line, client and currency');
  perform pg_temp.assert((select count(*)=0 from ins_report_claims_register(current_date-1,'all')),
    'as at a date before the claims were notified, nothing is listed');
  reset role;

  -- ---------------------------------------------------------------
  -- Ageing ties to the register
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  select coalesce(sum(outstanding_amount),0) into v_reg from ins_report_claims_register(current_date);
  select coalesce(sum(outstanding_total),0) into v_age from ins_report_claims_ageing(current_date);
  perform pg_temp.assert(v_reg = 1050000, 'register outstanding is 500,000 + 400,000 + 150,000');
  perform pg_temp.assert(v_age = v_reg, 'ageing total equals the register total');
  perform pg_temp.assert((select count(*)=1 and min(age_bucket)='0-30' and sum(claim_count)=3 from ins_report_claims_ageing(current_date)),
    'all three open claims were notified today, so they sit in the first bucket');
  perform pg_temp.assert((select count(*)=1 and min(group_label)='Alpha' and sum(outstanding_total)=1050000 from ins_report_claims_ageing(current_date,'insurer')),
    'grouped by insurer: one insurer, same total');
  perform pg_temp.assert((select count(*)=2 and sum(outstanding_total)=1050000 from ins_report_claims_ageing(current_date,'product_line')),
    'grouped by product line: Fire and Marine, same total');
  perform pg_temp.assert((select outstanding_total=900000 from ins_report_claims_ageing(current_date,'product_line') where group_label='Fire'),
    'Fire holds the notified and assessing claims');
  perform pg_temp.assert((select outstanding_total=150000 from ins_report_claims_ageing(current_date,'product_line') where group_label='Marine'),
    'Marine holds the part-paid approved claim');
  reset role;

  raise notice 'PASS: ins_reports_batch3 (access, validation, register scope, reserve revision, approved less paid, paid tie-out, ageing ties to register, grouping)';
end $$;

rollback;
