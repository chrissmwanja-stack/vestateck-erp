-- Insurance reports, batch 2 (20261121100000): commission earned, commission
-- receivable.
--
-- The point of this file is the tie-out. Commission earned is compared with the
-- movement on the commission income account in the ledger.
--
-- Covers: access (no role, other company, anonymous); input validation; deferred
-- commission is NOT earned (the default mode defers to insurer settlement);
-- commission earned at placement shows in the period and ties to the ledger;
-- grouping; the period window; the bucket columns add up to the total; the total
-- still ties to the ledger after a posted cancellation; commission receivable is
-- empty under the net settlement basis.
--
-- NOT covered here (implemented, but no scenario yet): commission recognised on
-- insurer settlement or on premium collection and its reversal, endorsement
-- commission, imported policies and opening balances (excluded by default),
-- and commission receivable WITH rows. That needs the gross settlement basis
-- fixture in test_ins_settlement_basis.sql. The as-at and void-after-the-date
-- rules were exercised against a stub schema when the function was written,
-- not against this stack.
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

-- Commission income balance (credits less debits), counting a voided entry and
-- its reversal together so a void nets to zero instead of double counting.
create function pg_temp.income_balance(p_gl uuid) returns numeric language sql as $$
  select coalesce(sum(l.credit - l.debit), 0)
    from public.journal_entry_lines l
   where l.gl_account_id = p_gl;
$$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  maker uuid := gen_random_uuid(); checker uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid(); outsider uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  clearing uuid; ap_gl uuid; line_id uuid; line2 uuid; insurer uuid;
  c ins_clients%rowtype; p1 ins_policies%rowtype; p2 ins_policies%rowtype;
  cx ins_policy_cancellations%rowtype;
  r record; terms jsonb;
begin
  insert into tenants(id,name) values(ta,'Commission reports test A'),(tb,'Commission reports test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'crep-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[maker,checker,mgr,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u, case when u=other_mgr then tb else ta end, 'Reports actor', 'crep-'||u||'@test.local'
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
  c := ins_register_client('Commission reports client','corporate',null,null,null,'low');

  -- p1 keeps the default mode: commission (10% of 1,000 = 100) is DEFERRED at bind.
  p1 := ins_create_policy(c.id,insurer,line_id,public.ins_local_today(),public.ins_local_today()+365,50000,'UGX',1000,10,null,null);
  p1 := pg_temp.approve_and_bind(p1.id);

  -- p2 is set to earn its commission at placement (10% of 600 = 60) before it is approved.
  p2 := ins_create_policy(c.id,insurer,line2,public.ins_local_today(),public.ins_local_today()+365,30000,'UGX',600,10,null,null);
  perform ins_set_policy_commission_recognition(p2.id,'at_placement');
  p2 := pg_temp.approve_and_bind(p2.id);
  reset role;

  -- ---------------------------------------------------------------
  -- Access
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today())','INS_FORBIDDEN','earned needs insurance access');
  perform pg_temp.expect_error('select * from ins_report_commission_receivable(public.ins_local_today())','INS_FORBIDDEN','receivable needs insurance access');
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today())','INS_POSTING_RULE_MISSING','another company has no commission income rule, so it sees none of ours');
  reset role;
  set local role anon;
  perform pg_temp.expect_error('select * from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today())','permission denied','anonymous cannot run the earned report');
  perform pg_temp.expect_error('select * from ins_report_commission_receivable(public.ins_local_today())','permission denied','anonymous cannot run the receivable report');
  reset role;

  -- ---------------------------------------------------------------
  -- Input validation
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_report_commission_earned(public.ins_local_today()+1,public.ins_local_today())','INS_REPORT_INPUT','period must run forwards');
  perform pg_temp.expect_error('select * from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today(),''insurer'')','INS_REPORT_INPUT','insurer grouping is not offered yet');
  perform pg_temp.expect_error('select * from ins_report_commission_receivable(null)','INS_REPORT_INPUT','an as-at date is required');
  reset role;

  -- ---------------------------------------------------------------
  -- Earned: only the at-placement policy, and it ties to the ledger
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=1 and sum(placement)=60 and sum(net_earned)=60 and sum(policy_count)=1
                            from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today(),'month')),
    'only the at-placement commission is earned: 60 on one policy; the deferred 100 is not income');
  perform pg_temp.assert((select count(*)=1 and min(group_label)='Marine' and sum(net_earned)=60
                            from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today(),'product_line')),
    'grouped by product line: only Marine earned');
  perform pg_temp.assert((select count(*)=1 and sum(net_earned)=60 from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today(),'client')),
    'grouped by client: one row');
  perform pg_temp.assert((select count(*)=0 from ins_report_commission_earned(public.ins_local_today()+1,public.ins_local_today()+2)),'nothing earned outside the period');
  reset role;
  perform pg_temp.assert(pg_temp.income_balance(income_gl)=60,'the ledger holds 60 of commission income');
  perform pg_temp.jwt(mgr); set local role authenticated;
  select sum(net_earned) as net into r from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today(),'month',true);
  reset role;
  perform pg_temp.assert(r.net = pg_temp.income_balance(income_gl),
    'with imported policies included, earned equals the commission income ledger');

  -- ---------------------------------------------------------------
  -- After a posted cancellation: whatever it does to income, the report follows the ledger
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
  select sum(net_earned) as net, sum(placement+recognised+reversed+cancellations+endorsements+other) as parts into r
    from ins_report_commission_earned(public.ins_local_today(),public.ins_local_today(),'month',true);
  reset role;
  perform pg_temp.assert(r.net = pg_temp.income_balance(income_gl),'after the cancellation, earned still equals the commission income ledger');
  perform pg_temp.assert(r.net = r.parts,'the bucket columns add up to the net earned');

  -- ---------------------------------------------------------------
  -- Receivable: the default settlement basis is net, so nothing is owed by insurers
  -- ---------------------------------------------------------------
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform pg_temp.assert((select count(*)=0 from ins_report_commission_receivable(public.ins_local_today())),
    'under the net basis the broker withholds commission, so no insurer owes any');
  reset role;

  raise notice 'PASS: ins_reports_batch2 (access, validation, earned at placement, ledger tie-out, cancellation, receivable empty on net basis)';
end $$;

rollback;
