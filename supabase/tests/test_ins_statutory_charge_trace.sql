-- Statutory charges: allocation record, trace, summary and reconciliation
-- (20261123010000).
--
-- The point of this file is the tie-out. Every statutory charge is followed from
-- the assessment on the policy, through the allocation to the insurer share,
-- through a real client receipt and a real insurer remittance, and the
-- reconciliation is shown to fail when the books and the record disagree.
--
-- Covers: the allocation rows written by bind (single insurer, two insurers with
-- the cent rule, a charge that does not divide evenly); the rows add up to each
-- share's booked pass-through; the rows are evidence and cannot be changed; the
-- backfill rebuilds the same rows; access (no role, other company, anonymous) and
-- input validation; the summary by charge and by insurer; a pro rata collection
-- and a pro rata remittance with the basis written out; a receipt split across
-- two insurer allocations adds up to the whole; the exceptions report is empty
-- when everything ties and names the policy when a booked amount is changed;
-- another company sees nothing.
--
-- NOT covered here (implemented, but no scenario yet): a receipt or remittance
-- voided after the as-at date, a policy cancelled after bind (its rows stay and
-- the status shows), imported policies and the include-imported switch, manual
-- (non-catalogue) pass-through charges, and several charges on one policy.
-- Reversal on cancellation and a brokerage-held remittance are not built.
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

-- A policy priced with the training levy, acknowledged, approved and bound.
create function pg_temp.bound_policy(p_client uuid, p_line uuid, p_gross numeric, p_shares jsonb)
returns public.ins_policies language plpgsql as $$
declare
  p public.ins_policies;
begin
  p := ins_create_policy(p_client, (p_shares -> 0 ->> 'insurer_id')::uuid, p_line, public.ins_local_today(),
                         public.ins_local_today() + 365, 5000000, 'UGX', p_gross, 10, null, null);
  perform ins_set_policy_financial_configuration(p.id, p_shares, '[]'::jsonb);
  perform ins_apply_statutory_charges(p.id);
  perform ins_acknowledge_statutory_charges(p.id);
  return pg_temp.approve_and_bind(p.id);
end $$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid(); admin2 uuid := gen_random_uuid();
  maker uuid := gen_random_uuid(); checker uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid(); outsider uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid; rec_gl uuid; levy_gl uuid;
  trust uuid; line_id uuid; alpha uuid; beta uuid; v_setting uuid;
  c ins_clients%rowtype;
  p1 ins_policies%rowtype; p2 ins_policies%rowtype; p3 ins_policies%rowtype;
  q ins_policy_cash_requests%rowtype;
  v_t1 numeric; v_p1 numeric; v_t3 numeric;
  v_exact_a numeric; v_exact_b numeric; v_sum_exact numeric;
