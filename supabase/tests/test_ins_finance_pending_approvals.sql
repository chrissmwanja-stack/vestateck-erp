-- ins_finance_pending_approvals(): the Finance worklist of premium cash requests,
-- cancellation cash requests and open cancellation cases waiting for a decision.
-- Covers: Finance-only access (Insurance manager, outsider and anon refused), tenant isolation,
-- only pending items listed (decided ones drop off), is_mine for maker and proposer, amounts and
-- currency, and oldest-first order.
-- Run only on a disposable local/test database; every fixture rolls back.
\set ON_ERROR_STOP on
begin;

-- Test fixture: a motor policy needs an issued certificate before it binds.
-- No-op unless the caller manages insurance, the policy is a draft on the MOTOR line,
-- and no certificate is attached yet.
create function pg_temp.motor_cert(p_policy uuid) returns void
language plpgsql as $$
declare pol ins_policies%rowtype; line_code text; r uuid; s text := replace(p_policy::text, '-', '');
begin
  if not can_manage_insurance() then return; end if;
  select * into pol from ins_policies where id = p_policy;
  if not found or pol.status <> 'draft' then return; end if;
  select code into line_code from ins_product_lines where id = pol.product_line_id;
  if line_code is distinct from 'MOTOR' then return; end if;
  if exists (select 1 from ins_certificate_stock where policy_id = p_policy and status = 'issued') then return; end if;
  r := ins_register_risk(pol.client_id, pol.product_line_id, 'vehicle', 'Test vehicle', null, 'CH' || s, null, null, null, null, 0);
  perform ins_load_certificate_range('C' || s || '-', 1, 1, 4);
  perform ins_issue_certificate('C' || s || '-0001', r, null);
  perform ins_link_policy_risk(p_policy, r);
  perform ins_attach_certificate(p_policy, 'C' || s || '-0001');
end $$;
create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
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

-- Runs a statement that must fail with the given SQLSTATE (for RLS denials,
-- whose message text is not stable).
create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      return;
    end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
end $$;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

-- Acts as a user for the rest of the transaction (role switching stays inline).
create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  ta uuid:=gen_random_uuid(); tb uuid:=gen_random_uuid(); maker uuid:=gen_random_uuid(); checker uuid:=gen_random_uuid();
  manager uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); other_fin uuid:=gen_random_uuid();
  trust_gl uuid; bank_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  trust uuid; line_id uuid; insurer uuid; canc uuid; canc_cash uuid;
  c ins_clients%rowtype; p ins_policies%rowtype;
  q1 ins_policy_cash_requests%rowtype; q2 ins_policy_cash_requests%rowtype; r record; n integer;
