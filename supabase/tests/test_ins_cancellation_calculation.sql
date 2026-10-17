-- Cancellation calculation only: standalone fixtures; no cancellation or cash posting.
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
  reconciler uuid:=gen_random_uuid(); manager uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); other_fin uuid:=gen_random_uuid();
  trust_gl uuid; bank_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  trust uuid; operating uuid; otherbank uuid; line_id uuid; insurer uuid; premium_item uuid; payable_item uuid;
  c ins_clients%rowtype; p ins_policies%rowtype; p2 ins_policies%rowtype; draft ins_policies%rowtype;
  q ins_policy_cash_requests%rowtype; retry ins_policy_cash_requests%rowtype; outq ins_policy_cash_requests%rowtype;
  stale ins_policy_cash_requests%rowtype; rejected ins_policy_cash_requests%rowtype; broken ins_policy_cash_requests%rowtype;
  bankq ins_policy_cash_requests%rowtype; v jsonb; n integer; j integer; rec bank_reconciliations%rowtype;
  key uuid:=gen_random_uuid(); receipt_line uuid; payment_line uuid; rec2 uuid;
  beta uuid; fee_gl uuid; tax_gl uuid; a uuid; b uuid; config jsonb; charge_config jsonb; snap jsonb; jbefore integer;
  q1 ins_policy_cash_requests%rowtype; q2 ins_policy_cash_requests%rowtype; qa ins_policy_cash_requests%rowtype; qb ins_policy_cash_requests%rowtype;
  renewed ins_policies%rowtype; zero_policy ins_policies%rowtype; rollback_policy ins_policies%rowtype; commission_a uuid; commission_b uuid;
  cn ins_claims%rowtype; transfer_row ins_commission_transfers%rowtype; report jsonb; expected numeric; terms_input jsonb; charge_input jsonb; quote jsonb; before_journals integer; before_settlements integer;
