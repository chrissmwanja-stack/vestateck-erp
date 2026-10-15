-- Co-insurance and charges: existing single-insurer regressions remain unchanged.
-- Run only on a disposable local/test database; every fixture rolls back.
\set ON_ERROR_STOP on
begin;
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
  cn ins_claims%rowtype; transfer_row ins_commission_transfers%rowtype; report jsonb; expected numeric;
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
  p:=ins_bind_policy(p.id);
  p2:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  p2:=ins_bind_policy(p2.id);
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
  draft:=ins_bind_policy(draft.id);
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

  -- COINSURANCE_FIXTURE_READY: the TS race harness commits only fixture setup above.
  perform pg_temp.jwt(manager); set local role authenticated;
  cn:=ins_create_claim(draft.id,current_date,current_date,'Lead insurer claim',null,100);
  perform ins_transition_claim(cn.id,'assessing');
  cn:=ins_transition_claim(cn.id,'approved','Lead insurer assessment',100);
  perform pg_temp.assert(cn.payment_mode='insurer_direct','claims remain based on the lead insurer, not a co-insurer');
  perform pg_temp.expect_error(format('select ins_set_policy_financial_configuration(%L,%L::jsonb,%L::jsonb)',draft.id,config,charge_config),'INS_FINANCIAL_IMMUTABLE','bound configuration cannot be reset');
  v:=ins_policy_reversal_eligibility(draft.id);
  perform pg_temp.assert(not(v->>'eligible')::boolean,'co-insurance reversal eligibility is false');
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''reverse co-insurance'',false,%L)',draft.id,gen_random_uuid()),'INS_REVERSAL_COMPLEX','complex reversal is blocked');
  reset role;
  perform pg_temp.expect_error(format('update ins_policy_insurer_shares set share_pct=50 where id=%L',a),'INS_FINANCIAL_IMMUTABLE','even owner updates cannot rewrite bound shares');
  perform pg_temp.expect_error(format('update ins_policy_charges set amount=0 where policy_id=%L',draft.id),'INS_FINANCIAL_IMMUTABLE','bound charges cannot change');
  perform pg_temp.expect_error(format('update ins_policy_financial_snapshots set snapshot=''{}'' where policy_id=%L',draft.id),'INS_FINANCIAL_IMMUTABLE','immutable snapshot');
  perform pg_temp.assert((select snapshot from ins_policy_financial_snapshots where policy_id=draft.id)=snap,'historical snapshot is unchanged');

  perform pg_temp.jwt(maker); set local role authenticated;
  select id into premium_item from fin_open_items where source_id=draft.id and source_type='ins_policy_premium';
  perform pg_temp.expect_error(format('select fin_raise_credit_note(%L,%L,1,current_date,%L,%L::jsonb,''complex credit bypass'')',
    'ar_control',(select party_account_id from fin_open_items where id=premium_item),fee_gl,jsonb_build_array(jsonb_build_object('open_item_id',premium_item,'amount',1))),
    'INS_CANCELLATION_REQUIRED','generic premium credit cannot bypass complex cancellation restriction');
  q1:=ins_submit_policy_cash_request(draft.id,'receipt',trust,400,current_date,gen_random_uuid());
  q2:=ins_submit_policy_cash_request(draft.id,'receipt',trust,204.50,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker); q1:=ins_decide_policy_cash_request(q1.id,'approve'); q2:=ins_decide_policy_cash_request(q2.id,'approve');
  v:=ins_policy_cash_position(draft.id);
  perform pg_temp.assert((v->>'collected')::numeric=604.5 and (v->>'broker_fee_collected')::numeric=25 and (v->>'vat_collected')::numeric=4.5,'collections are split across invoice components');
  perform pg_temp.assert((select (x->>'funded')::numeric from jsonb_array_elements(v->'shares')x where x->>'share_id'=a::text)=330,'lead is funded only pro rata');
  perform pg_temp.assert((select (x->>'funded')::numeric from jsonb_array_elements(v->'shares')x where x->>'share_id'=b::text)=245,'Beta funding includes its assigned charges');
  perform pg_temp.jwt(maker);
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''remittance'',%L,1,current_date,%L)',draft.id,trust,gen_random_uuid()),'INS_SHARE_INPUT','new-path remittances require a recipient share');
  perform pg_temp.expect_error(format('select ins_submit_policy_share_cash_request(%L,%L,%L,331,current_date,%L)',draft.id,a,trust,gen_random_uuid()),'INS_CASH_CAP','cannot overfund lead insurer');
  perform pg_temp.expect_error(format('select ins_submit_policy_share_cash_request(%L,%L,%L,1,current_date,%L)',p2.id,a,trust,gen_random_uuid()),'INS_SHARE_INPUT','cannot remit against another policy share');
  qa:=ins_submit_policy_share_cash_request(draft.id,a,trust,300,current_date,gen_random_uuid());
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',qa.id),'INS_CASH_SELF_APPROVAL','share remittance still needs a checker');
  perform pg_temp.jwt(checker); qa:=ins_decide_policy_cash_request(qa.id,'approve');
  perform pg_temp.jwt(maker);
  perform pg_temp.expect_error(format('select fin_void_settlement(%L,''remove partial receipt'')',q2.settlement_id),'INS_CASH_FUNDS_IN_USE','receipt void must preserve per-share funding, not merely policy total');
  qb:=ins_submit_policy_share_cash_request(draft.id,b,trust,200,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker); qb:=ins_decide_policy_cash_request(qb.id,'approve');
  reset role;
  perform pg_temp.assert((select count(*) from ins_commission_entries where policy_id=draft.id and status='deferred')=2,'partial insurer remittances do not recognize either full commission');
  raise notice 'PASS: pro-rata funding, fees/VAT ring-fencing, recipient selection, maker/checker and per-share receipt-void dependency';

  -- The third-party reconciliation backstop covers both new payable sources.
  perform pg_temp.jwt(maker); set local role authenticated;
  select id into payment_line from import_bank_statement_lines('PREMIUM-TRUST',jsonb_build_array(jsonb_build_object('statement_date',current_date,'amount',-300)));
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_settlement(%L,%L)',payment_line,qa.settlement_id),'INS_CASH_THIRD_PERSON','maker cannot reconcile new share payable');
  perform pg_temp.assert(auto_match_bank_statement('PREMIUM-TRUST',current_date,current_date)=0,'auto-match skips maker share movements');
  perform pg_temp.jwt(checker);
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_settlement(%L,%L)',payment_line,qa.settlement_id),'INS_CASH_THIRD_PERSON','checker cannot reconcile new share payable');
  perform pg_temp.jwt(reconciler); rec:=match_bank_statement_line_to_settlement(payment_line,qa.settlement_id);
  perform unmatch_bank_reconciliation(rec.id);
  reset role;
  perform pg_temp.assert((select count(*) from ins_policy_cash_reconciliation_events where policy_id=draft.id)=2,'share reconciliation/unmatch trail is attributed to the policy');
  perform pg_temp.jwt(maker); set local role authenticated;
  select id into payable_item from fin_open_items where source_type='ins_policy_share_insurer' and source_id=a;
  perform pg_temp.expect_error(format('select fin_record_settlement(%L,''out'',%L,1,current_date,%L::jsonb)',trust,
    (select party_account_id from fin_open_items where id=payable_item),jsonb_build_array(jsonb_build_object('open_item_id',payable_item,'amount',1))),
    'INS_CASH_APPROVAL_REQUIRED','generic Finance cannot bypass share approval');
  -- Collect the rest, then settle A independently while B remains partly paid.
  q:=ins_submit_policy_cash_request(draft.id,'receipt',trust,604.50,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker); q:=ins_decide_policy_cash_request(q.id,'approve');
  perform pg_temp.jwt(maker); outq:=ins_submit_policy_share_cash_request(draft.id,a,trust,300,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker); outq:=ins_decide_policy_cash_request(outq.id,'approve');
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id=commission_a)='earned' and (select status from ins_commission_entries where id=commission_b)='deferred','only fully remitted insurer share commission is recognized');
  perform pg_temp.jwt(manager); set local role authenticated;
  report:=ins_insurer_commission_statement_data(beta);
  perform pg_temp.assert((select count(*) from jsonb_array_elements(report->'policies') x where x->>'id'=draft.id::text and (x->>'gross_premium')::numeric=400 and (x->>'commission_rate_pct')::numeric=20)=1,'non-lead insurer statement uses its allocation and rate');
  transfer_row:=ins_transfer_earned_commission(trust,operating,current_date,array[commission_a],'A commission only');
  reset role;
  perform pg_temp.assert(transfer_row.amount=60,'commission transfer is independent per insurer');
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.expect_error(format('select fin_void_settlement(%L,''reverse fully remitted share'')',outq.settlement_id),'INS_COMMISSION_TRANSFERRED','cannot void insurer payment after that share commission withdrawal');
  reset role;
  raise notice 'PASS: third Finance reconciliation/audit, generic bypass closure, independent recognition, statements and commission transfers';

  perform pg_temp.jwt(manager); set local role authenticated;
  renewed:=ins_create_renewal_draft(draft.id);
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)',renewed.id),'INS_CONFIG_REVIEW','renewal cannot bind without fresh review');
  reset role;
  perform pg_temp.assert((select count(*) from ins_policy_insurer_shares where policy_id=renewed.id and not reviewed)=2,'renewal copies shares but not review approval');
  perform pg_temp.assert((select count(*) from ins_policy_charges where policy_id=renewed.id and amount is null and not reviewed)=3,'renewal copies charge structure, clears historical amounts');
  perform pg_temp.assert((select count(*) from ins_policy_financial_snapshots where policy_id=renewed.id)=0,'renewal has no financial posting snapshot');

  perform pg_temp.jwt(manager); set local role authenticated;
  zero_policy:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  perform ins_set_policy_financial_configuration(zero_policy.id,jsonb_build_array(config->0||jsonb_build_object('share_pct',100)),
    jsonb_build_array(jsonb_build_object('kind','insurer_pass_through','description','Zero-valued charge','amount',0,'recipient_mode','all_insurers','reviewed',true)));
  zero_policy:=ins_bind_policy(zero_policy.id);
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''zero charge reversal'',false,%L)',zero_policy.id,gen_random_uuid()),'INS_REVERSAL_COMPLEX','zero-valued charges never bypass reversal restriction');
  reset role;
  raise notice 'PASS: renewal review/reset and zero-valued charge reversal restriction';

  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_policy_charge_income_accounts() where id=fee_gl)=1,'income account picker exposes active same-tenant revenue accounts');
  reset role;

  -- Largest-remainder rounding favors the largest fraction, not the final
  -- insurer UUID or the lead, and keeps premium and charge totals exact.
  perform pg_temp.jwt(manager); set local role authenticated;
  zero_policy:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',.03,0,null,null);
  perform ins_set_policy_financial_configuration(zero_policy.id,jsonb_set(jsonb_set(config,'{0,commission_rate_pct}','0'),'{1,commission_rate_pct}','0'),
    jsonb_build_array(jsonb_build_object('kind','insurer_pass_through','description','Rounding test','amount',.01,'recipient_mode','all_insurers','reviewed',true)));
  zero_policy:=ins_bind_policy(zero_policy.id);
  reset role;
  perform pg_temp.assert((select premium_amount=.02 and pass_through_amount=.01 from ins_policy_insurer_shares where policy_id=zero_policy.id and insurer_id=insurer),'largest fractional premium/charge receives the remainder cent');
  perform pg_temp.assert((select sum(premium_amount)=.03 and sum(pass_through_amount)=.01 from ins_policy_insurer_shares where policy_id=zero_policy.id),'rounding preserves exact allocation totals');

  -- Failed tax/account configuration rolls back the entire extended bind.
  perform pg_temp.jwt(manager); set local role authenticated;
  rollback_policy:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  perform ins_set_policy_financial_configuration(rollback_policy.id,config,charge_config);
  reset role;
  select count(*) into jbefore from journal_entries where tenant_id=ta;
  delete from gl_posting_rules where tenant_id=ta and account_role='vat_output';
  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)',rollback_policy.id),'INS_POSTING_RULE_MISSING','VAT option requires liability account');
  reset role;
  perform pg_temp.assert((select status from ins_policies where id=rollback_policy.id)='draft'
    and (select count(*) from journal_entries where tenant_id=ta)=jbefore
    and not exists(select 1 from ins_policy_financial_snapshots where policy_id=rollback_policy.id)
    and not exists(select 1 from ins_policy_insurer_shares where policy_id=rollback_policy.id and premium_amount is not null),'failed bind leaves no journals, snapshots or calculated allocation residue');
  -- Force failure AFTER the bind journal and premium receivable exist.
  -- The outer RPC transaction must still remove every partial accounting row.
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values(ta,'vat_output',tax_gl);
  execute $ddl$create function pg_temp.force_share_item_failure() returns trigger language plpgsql as $fn$
    begin if new.source_type='ins_policy_share_insurer' then raise exception 'INS_TEST_LATE_BIND_FAILURE'; end if; return new; end $fn$ $ddl$;
  execute 'create trigger zzz_test_share_item_failure before insert on public.fin_open_items for each row execute function pg_temp.force_share_item_failure()';
  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)',rollback_policy.id),'INS_TEST_LATE_BIND_FAILURE','late failure rolls back an already posted bind journal and open items');
  reset role;
  execute 'drop trigger zzz_test_share_item_failure on public.fin_open_items';
  perform pg_temp.assert((select count(*) from journal_entries where tenant_id=ta)=jbefore
    and not exists(select 1 from fin_open_items where source_type='ins_policy_premium' and source_id=rollback_policy.id)
    and not exists(select 1 from fin_open_items where source_type='ins_policy_share_insurer' and source_id in(select id from ins_policy_insurer_shares where policy_id=rollback_policy.id))
    and not exists(select 1 from ins_policy_financial_snapshots where policy_id=rollback_policy.id),'late failure leaves neither journal nor any policy/share open item or snapshot');
  delete from gl_posting_rules where tenant_id=ta and account_role='vat_output';
  perform pg_temp.jwt(manager); set local role authenticated;
  zero_policy:=ins_create_policy(c.id,insurer,line_id,current_date,current_date+365,50000,'UGX',1000,10,null,null);
  perform ins_set_policy_financial_configuration(zero_policy.id,jsonb_build_array(config->0||jsonb_build_object('share_pct',100)),
    jsonb_build_array(jsonb_build_object('kind','broker_fee','description','VAT deliberately not calculated','amount',50,'recipient_mode','broker','income_gl_account_id',fee_gl,'vat_mode','not_calculated','reviewed',true)));
  zero_policy:=ins_bind_policy(zero_policy.id);
  reset role;
  perform pg_temp.assert((select vat_total=0 and invoice_total=1050 from ins_policy_financial_snapshots where policy_id=zero_policy.id),'VAT not calculated is allowed without a VAT liability mapping and is not labelled exempt');
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_policy_cash_policies('Beta co-insurer'))>0,'Finance policy search includes non-lead insurers');
  perform pg_temp.assert((select count(*) from ins_broker_fee_tax_rows())=2,'Finance without Insurance role can report fee VAT');
  perform pg_temp.assert((select sum(vat_amount) from ins_broker_fee_tax_rows())=9,'VAT supplement reports explicit output tax');
  reset role;
  perform pg_temp.jwt(other_fin); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_policy_insurer_shares where policy_id=draft.id)=0,'shares are tenant isolated');
  perform pg_temp.expect_error(format('select ins_policy_financial_details(%L)',draft.id),'INS_NOT_FOUND','cross-tenant financial details');
  perform pg_temp.assert((select count(*) from ins_broker_fee_tax_rows())=0,'VAT report is tenant isolated');
  reset role;
  set local role anon;
  perform pg_temp.expect_state(format('select ins_policy_financial_details(%L)',draft.id),'42501','anonymous financial configuration');
  reset role;
  raise notice 'PASS: transactional bind rollback, Finance-only VAT supplement, tenant isolation and anonymous denial';
end $$;
rollback;