begin
  insert into tenants(id,name) values(ta,'Pending approvals A'),(tb,'Pending approvals B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'pending-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[maker,checker,manager,outsider,other_fin]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,case when u=other_fin then tb else ta end,
           case when u=maker then 'Maker Mary' when u=checker then 'Checker Charles' else 'Pending test actor' end,
           'pending-'||u||'@test.local'
    from unnest(array[maker,checker,manager,outsider,other_fin]) u;
  insert into finance_team_members(tenant_id,user_id,role) values(ta,maker,'finance'),(ta,checker,'finance'),(tb,other_fin,'finance');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values(ta,manager,'insurance','manager');
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1000','Operating','asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1020','Client money','asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1100','AR','asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2010','Insurer payable','liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2020','Unearned commission','liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4000','Commission income','revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values
    (ta,'bank',bank_gl),(ta,'client_money_bank',trust_gl),(ta,'ar_control',ar_gl),
    (ta,'insurer_payable',pay_gl),(ta,'unearned_commission',unearned_gl),(ta,'commission_income',income_gl);
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id) values(ta,'PENDING-TRUST','client_money','UGX',trust_gl) returning id into trust;
  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'GEN','General') returning id into line_id;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha Assurance') returning id into insurer;
  c:=ins_register_client('Pending client','corporate',null,null,null,'low');
  p:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  p:=ins_bind_policy(p.id);
  reset role;

  -- Nothing waiting yet.
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_finance_pending_approvals())=0,'empty worklist when nothing is pending');

  -- A premium receipt prepared by the maker.
  q1:=ins_submit_policy_cash_request(p.id,'receipt',trust,400,current_date,gen_random_uuid(),'PEND-001','first receipt');
  select * into r from ins_finance_pending_approvals();
  perform pg_temp.assert(r.item_type='premium_cash' and r.item_id=q1.id and r.policy_id=p.id and r.policy_no=p.policy_no,'premium cash request listed with its policy');
  perform pg_temp.assert(r.client_name='Pending client' and r.insurer_name='Alpha Assurance' and r.currency='UGX','client, insurer and currency shown');
  perform pg_temp.assert(r.kind='receipt' and r.amount=400 and r.submitted_by_name='Maker Mary','kind, amount and maker shown');
  perform pg_temp.assert(r.is_mine,'the maker is told it is theirs');
  reset role;

  -- The checker sees the same item as theirs to decide.
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.assert((select not is_mine from ins_finance_pending_approvals() where item_id=q1.id),'the checker can decide it');
  -- A later request sorts after the earlier one.
  q2:=ins_submit_policy_cash_request(p.id,'receipt',trust,100,current_date,gen_random_uuid(),'PEND-002','second receipt');
  reset role;
  update ins_policy_cash_requests set created_at=now()+interval '1 minute' where id=q2.id;
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.assert((select array_agg(item_id order by ordinality) from ins_finance_pending_approvals() with ordinality)=array[q1.id,q2.id],'oldest first');
  reset role;

  -- An open cancellation case and a pending cancellation cash request.
  insert into ins_policy_cancellations(tenant_id,policy_id,request_key,reason,effective_date,insurer_terms,charge_refunds,proposed_by,calculation)
    values(ta,p.id,gen_random_uuid(),'Client asked to cancel',current_date,'[]','[]',checker,'{}') returning id into canc;
  perform pg_temp.jwt(maker); set local role authenticated;
  select * into r from ins_finance_pending_approvals() where item_type='cancellation';
  perform pg_temp.assert(r.item_id=canc and r.kind='proposed' and r.amount is null and r.submitted_by_name='Checker Charles' and not r.is_mine,'open cancellation case listed, decidable by a different Finance user');
  reset role;
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.assert((select is_mine from ins_finance_pending_approvals() where item_id=canc),'the proposer cannot decide their own cancellation');
  reset role;

  insert into ins_cancellation_cash_requests(tenant_id,cancellation_id,kind,bank_account_id,amount,cash_date,reference,notes,request_key,maker_id)
    values(ta,canc,'refund',trust,250,current_date,'REFUND-1','refund to client',gen_random_uuid(),maker) returning id into canc_cash;
  perform pg_temp.jwt(maker); set local role authenticated;
  select * into r from ins_finance_pending_approvals() where item_type='cancellation_cash';
  perform pg_temp.assert(r.item_id=canc_cash and r.kind='refund' and r.amount=250 and r.is_mine and r.policy_no=p.policy_no,'cancellation cash request listed with its policy');
  perform pg_temp.assert((select count(*) from ins_finance_pending_approvals())=4,'all four pending items listed');
  reset role;

  -- Decided items drop off.
  perform pg_temp.jwt(checker); set local role authenticated;
  perform ins_decide_policy_cash_request(q1.id,'approve');
  reset role;
  perform pg_temp.jwt(maker); set local role authenticated;
  perform ins_decide_policy_cash_request(q2.id,'reject','not wanted today');
  reset role;
  update ins_cancellation_cash_requests set status='cancelled',checker_id=null,checked_at=now(),decision_reason='withdrawn by maker' where id=canc_cash;
  update ins_policy_cancellations set status='withdrawn' where id=canc;
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_finance_pending_approvals())=0,'approved, rejected, cancelled and withdrawn items drop off');
  reset role;
  raise notice 'PASS: pending items listed with policy, amount, currency, maker and is_mine; decided items drop off';

  -- Access.
  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_finance_pending_approvals()','INS_CASH_FORBIDDEN','Insurance manager is not Finance');
  reset role;
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error('select * from ins_finance_pending_approvals()','INS_CASH_FORBIDDEN','outsider refused');
  reset role;
  perform pg_temp.jwt(maker); set local role anon;
  perform pg_temp.expect_state('select * from ins_finance_pending_approvals()','42501','anon cannot execute');
  reset role;
  -- Tenant isolation: another tenant's Finance user sees none of tenant A's items, even with items pending.
  insert into ins_policy_cancellations(tenant_id,policy_id,request_key,reason,effective_date,insurer_terms,charge_refunds,proposed_by,calculation)
    values(ta,p.id,gen_random_uuid(),'Still open for tenant A',current_date,'[]','[]',checker,'{}');
  perform pg_temp.jwt(other_fin); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_finance_pending_approvals())=0,'worklist is tenant isolated');
  reset role;
  raise notice 'PASS: Finance-only, Insurance manager/outsider/anon refused, tenant isolated';
end $$;

rollback;