begin
  insert into tenants(id,name) values(ta,'Statutory trace test A'),(tb,'Statutory trace test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'sct-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[admin1,admin2,maker,checker,mgr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u, case when u=other_mgr then tb else ta end, 'Statutory trace actor', 'sct-'||u||'@test.local'
    from unnest(array[admin1,admin2,maker,checker,mgr,outsider,other_mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);
  insert into finance_team_members(tenant_id,user_id,role) values (ta,maker,'finance'),(ta,checker,'finance');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values(ta,mgr,'insurance','manager'),(tb,other_mgr,'insurance','manager');

  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1000','Operating','asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1020','Client money','asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1100','AR','asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2010','Insurer payable','liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2020','Unearned commission','liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4000','Commission income','revenue') returning id into income_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1110','Commission receivable','asset') returning id into rec_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type,is_control_account) values(ta,'2060','Insurance Training Levy Payable','liability',true) returning id into levy_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values
    (ta,'bank',bank_gl),(ta,'client_money_bank',trust_gl),(ta,'ar_control',ar_gl),
    (ta,'insurer_payable',pay_gl),(ta,'unearned_commission',unearned_gl),(ta,'commission_income',income_gl),
    (ta,'commission_receivable',rec_gl),(ta,'insurance_training_levy_payable',levy_gl);
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id) values(ta,'STAT-TRUST','client_money','UGX',trust_gl) returning id into trust;

  -- This company collects the levy, and recognises commission conservatively.
  perform pg_temp.jwt(admin1); set local role authenticated;
  v_setting := (public.acct_setting_propose('ins.statutory_charge_enforcement','required',public.ins_local_today(),'test fixture: this company collects a statutory levy')).id;
  reset role;
  perform pg_temp.jwt(admin2); set local role authenticated;
  perform public.acct_setting_approve(v_setting);
  reset role;
  perform pg_temp.jwt(admin1); set local role authenticated;
  v_setting := (public.acct_setting_propose('ins.commission_recognition','on_insurer_settlement',public.ins_local_today(),'test fixture: the conservative default')).id;
  reset role;
  perform pg_temp.jwt(admin2); set local role authenticated;
  perform public.acct_setting_approve(v_setting);
  reset role;

  perform pg_temp.jwt(mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_id;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into alpha;
  insert into ins_insurers(tenant_id,code,name) values(ta,'BETA','Beta') returning id into beta;
  c := ins_register_client('Statutory trace client','corporate',null,null,null,'low');

  -- p1: one insurer, 100,000 premium, 500 levy.   p2: Alpha 60 / Beta 40, 100,000, 500 levy.
  -- p3: Alpha 60 / Beta 40, 33,333 premium: the levy does not divide evenly across the shares.
  p1 := pg_temp.bound_policy(c.id, line_id, 100000,
          jsonb_build_array(jsonb_build_object('insurer_id',alpha,'is_lead',true,'share_pct',100,'commission_rate_pct',10,'reviewed',true)));
  p2 := pg_temp.bound_policy(c.id, line_id, 100000,
          jsonb_build_array(jsonb_build_object('insurer_id',alpha,'is_lead',true,'share_pct',60,'commission_rate_pct',10,'reviewed',true),
                            jsonb_build_object('insurer_id',beta,'is_lead',false,'share_pct',40,'commission_rate_pct',10,'reviewed',true)));
  p3 := pg_temp.bound_policy(c.id, line_id, 33333,
          jsonb_build_array(jsonb_build_object('insurer_id',alpha,'is_lead',true,'share_pct',60,'commission_rate_pct',10,'reviewed',true),
                            jsonb_build_object('insurer_id',beta,'is_lead',false,'share_pct',40,'commission_rate_pct',10,'reviewed',true)));
  reset role;

  -- ---------------------------------------------------------------
  -- Allocation rows, written around bind
  -- ---------------------------------------------------------------
  perform pg_temp.assert((select count(*)=1 and min(amount)=500 and min(source)='bind' from ins_policy_charge_allocations where policy_id=p1.id),
    'p1: one insurer, one allocation of 500, written by the bind trigger');
  perform pg_temp.assert((select count(*)=2 from ins_policy_charge_allocations where policy_id=p2.id)
                         and (select amount=300 from ins_policy_charge_allocations where policy_id=p2.id and insurer_id=alpha)
                         and (select amount=200 from ins_policy_charge_allocations where policy_id=p2.id and insurer_id=beta),
    'p2: the 500 levy splits 300 to Alpha and 200 to Beta');
  perform pg_temp.assert((select sum(amount) from ins_policy_charge_allocations where policy_id=p3.id)
                         = (select amount from ins_policy_charges where policy_id=p3.id and catalogue_id is not null),
    'p3: an uneven levy is allocated without losing or inventing a cent');
  perform pg_temp.assert(not exists (
      select 1 from ins_policy_insurer_shares s
       where s.policy_id in (p1.id,p2.id,p3.id)
         and s.pass_through_amount <> coalesce((select sum(a.amount) from ins_policy_charge_allocations a where a.insurer_share_id=s.id),0)),
    'every share''s allocations equal the pass-through amount bind booked');
  perform pg_temp.expect_error(format('update ins_policy_charge_allocations set amount=1 where policy_id=%L',p1.id),
    'INS_CHARGE_ALLOCATION_IMMUTABLE','allocations cannot be changed');
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error(format('delete from ins_policy_charge_allocations where policy_id=%L',p1.id),
    'permission denied','a caller cannot remove an allocation');
  perform pg_temp.expect_error(format('insert into ins_policy_charge_allocations(tenant_id,policy_id,charge_id,insurer_share_id,insurer_id,amount,currency,source) select tenant_id,policy_id,charge_id,insurer_share_id,insurer_id,1,currency,''bind'' from ins_policy_charge_allocations where policy_id=%L limit 1',p1.id),
    'permission denied','a caller cannot write an allocation');
  reset role;

  -- The backfill rebuilds exactly the same rows.
  create temp table before_rows on commit drop as
    select charge_id, insurer_share_id, amount from ins_policy_charge_allocations where policy_id = p2.id;
  delete from ins_policy_charge_allocations where policy_id = p2.id;
  perform pg_temp.assert(ins_record_charge_allocations(p2.id,'backfill')=2, 'backfill writes the two rows again');
  perform pg_temp.assert(not exists (select 1 from before_rows b where not exists (
      select 1 from ins_policy_charge_allocations a where a.policy_id=p2.id and a.charge_id=b.charge_id
         and a.insurer_share_id=b.insurer_share_id and a.amount=b.amount and a.source='backfill')),
    'backfill reproduces the bind-time rows');
  perform pg_temp.assert(ins_record_charge_allocations(p2.id,'backfill')=0, 'recording twice writes nothing the second time');

  -- ---------------------------------------------------------------
  -- Access and validation
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_statutory_charges(current_date-1,current_date+1)','INS_FORBIDDEN','summary needs access');
  perform pg_temp.expect_error('select * from ins_report_statutory_charge_trace(current_date-1,current_date+1)','INS_FORBIDDEN','trace needs access');
  perform pg_temp.expect_error('select * from ins_report_statutory_charge_exceptions(current_date-1,current_date+1)','INS_FORBIDDEN','exceptions need access');
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_statutory_charges(public.ins_local_today()-1,public.ins_local_today()+1)),'another company sees none of our charges');
  perform pg_temp.assert((select count(*)=0 from ins_report_statutory_charge_trace(public.ins_local_today()-1,public.ins_local_today()+1)),'another company sees no trace rows of ours');
  perform pg_temp.assert((select count(*)=0 from ins_policy_charge_allocations),'another company cannot read our allocations');
  reset role;
  set local role anon;
  perform pg_temp.expect_error('select * from ins_report_statutory_charges(current_date-1,current_date+1)','permission denied','anonymous cannot run the summary');
  reset role;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_statutory_charges(null,current_date)','INS_REPORT_INPUT','a period is required');
  perform pg_temp.expect_error('select * from ins_report_statutory_charges(current_date,current_date-1)','INS_REPORT_INPUT','the period must run forwards');
  perform pg_temp.expect_error('select * from ins_report_statutory_charges(current_date-1,current_date+1,''bogus'')','INS_REPORT_INPUT','grouping must be one offered');
  reset role;

  -- ---------------------------------------------------------------
  -- Summary before any cash: assessed only
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=1 and min(assessed)=1166.67 and min(collected)=0 and min(remitted)=0
                            and min(uncollected)=1166.67 and min(policy_count)=3 and min(remitter)='insurer' and min(group_key)='UG_INSURANCE_TRAINING_LEVY'
                            from ins_report_statutory_charges(public.ins_local_today(),public.ins_local_today())),
    'by charge: 500 + 500 + 166.67 assessed on three policies, nothing collected, the insurer remits');
  perform pg_temp.assert((select assessed=900.00 from ins_report_statutory_charges(public.ins_local_today(),public.ins_local_today(),'insurer') where group_label='Alpha')
                         and (select assessed=266.67 from ins_report_statutory_charges(public.ins_local_today(),public.ins_local_today(),'insurer') where group_label='Beta'),
    'by insurer: Alpha 500 + 300 + 100.00 and Beta 200 + 66.67');
  perform pg_temp.assert((select count(*)=0 from ins_report_statutory_charges(public.ins_local_today()-10,public.ins_local_today()-1)),
    'a period before the policies were bound shows nothing');
  perform pg_temp.assert((select count(*)=5 from ins_report_statutory_charge_trace(public.ins_local_today(),public.ins_local_today()) where stage='assessed'),
    'the trace lists five assessed allocations: 1 + 2 + 2');
  reset role;

  -- ---------------------------------------------------------------
  -- A real receipt and a real remittance on p1
  -- ---------------------------------------------------------------
  select amount into v_t1 from fin_open_items where source_type='ins_policy_premium' and source_id=p1.id;
  perform pg_temp.assert(v_t1 = 100500, 'p1 invoice is the premium plus the levy');
  perform pg_temp.jwt(maker); set local role authenticated;
  q := ins_submit_policy_cash_request(p1.id,'receipt',trust,33333,public.ins_local_today(),gen_random_uuid(),'STAT-001','partial client collection');
  perform pg_temp.jwt(checker);
  q := ins_decide_policy_cash_request(q.id,'approve');
  perform pg_temp.jwt(maker);
  q := ins_submit_policy_share_cash_request(p1.id,(select id from ins_policy_insurer_shares where policy_id=p1.id and insurer_id=alpha),trust,20000,public.ins_local_today(),gen_random_uuid());
  perform pg_temp.jwt(checker);
  q := ins_decide_policy_cash_request(q.id,'approve');
  reset role;

  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select amount=165.84 and basis like 'pro rata: receipt 33333%' and settlement_no is not null
                            from ins_report_statutory_charge_trace(public.ins_local_today(),public.ins_local_today())
                           where stage='collected' and policy_id=p1.id),
    'receipt of 33,333 collects 33,333 x 500 / 100,500 = 165.84 of the levy, with its basis written out');
  perform pg_temp.assert((select amount=110.50 and basis like 'pro rata: remittance 20000%'
                            from ins_report_statutory_charge_trace(public.ins_local_today(),public.ins_local_today())
                           where stage='remitted' and policy_id=p1.id),
    'remittance of 20,000 covers 20,000 x 500 / 90,500 = 110.50 of the levy');
  perform pg_temp.assert((select collected=165.84 and remitted=110.50 and uncollected=1000.83 and held_unremitted=55.34 and assessed=1166.67
                            from ins_report_statutory_charges(public.ins_local_today(),public.ins_local_today())),
    'summary: collected 165.84, remitted 110.50, uncollected 1,000.83, held 55.34');
  perform pg_temp.assert((select sum(amount) filter (where stage='collected')=165.84 and sum(amount) filter (where stage='remitted')=110.50
                            from ins_report_statutory_charge_trace(public.ins_local_today(),public.ins_local_today())),
    'the summary is the sum of the trace');
  reset role;

  -- ---------------------------------------------------------------
  -- A receipt split across two insurer allocations adds up to the whole
  -- ---------------------------------------------------------------
  select amount into v_t3 from fin_open_items where source_type='ins_policy_premium' and source_id=p3.id;
  perform pg_temp.jwt(maker); set local role authenticated;
  q := ins_submit_policy_cash_request(p3.id,'receipt',trust,12345,public.ins_local_today(),gen_random_uuid(),'STAT-002','part payment');
  perform pg_temp.jwt(checker);
  q := ins_decide_policy_cash_request(q.id,'approve');
  reset role;
  select 12345 * a.amount / v_t3 into v_exact_a from ins_policy_charge_allocations a where a.policy_id=p3.id and a.insurer_id=alpha;
  select 12345 * a.amount / v_t3 into v_exact_b from ins_policy_charge_allocations a where a.policy_id=p3.id and a.insurer_id=beta;
  v_sum_exact := v_exact_a + v_exact_b;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=2 and sum(amount)=round(v_sum_exact,2)
                            from ins_report_statutory_charge_trace(public.ins_local_today(),public.ins_local_today())
                           where stage='collected' and policy_id=p3.id),
    'one receipt over two insurer allocations: the parts add up to the rounded whole');
  perform pg_temp.assert((select bool_and(amount >= trunc(case when insurer_id=alpha then v_exact_a else v_exact_b end,2)
                                      and amount <= trunc(case when insurer_id=alpha then v_exact_a else v_exact_b end,2) + 0.01)
                            from ins_report_statutory_charge_trace(public.ins_local_today(),public.ins_local_today())
                           where stage='collected' and policy_id=p3.id),
    'and each part is within one cent of its exact share');
  reset role;

  -- ---------------------------------------------------------------
  -- Reconciliation
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_statutory_charge_exceptions(public.ins_local_today(),public.ins_local_today())),
    'exceptions: everything ties, so nothing is listed');
  reset role;
  -- The shares are locked after bind, correctly. To prove the reconciliation catches a booked
  -- amount that no longer matches the record, switch the table's triggers off for this one write
  -- (the table owner may; no superuser setting is needed).
  alter table ins_policy_insurer_shares disable trigger user;
  update ins_policy_insurer_shares set pass_through_amount = pass_through_amount + 1
   where policy_id = p2.id and insurer_id = alpha;
  alter table ins_policy_insurer_shares enable trigger user;
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=1 and min(check_name)='allocation' and min(policy_no)=p2.policy_no and min(difference)=-1
                            from ins_report_statutory_charge_exceptions(public.ins_local_today(),public.ins_local_today())
                           where check_name='allocation'),
    'exceptions: a booked pass-through that differs from the allocations names the policy and the difference');
  reset role;

  raise notice 'PASS: ins_statutory_charge_trace (allocation rows, cent rule, immutability, backfill, access, validation, summary, pro rata collection and remittance, split receipt, reconciliation)';
end $$;

rollback;
