-- Cancellation approval/accounting: standalone fixtures; no cash execution.
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
  cn ins_claims%rowtype; transfer_row ins_commission_transfers%rowtype; report jsonb; expected numeric; terms_input jsonb; charge_input jsonb; quote jsonb; before_journals integer; before_settlements integer; cancellation ins_policy_cancellations%rowtype; retry_case ins_policy_cancellations%rowtype; clearing uuid; ap_gl uuid; before_credits integer; saved_case uuid; pending_cash uuid; late_case ins_policy_cancellations%rowtype;
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
  -- Dedicated clearing is deliberately not a posting role; existing role count stays unchanged.
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1199','Cancellation clearing','asset') returning id into clearing;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2090','Refund/AP control','liability') returning id into ap_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values(ta,'ap_control',ap_gl);
  perform pg_temp.jwt(manager); set local role authenticated;
  key:=gen_random_uuid();
  cancellation:=ins_submit_policy_cancellation(draft.id,current_date,terms_input,charge_input,'Insurer-approved cancellation',key);
  retry_case:=ins_submit_policy_cancellation(draft.id,current_date,terms_input,charge_input,'Insurer-approved cancellation',key);
  perform pg_temp.assert(cancellation.id=retry_case.id,'proposal retry returns same immutable proposal');
  perform pg_temp.expect_error(format('select ins_submit_policy_cancellation(%L,current_date,%L::jsonb,%L::jsonb,''Different payload'',%L)',draft.id,terms_input,charge_input,key),'INS_CANCELLATION_RETRY_CONFLICT','retry payload cannot change');
  perform pg_temp.expect_error(format('select ins_prepare_policy_cancellation(%L,%L)',cancellation.id,clearing),'INS_CASH_FORBIDDEN','Insurance cannot prepare Finance approval');
  perform pg_temp.jwt(maker);
  cancellation:=ins_prepare_policy_cancellation(cancellation.id,clearing);
  perform pg_temp.expect_error(format('select ins_decide_policy_cancellation(%L,''approve'',''Self review forbidden'',true)',cancellation.id),'INS_CANCELLATION_SELF_APPROVAL','Finance preparer cannot approve');
  perform pg_temp.jwt(checker);
  perform pg_temp.expect_error(format('select ins_decide_policy_cancellation(%L,''approve'',''Reviewed contract terms'',false)',cancellation.id),'INS_CANCELLATION_EXCEPTION','manual exception needs explicit independent acceptance');
  reset role;
  -- CANCELLATION_POSTING_FIXTURE_READY: prepared, fully collected co-insurance proposal.
  select count(*) into before_journals from journal_entries;
  select count(*) into before_settlements from fin_settlements;
  select count(*) into before_credits from fin_credit_notes;
  perform pg_temp.jwt(checker); set local role authenticated;
  cancellation:=ins_decide_policy_cancellation(cancellation.id,'approve','Reviewed insurer contract and charge terms',true);
  retry_case:=ins_decide_policy_cancellation(cancellation.id,'approve','Reviewed insurer contract and charge terms',true);
  perform pg_temp.assert(cancellation.id=retry_case.id and cancellation.status='posted','approval retry is idempotent');
  reset role;
  perform pg_temp.assert((select status='cancelled' from ins_policies where id=draft.id),'policy cancelled only after independent posting');
  perform pg_temp.assert((select snapshot from ins_policy_financial_snapshots where policy_id=draft.id)=snap,'bind-time financial snapshot remains immutable');
  perform pg_temp.assert((select count(*) from fin_settlements)=before_settlements,'cancellation approval does not pay cash');
  perform pg_temp.assert((select count(*) from fin_credit_notes)=before_credits+2,'each unpaid insurer payable receives a linked credit');
  perform pg_temp.assert((select amount=604.5 and control_role='ap_control' from fin_open_items where id=cancellation.refund_item_id),'full client collections produce separate refund liability');
  perform pg_temp.assert((select count(*)=2 and sum(payable_credit)=505 and sum(recovery_due)=0 and sum(retained_commission)=70 from ins_cancellation_insurer_adjustments where cancellation_id=cancellation.id),'independent insurer credits and retained commissions reconcile');
  perform pg_temp.assert((select sum(l.debit-l.credit)=0 from ins_cancellation_journals j join journal_entry_lines l on l.journal_entry_id=j.journal_entry_id where j.cancellation_id=cancellation.id and l.gl_account_id=clearing),'cancellation clearing nets exactly zero');
  perform pg_temp.assert((select sum(debit)=4.5 from journal_entry_lines where journal_entry_id=cancellation.journal_entry_id and gl_account_id=tax_gl),'VAT liability credited at original charged tax fraction');
  perform pg_temp.assert((select sum(amount)=140 from ins_commission_entries where policy_id=draft.id),'original commission entry history is not rewritten');
  perform pg_temp.assert((select sum(amount)=70 from ins_commission_ledger where policy_id=draft.id),'commission reporting projects retained commission');
  perform pg_temp.assert(not exists(select 1 from ins_cancellation_journals j join journal_entries e on e.id=j.journal_entry_id where j.cancellation_id=cancellation.id and e.entry_date<>current_date),'all cancellation journals use current accounting date');
  perform pg_temp.expect_error(format('update ins_policy_cancellations set reason=''Changed history'' where id=%L',cancellation.id),'INS_CANCELLATION_IMMUTABLE','posted evidence immutable even to owner');
  perform pg_temp.expect_error(format('update ins_policy_insurer_shares set commission_amount=0 where policy_id=%L',draft.id),'INS_FINANCIAL_IMMUTABLE','original share remains immutable');
  perform pg_temp.expect_error(format('delete from ins_cancellation_insurer_adjustments where cancellation_id=%L',cancellation.id),'INS_CANCELLATION_IMMUTABLE','adjustments cannot disappear');
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.expect_state(format('update ins_policy_cancellations set reason=''Direct update'' where id=%L',cancellation.id),'42501','no direct API DML');
  perform pg_temp.expect_error(format('select fin_record_settlement(%L,''out'',%L,1,current_date,%L::jsonb)',operating,(select party_account_id from fin_open_items where id=cancellation.refund_item_id),jsonb_build_array(jsonb_build_object('open_item_id',cancellation.refund_item_id,'amount',1))),'INS_CANCELLATION_CASH_REQUIRED','generic cash cannot pay a cancellation refund without cash approval');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,1,current_date,%L)',draft.id,trust,gen_random_uuid()),'INS_CASH_STATE','old cash path cannot bypass cancelled-policy control');
  reset role;
  -- Legacy single-insurer cancellation with partial collections: stale review
  -- must refresh, credits consume only unpaid AR and no cash is auto-posted.
  perform pg_temp.jwt(manager); set local role authenticated;
  terms_input:=jsonb_build_array(jsonb_build_object('insurer_id',insurer,'terms',jsonb_build_object('method','pro_rata','contract_reference','Original contract permits pro-rata','pro_rata_permitted',true)));
  cancellation:=ins_submit_policy_cancellation(p.id,current_date,terms_input,'[]','Full inception-date cancellation',gen_random_uuid());
  perform pg_temp.jwt(maker);
  cancellation:=ins_prepare_policy_cancellation(cancellation.id,clearing);
  q:=ins_submit_policy_cash_request(p.id,'receipt',trust,100,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker); q:=ins_decide_policy_cash_request(q.id,'approve');
  perform pg_temp.expect_error(format('select ins_decide_policy_cancellation(%L,''approve'',''Stale review must not post'',false)',cancellation.id),'INS_CANCELLATION_STALE','new cash receipt invalidates reviewed figures');
  perform pg_temp.jwt(maker); cancellation:=ins_prepare_policy_cancellation(cancellation.id,clearing);
  q:=ins_submit_policy_cash_request(p.id,'receipt',trust,50,current_date,gen_random_uuid()); pending_cash:=q.id;
  perform pg_temp.jwt(checker); cancellation:=ins_decide_policy_cancellation(cancellation.id,'approve','Reviewed refreshed original contractual terms',false);
  reset role;
  perform pg_temp.assert((select amount=100 from fin_open_items where id=cancellation.refund_item_id),'only collected cash is a refund liability');
  perform pg_temp.assert((select sum(l.amount)=1800 from ins_cancellation_credit_links l where l.cancellation_id=cancellation.id),'900 unpaid AR and 900 insurer AP credits are separately linked');
  perform pg_temp.assert((select outstanding_amount=0 from fin_open_item_balances where source_type='ins_policy_premium' and source_id=p.id),'unpaid premium receivable consumed exactly');
  perform pg_temp.assert((select status='cancelled' and settlement_id is null from ins_policy_cash_requests where id=pending_cash),'old pending cash invalidated without moving money');
  perform pg_temp.assert((select sum(amount)=0 from ins_commission_ledger where policy_id=p.id),'full return leaves zero retained commission without rewriting original entries');

  -- Fully remitted/transferred policy: recover insurer money separately and
  -- disclose the commission cash still held in the broker operating account.
  perform pg_temp.jwt(maker); set local role authenticated;
  q:=ins_submit_policy_cash_request(p2.id,'receipt',trust,1000,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker); q:=ins_decide_policy_cash_request(q.id,'approve');
  perform pg_temp.jwt(maker); q:=ins_submit_policy_cash_request(p2.id,'remittance',trust,900,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker); q:=ins_decide_policy_cash_request(q.id,'approve');
  perform pg_temp.jwt(manager);
  select id into commission_a from ins_commission_entries where policy_id=p2.id;
  transfer_row:=ins_transfer_earned_commission(trust,operating,current_date,array[commission_a],'Original earned commission transfer');
  terms_input:=jsonb_build_array(jsonb_build_object('insurer_id',insurer,'terms',jsonb_build_object('method','manual_review','contract_reference','Insurer-approved half return','manual_return_premium','500')));
  cancellation:=ins_submit_policy_cancellation(p2.id,current_date,terms_input,'[]','Agreed half-premium cancellation',gen_random_uuid());
  perform pg_temp.jwt(maker); cancellation:=ins_prepare_policy_cancellation(cancellation.id,clearing);
  reset role;
  select count(*) into before_journals from journal_entries; select count(*) into before_credits from fin_credit_notes;
  select count(*) into before_settlements from fin_open_items;
  -- Fail after journals/open items have been built, just before policy state
  -- changes. The whole approval, including its evidence, must roll back.
  execute $ddl$create function pg_temp.fail_cancellation_policy_update() returns trigger language plpgsql as $fn$
   begin if new.status='cancelled' then raise exception 'FORCED_LATE_CANCEL_FAILURE'; end if; return new; end $fn$ $ddl$;
  create trigger cancellation_late_failure before update on ins_policies for each row execute function pg_temp.fail_cancellation_policy_update();
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_decide_policy_cancellation(%L,''approve'',''Reviewed paid policy cancellation'',true)',cancellation.id),'FORCED_LATE_CANCEL_FAILURE','late financial failure rolls back whole approval');
  reset role; drop trigger cancellation_late_failure on ins_policies;
  perform pg_temp.assert((select count(*) from journal_entries)=before_journals and (select count(*) from fin_credit_notes)=before_credits and (select count(*) from fin_open_items)=before_settlements,'no journals, credit notes or open items survive failed approval');
  perform pg_temp.assert((select status='prepared' and cancellation_no is null from ins_policy_cancellations where id=cancellation.id) and (select status='active' from ins_policies where id=p2.id),'case and policy remain retryable');
  perform pg_temp.jwt(checker); set local role authenticated;
  cancellation:=ins_decide_policy_cancellation(cancellation.id,'approve','Reviewed paid policy cancellation',true);
  reset role;
  perform pg_temp.assert((select sum(recovery_due)=450 and sum(payable_credit)=0 and sum(retained_commission)=50 and sum(transferred_clawback_due)=50 from ins_cancellation_insurer_adjustments where cancellation_id=cancellation.id),'net insurer recovery and transferred commission clawback remain distinct');
  perform pg_temp.assert((select amount=500 from fin_open_items where id=cancellation.refund_item_id),'client refund liability does not imply funds were recovered');
  perform pg_temp.assert((select e.amount=100 and e.status='transferred' and t.amount=100 and t.status='posted' from ins_commission_entries e join ins_commission_transfers t on t.id=e.transfer_id where e.id=commission_a),'original transferred commission history preserved');
  perform pg_temp.assert((select amount=50 and status='transferred' from ins_commission_ledger where id=commission_a),'net commission reporting is adjusted, not original cash transfer');
  perform pg_temp.jwt(maker); set local role authenticated;
  select recovery_item_id into payable_item from ins_cancellation_insurer_adjustments where cancellation_id=cancellation.id;
  perform pg_temp.expect_error(format('select fin_record_settlement(%L,''in'',%L,1,current_date,%L::jsonb)',trust,(select party_account_id from fin_open_items where id=payable_item),jsonb_build_array(jsonb_build_object('open_item_id',payable_item,'amount',1))),'INS_CANCELLATION_CASH_REQUIRED','insurer recovery also needs independent cash approval');
  perform pg_temp.expect_error(format('select void_journal_entry(%L,''Cannot rewrite original bank history'')',(select journal_entry_id from fin_settlements where id=q.settlement_id)),'INS_CANCELLATION_LOCKED','original cash journal cannot be independently voided');
  reset role;
  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L,''Cannot erase transferred clawback'')',transfer_row.id),'INS_CANCELLATION_LOCKED','original commission transfer cannot be erased instead of recovery');
  reset role;

  -- Claims inserted after preparation must still block the checker.
  perform pg_temp.jwt(manager); set local role authenticated;
  rollback_policy:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  perform pg_temp.motor_cert(rollback_policy.id); rollback_policy:=ins_bind_policy(rollback_policy.id);
  cancellation:=ins_submit_policy_cancellation(rollback_policy.id,current_date,terms_input,'[]','Prepared before claim arrived',gen_random_uuid());
  perform pg_temp.jwt(maker); cancellation:=ins_prepare_policy_cancellation(cancellation.id,clearing);
  perform pg_temp.jwt(manager); cn:=ins_create_claim(rollback_policy.id,current_date,current_date,'Claim received before approval',null,100);
  perform pg_temp.jwt(checker);
  perform pg_temp.expect_error(format('select ins_decide_policy_cancellation(%L,''approve'',''Cannot approve a claim-bearing policy'',true)',cancellation.id),'INS_CANCELLATION_CLAIM','claim at check time blocks cancellation');
  cancellation:=ins_decide_policy_cancellation(cancellation.id,'reject','Existing claim requires separate review');
  reset role;
  perform pg_temp.assert((select status='active' from ins_policies where id=rollback_policy.id) and cancellation.status='rejected','rejection preserves cover and claim evidence');

  -- Tax supplement includes signed cancellation credit rows, not just accruals.
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.assert((select sum(vat_amount)=4.5 from ins_broker_fee_tax_rows() where policy_id=draft.id),'fee VAT report nets original 9 less cancellation credit 4.5');
  perform pg_temp.assert((ins_policy_cash_position(draft.id)->>'can_prepare')::boolean=false,'legacy cash UI does not advertise cancelled-policy payment authority');
  perform pg_temp.assert((ins_policy_cancellation_context(draft.id)->>'can_finance')::boolean,'Finance without Insurance role can review cancellation history');
  reset role;
  perform pg_temp.assert((ins_policy_cancellation_context(draft.id,20)->>'has_live_case')::boolean and jsonb_array_length(ins_policy_cancellation_context(draft.id,20)->'cases')=0,'pagination never hides the global existing-case guard');
  perform pg_temp.jwt(manager); set local role authenticated;
  report:=ins_insurer_commission_statement_data(beta);
  perform pg_temp.assert((select (x->>'gross_premium')::numeric=200 and (x->>'commission_amount')::numeric=40 and (x->>'net_premium_to_insurer')::numeric=205 from jsonb_array_elements(report->'policies') x where x->>'id'=draft.id::text),'public non-lead insurer statement RPC reports retained amounts, not original bound totals');
  report:=ins_insurer_commission_statement_data(insurer);
  perform pg_temp.assert((select (x->>'gross_premium')::numeric=500 and (x->>'commission_amount')::numeric=50 and (x->>'net_premium_to_insurer')::numeric=450 from jsonb_array_elements(report->'policies') x where x->>'id'=p2.id::text),'public statement handles legacy single-insurer transferred commission without rewriting cash');
  reset role;
  set constraints all immediate;
  raise notice 'PASS: durable proposal, Finance maker/checker, explicit exceptions, immutable originals, zero-clearing posting, independent insurer credits and unpaid client refund liability';
end $$;
rollback;