begin
  insert into tenants(id,name) values(ta,'Premium cash test A'),(tb,'Premium cash test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'premium-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[maker,checker,reconciler,manager,outsider,other_fin]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,case when u=other_fin then tb else ta end,'Premium cash test actor','premium-'||u||'@test.local'
    from unnest(array[maker,checker,reconciler,manager,outsider,other_fin]) u;
  insert into finance_team_members(tenant_id,user_id,role) values(ta,maker,'finance'),(ta,checker,'finance'),(ta,reconciler,'finance'),(tb,other_fin,'finance');
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
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id) values(ta,'PREMIUM-TRUST','client_money','UGX',trust_gl) returning id into trust;
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id) values(ta,'PREMIUM-OPERATING','operating','UGX',bank_gl) returning id into operating;
  insert into fin_bank_accounts(tenant_id,name,kind,currency) values(tb,'OTHER-TRUST','operating','UGX') returning id into otherbank;
  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MOTOR','Motor') returning id into line_id;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c:=ins_register_client('Premium cash client','corporate',null,null,null,'low');
  p:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  perform pg_temp.motor_cert(p.id); p:=ins_bind_policy(p.id);
  p2:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  perform pg_temp.motor_cert(p2.id); p2:=ins_bind_policy(p2.id);
  draft:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  reset role;
  select id into premium_item from fin_open_items where source_id=p.id and source_type='ins_policy_premium';
  select id into payable_item from fin_open_items where source_id=p.id and source_type='ins_policy_insurer';

  perform pg_temp.assert((select count(*) from fin_open_items where source_id=p.id)=2,'legacy bind still creates exactly two open items');
  perform pg_temp.assert((select count(*) from journal_entry_lines where journal_entry_id=p.journal_entry_id)=3,'legacy bind journal is unchanged');
  perform pg_temp.assert((select not extended from ins_policy_financial_snapshots where policy_id=p.id),'legacy snapshot does not select the extended engine');
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4010','Broker fee income','revenue') returning id into fee_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2100','Output VAT liability','liability') returning id into tax_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values(ta,'vat_output',tax_gl);
  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_insurers(tenant_id,code,name,claim_payment_mode) values(ta,'BETA','Beta co-insurer','via_broker') returning id into beta;
  config:=jsonb_build_array(jsonb_build_object('insurer_id',insurer,'is_lead',true,'share_pct',60,'commission_rate_pct',10,'insurer_policy_no','A-001','reviewed',true),
    jsonb_build_object('insurer_id',beta,'is_lead',false,'share_pct',40,'commission_rate_pct',20,'insurer_policy_no','B-001','reviewed',true));
  charge_config:=jsonb_build_array(
    jsonb_build_object('kind','insurer_pass_through','description','All insurers charge','amount',100,'recipient_mode','all_insurers','vat_mode','not_calculated','reviewed',true),
    jsonb_build_object('kind','insurer_pass_through','description','Beta only charge','amount',50,'recipient_mode','one_insurer','recipient_insurer_id',beta,'vat_mode','not_calculated','reviewed',true),
    jsonb_build_object('kind','broker_fee','description','Broker service fee','amount',50,'recipient_mode','broker','income_gl_account_id',fee_gl,'vat_mode','exclusive','vat_rate_pct',18,'reviewed',true));
  -- 18% here is only a test value, NOT a configured/default statutory rate.
  perform pg_temp.expect_error(format('select ins_set_policy_financial_configuration(%L,%L::jsonb,''[]''::jsonb)',draft.id,
    jsonb_set(config,'{0,share_pct}','59')),'INS_SHARE_TOTAL','shares must total exactly 100');
  perform pg_temp.expect_error(format('select ins_set_policy_financial_configuration(%L,%L::jsonb,''[]''::jsonb)',draft.id,
    jsonb_set(config,'{1,is_lead}','true')),'INS_SHARE_TOTAL','two leads are rejected');
  perform pg_temp.expect_error(format('select ins_set_policy_financial_configuration(%L,%L::jsonb,%L::jsonb)',draft.id,config,
    jsonb_set(charge_config,'{1,recipient_insurer_id}',to_jsonb(gen_random_uuid()::text))),'INS_CHARGE_RECIPIENT','charge recipient must participate');
  perform ins_set_policy_financial_configuration(draft.id,config,charge_config);
  perform pg_temp.expect_state(format('update ins_policy_insurer_shares set share_pct=1 where policy_id=%L',draft.id),'42501','no direct configuration DML');
  perform pg_temp.motor_cert(draft.id); draft:=ins_bind_policy(draft.id);
  reset role;
  select id into a from ins_policy_insurer_shares where policy_id=draft.id and insurer_id=insurer;
  select id into b from ins_policy_insurer_shares where policy_id=draft.id and insurer_id=beta;
  select snapshot into snap from ins_policy_financial_snapshots where policy_id=draft.id;
  perform pg_temp.assert((select invoice_total=1209 and broker_fee_total=50 and vat_total=9 from ins_policy_financial_snapshots where policy_id=draft.id),'premium plus charges plus explicit fee VAT');
  perform pg_temp.assert(draft.commission_amount=140 and draft.net_premium_to_insurer=860,'policy header remains premium-only; charge payables are separate');
  perform pg_temp.assert((select premium_amount=600 and pass_through_amount=60 and commission_amount=60 and payable_amount=600 from ins_policy_insurer_shares where id=a),'lead receives its premium and pro-rata charge, commission excludes charges');
  perform pg_temp.assert((select premium_amount=400 and pass_through_amount=90 and commission_amount=80 and payable_amount=410 from ins_policy_insurer_shares where id=b),'Beta receives pro-rata plus specifically assigned charge');
  perform pg_temp.assert((select count(*) from fin_open_items where source_type='ins_policy_share_insurer' and source_id in(a,b))=2,'one Finance payable per participating insurer');
  perform pg_temp.assert((select sum(debit-credit) from journal_entry_lines where journal_entry_id=draft.journal_entry_id)=0,'extended bind journal balances');
  perform pg_temp.assert((select sum(debit) from journal_entry_lines where journal_entry_id=draft.journal_entry_id and gl_account_id=ar_gl)=1209,'client AR includes all invoice components');
  perform pg_temp.assert((select sum(credit) from journal_entry_lines where journal_entry_id=draft.journal_entry_id and gl_account_id=tax_gl)=9,'VAT posts to tax liability');
  perform pg_temp.assert((select sum(credit) from journal_entry_lines where journal_entry_id=draft.journal_entry_id and gl_account_id=fee_gl)=50,'broker fee posts separately to explicit income GL');
  select id into commission_a from ins_commission_entries where insurer_share_id=a;
  select id into commission_b from ins_commission_entries where insurer_share_id=b;
  perform pg_temp.assert(commission_a is not null and commission_b is not null,'separate deferred commission entries');
  raise notice 'PASS: unchanged legacy engine, exact shares/lead/recipients, per-insurer payables, charge segregation and optional VAT posting';

  -- All amounts are server-derived from the immutable bound allocation.
  terms_input:=jsonb_build_array(
   jsonb_build_object('insurer_id',insurer,'terms',jsonb_build_object('method','manual_review','contract_reference','Alpha agreed cancellation terms','manual_return_premium','300')),
   jsonb_build_object('insurer_id',beta,'terms',jsonb_build_object('method','manual_review','contract_reference','Beta agreed cancellation terms','manual_return_premium','200')));
  select jsonb_agg(jsonb_build_object('charge_id',ch.id,'refund_amount',round(ch.amount/2,2)::text,'legal_basis_confirmed',true,'basis','Contractual half refund confirmed',
    'insurer_refunds',case when ch.kind='broker_fee' then null else
      (select jsonb_agg(jsonb_build_object('insurer_id',sh.insurer_id,'refund_amount',
       round(case when ch.recipient_mode='one_insurer' then ch.amount else ch.amount*sh.share_pct/100 end/2,2)::text,'basis','Recipient contract permits half refund'))
       from ins_policy_insurer_shares sh where sh.policy_id=ch.policy_id and (ch.recipient_mode='all_insurers' or sh.insurer_id=ch.recipient_insurer_id)) end))
   into charge_input from ins_policy_charges ch where ch.policy_id=draft.id;
  select count(*) into before_journals from journal_entries;
  select count(*) into before_settlements from fin_settlements;
  perform pg_temp.jwt(maker); set local role authenticated;
  quote:=ins_preview_policy_cancellation(draft.id,current_date,terms_input,charge_input);
  perform pg_temp.assert(quote->>'invoice_credit'='604.50','return premium, charges, broker fee and original VAT reconcile');
  perform pg_temp.assert((quote->>'receivable_credit')::numeric=604.5 and (quote->>'client_refund_due')::numeric=0,'uncollected premiums produce a receivable credit, not cash refund');
  perform pg_temp.assert(quote->>'stage'='calculation_only' and not (quote->>'payment_authorized')::boolean and quote->>'funding_status'='not_checked','calculation cannot authorize a cancellation or payment');
  perform pg_temp.assert((quote->>'requires_finance_exception')::boolean,'client input cannot approve manual exceptions');
  perform pg_temp.assert((select (x->>'commission_clawback')::numeric=30 and (x->>'pass_through_refund')::numeric=30 and (x->>'total_insurer_credit')::numeric=300 from jsonb_array_elements(quote->'insurers') x where x->>'insurer_id'=insurer::text),'Alpha uses original 10 percent commission and actual charge recipients');
  perform pg_temp.assert((select (x->>'commission_clawback')::numeric=40 and (x->>'pass_through_refund')::numeric=45 and (x->>'total_insurer_credit')::numeric=205 from jsonb_array_elements(quote->'insurers') x where x->>'insurer_id'=beta::text),'Beta uses original 20 percent commission and includes its dedicated pass-through');
  select jsonb_agg(case when x->>'charge_id'=(select id::text from ins_policy_charges where policy_id=draft.id and recipient_mode='all_insurers') then
   jsonb_set(jsonb_set(x,'{refund_amount}','"60"'),'{insurer_refunds}',jsonb_build_array(
    jsonb_build_object('insurer_id',insurer,'refund_amount','60','basis','Alpha full refund allowed'),
    jsonb_build_object('insurer_id',beta,'refund_amount','0','basis','Beta charge non-refundable'))) else x end)
   into v from jsonb_array_elements(charge_input) x;
  report:=ins_preview_policy_cancellation(draft.id,current_date,terms_input,v);
  perform pg_temp.assert((select (x->>'pass_through_refund')::numeric=60 from jsonb_array_elements(report->'insurers') x where x->>'insurer_id'=insurer::text)
   and (select (x->>'pass_through_refund')::numeric=25 from jsonb_array_elements(report->'insurers') x where x->>'insurer_id'=beta::text),'recipient-specific terms override a pooled proportional charge refund');
  perform pg_temp.assert((select (x->>'refund_vat')::numeric=4.5 from jsonb_array_elements(quote->'charges') x where x->>'kind'='broker_fee'),'VAT credit follows original charged VAT, not a current rate');
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date,%L::jsonb,''[]''::jsonb)',draft.id,terms_input),'INS_CANCELLATION_REVIEW_REQUIRED','every charge requires explicit refund/retention decision');
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date,''[]''::jsonb,%L::jsonb)',draft.id,charge_input),'INS_CANCELLATION_REVIEW_REQUIRED','every original insurer requires its own terms');
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date+1,%L::jsonb,%L::jsonb)',draft.id,terms_input,charge_input),'INS_CANCELLATION_INPUT','future cancellations not treated as current');
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date,%L::jsonb,%L::jsonb)',draft.id,terms_input,jsonb_set(charge_input,'{0,legal_basis_confirmed}','false')),'INS_CANCELLATION_REVIEW_REQUIRED','charge retention/refund basis requires confirmation');
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date,%L::jsonb,%L::jsonb)',draft.id,terms_input,jsonb_set(charge_input,'{0,refund_amount}','"9999"')),'INS_CANCELLATION_INPUT','charge over-refund blocked');
  reset role;
  perform pg_temp.assert((select count(*) from journal_entries)=before_journals and (select count(*) from fin_settlements)=before_settlements,'preview creates neither journals nor settlements');
  perform pg_temp.assert((select snapshot from ins_policy_financial_snapshots where policy_id=draft.id)=snap and (select status from ins_policies where id=draft.id)='active','original policy and snapshots remain unchanged');

  -- Stale previews are not durable promises: each call uses actual collections.
  perform pg_temp.jwt(maker); set local role authenticated;
  q:=ins_submit_policy_cash_request(draft.id,'receipt',trust,604.5,current_date,gen_random_uuid(),'Partial collection');
  perform pg_temp.jwt(checker);
  q:=ins_decide_policy_cash_request(q.id,'approve',null);
  quote:=ins_preview_policy_cancellation(draft.id,current_date,terms_input,charge_input);
  perform pg_temp.assert((quote->>'receivable_credit')::numeric=604.5 and (quote->>'client_refund_due')::numeric=0,'half paid, half credited leaves no cash refund');
  perform pg_temp.jwt(maker);
  q:=ins_submit_policy_cash_request(draft.id,'receipt',trust,604.5,current_date,gen_random_uuid(),'Remaining collection');
  perform pg_temp.jwt(checker);
  q:=ins_decide_policy_cash_request(q.id,'approve',null);
  quote:=ins_preview_policy_cancellation(draft.id,current_date,terms_input,charge_input);
  perform pg_temp.assert((quote->>'receivable_credit')::numeric=0 and (quote->>'client_refund_due')::numeric=604.5 and not (quote->>'payment_authorized')::boolean,'fully collected policy has refund liability estimate, not automatic payment authority');
  perform pg_temp.expect_state('select platform_ins_cancellation_money(''1'')','42501','private money helper not executable by client');
  perform pg_temp.expect_state(format('select platform_ins_calculate_insurer_cancellation(''{}'',''{}'',current_date,current_date,current_date)'),'42501','private calculator cannot bypass authorized RPC');
  perform pg_temp.jwt(outsider);
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date,%L::jsonb,%L::jsonb)',draft.id,terms_input,charge_input),'INS_FORBIDDEN','ordinary unauthorized actor denied');
  perform pg_temp.jwt(other_fin);
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date,%L::jsonb,%L::jsonb)',draft.id,terms_input,charge_input),'INS_NOT_FOUND','cross-tenant Finance cannot access a policy');
  reset role;
  set local role anon;
  perform pg_temp.expect_state(format('select ins_preview_policy_cancellation(%L,current_date,''[]'',''[]'')',draft.id),'42501','anonymous preview denied');
  reset role;
  perform pg_temp.jwt(manager); set local role authenticated;
  cn:=ins_create_claim(draft.id,current_date,current_date,'Existing claim blocks cancellation',null,100);
  perform pg_temp.expect_error(format('select ins_preview_policy_cancellation(%L,current_date,%L::jsonb,%L::jsonb)',draft.id,terms_input,charge_input),'INS_CANCELLATION_CLAIM','any existing claim blocks cancellation v1');
  reset role;
  -- Original restricted reversal remains restricted.
  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''No alternate cancellation bypass'',false,%L)',draft.id,gen_random_uuid()),'INS_REVERSAL_COMPLEX','new preview does not weaken original reversal protection');
  reset role;
  raise notice 'PASS: exact insurer-specific cancellation estimates, explicit charge decisions, original VAT, credit/cash distinction, permissions and claim block; no posting/payment authority';
end $$;
rollback;
