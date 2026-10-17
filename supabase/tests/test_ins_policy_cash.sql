-- Premium receipts/remittances: real authenticated RPCs and trigger backstops.
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

  -- CONCURRENCY_FIXTURE_READY: the TS race harness reuses only the fixture above.
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.assert(not can_access_insurance(),'Finance cash workflow does not require Insurance membership');
  perform pg_temp.assert((select count(*) from ins_policy_cash_policies())=2,'Finance has a narrow policy lookup');
  perform pg_temp.assert((select count(*) from ins_policy_cash_bank_accounts())=1,'only mapped active client-money banks offered');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''remittance'',%L,1,current_date,%L)',p.id,trust,gen_random_uuid()),'INS_CASH_CAP','unfunded remittance');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,1,current_date,%L)',draft.id,trust,gen_random_uuid()),'INS_CASH_STATE','draft policy');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,1,current_date,%L)',p.id,operating,gen_random_uuid()),'INS_CASH_BANK','operating bank');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,1,current_date,%L)',p.id,otherbank,gen_random_uuid()),'INS_CASH_BANK','cross-tenant bank');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,1,current_date+1,%L)',p.id,trust,gen_random_uuid()),'INS_CASH_DATE','future date');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,1.001,current_date,%L)',p.id,trust,gen_random_uuid()),'INS_CASH_INPUT','precision is not silently rounded');
  q:=ins_submit_policy_cash_request(p.id,'receipt',trust,400,current_date,key,'PREMIUM-001','partial client collection');
  retry:=ins_submit_policy_cash_request(p.id,'receipt',trust,400,current_date,key,'PREMIUM-001','partial client collection');
  perform pg_temp.assert(q.id=retry.id and q.status='pending' and q.settlement_id is null,'submission is idempotent and does not post');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,401,current_date,%L)',p.id,trust,key),'INS_CASH_RETRY_CONFLICT','key cannot change payload');
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',q.id),'INS_CASH_SELF_APPROVAL','maker cannot approve');
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''reject'',''not allowed'')',q.id),'INS_CASH_SELF_APPROVAL','maker cannot reject as checker');
  v:=ins_policy_cash_position(p.id);
  perform pg_temp.assert((v->>'collected')::numeric=0 and (v->>'maximum_remittance')::numeric=0,'pending cash is not spendable');
  reset role;
  select count(*) into n from fin_settlements where tenant_id=ta;
  select count(*) into j from journal_entries where tenant_id=ta;

  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',q.id),'INS_CASH_FORBIDDEN','Insurance manager cannot approve cash');
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''receipt'',%L,1,current_date,%L)',p.id,trust,gen_random_uuid()),'INS_CASH_FORBIDDEN','Insurance manager cannot prepare cash');
  perform pg_temp.expect_error('select ins_policy_cash_bank_accounts()','INS_CASH_FORBIDDEN','no Insurance-only bank cash authority');
  v:=ins_policy_cash_position(p.id);
  perform pg_temp.assert(not (v->>'can_prepare')::boolean and jsonb_array_length(v->'requests')=1,'Insurance reads status only');
  perform pg_temp.expect_state(format('update ins_policy_cash_requests set amount=1 where id=%L',q.id),'42501','request evidence is not editable');
  reset role;
  perform pg_temp.jwt(other_fin); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_policy_cash_requests where id=q.id)=0,'requests are tenant isolated');
  perform pg_temp.expect_error(format('select ins_policy_cash_position(%L)',p.id),'INS_NOT_FOUND','cross-tenant status');
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',q.id),'INS_NOT_FOUND','cross-tenant checker');
  reset role;
  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_policy_cash_position(%L)',p.id),'INS_CASH_FORBIDDEN','outsider status');
  reset role;
  raise notice 'PASS: Finance-only preparation, read-only Insurance, RLS, inputs, idempotency and no self-approval';

  -- Direct generic Finance recording must roll back its entire settlement.
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.expect_error(format('select fin_record_settlement(%L,''in'',%L,10,current_date,%L::jsonb)',trust,(select party_account_id from fin_open_items where id=premium_item),
    jsonb_build_array(jsonb_build_object('open_item_id',premium_item,'amount',10))), 'INS_CASH_APPROVAL_REQUIRED','generic receipt bypass');
  perform pg_temp.expect_error(format('select fin_record_settlement(%L,''out'',%L,10,current_date,%L::jsonb)',trust,
    (select party_account_id from fin_open_items where id=payable_item),jsonb_build_array(jsonb_build_object('open_item_id',payable_item,'amount',10))),
    'INS_CASH_APPROVAL_REQUIRED','generic remittance bypass');
  perform pg_temp.expect_state(format('select ins_policy_cash_validate(%L,''receipt'',%L,1,current_date)',p.id,trust),'42501','private helper');
  perform pg_temp.expect_state(format('update ins_policy_cash_requests set status=''posting'',checker_id=%L,operation_txid=txid_current() where id=%L',checker,q.id),'42501','forged approval context');
  reset role;
  perform pg_temp.assert((select count(*) from fin_settlements where tenant_id=ta)=n and (select count(*) from journal_entries where tenant_id=ta)=j,'bypass attempts leave no settlements or journals');
  perform pg_temp.jwt(checker); set local role authenticated;
  q:=ins_decide_policy_cash_request(q.id,'approve');
  retry:=ins_decide_policy_cash_request(q.id,'approve');
  perform pg_temp.assert(q.id=retry.id and q.settlement_id=retry.settlement_id and q.checker_id=checker,'same checker retry never reposts');
  v:=ins_policy_cash_position(p.id);
  perform pg_temp.assert((v->>'collected')::numeric=400 and (v->>'maximum_remittance')::numeric=400 and (v->>'insurer_outstanding')::numeric=900,'partial receipt makes exactly 400 available, no pro-rata reserve');
  reset role;
  perform pg_temp.assert((select count(*) from fin_settlements where tenant_id=ta)=n+1,'one approval creates one Finance settlement');
  perform pg_temp.assert((select sum(l.debit-l.credit) from journal_entry_lines l join fin_settlements s on s.journal_entry_id=l.journal_entry_id where s.id=q.settlement_id)=0,'receipt journal balances');
  perform pg_temp.assert((select sum(l.debit-l.credit) from journal_entry_lines l join fin_settlements s on s.journal_entry_id=l.journal_entry_id where s.id=q.settlement_id and l.gl_account_id=trust_gl)=400,'receipt debits client money');
  raise notice 'PASS: generic bypass closure, atomic posting, idempotent approval and exact partial-funding cap';

  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_submit_policy_cash_request(%L,''remittance'',%L,1,current_date,%L)',p2.id,trust,gen_random_uuid()),'INS_CASH_CAP','cannot use another policy collections');
  outq:=ins_submit_policy_cash_request(p.id,'remittance',trust,350,current_date,gen_random_uuid());
  stale:=ins_submit_policy_cash_request(p.id,'remittance',trust,300,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker);
  outq:=ins_decide_policy_cash_request(outq.id,'approve');
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',stale.id),'INS_CASH_CAP','approval rechecks funds consumed by another request');
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''cancel'',''cancel wrong maker'')',stale.id),'INS_CASH_MAKER','checker cannot cancel as maker');
  perform pg_temp.jwt(maker);
  stale:=ins_decide_policy_cash_request(stale.id,'cancel','superseded instruction');
  v:=ins_policy_cash_position(p.id);
  perform pg_temp.assert((v->>'remitted')::numeric=350 and (v->>'maximum_remittance')::numeric=50,'partial remittance consumes only its allocated funds');
  perform pg_temp.expect_error(format('select fin_void_settlement(%L,''remove client receipt'')',q.settlement_id),'INS_CASH_FUNDS_IN_USE','funding receipt cannot be voided');
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where policy_id=p.id)='deferred','partial net remittance does not recognize commission');
  raise notice 'PASS: per-policy funding isolation, stale approval rejection, cancellation and receipt dependency protection';

  -- Both manual and auto paths require a THIRD distinct Finance actor.
  perform pg_temp.jwt(maker); set local role authenticated;
  select id into receipt_line from import_bank_statement_lines('PREMIUM-TRUST',jsonb_build_array(jsonb_build_object('statement_date',current_date,'amount',400)));
  select id into payment_line from import_bank_statement_lines('PREMIUM-TRUST',jsonb_build_array(jsonb_build_object('statement_date',current_date,'amount',-350)));
  perform pg_temp.assert(auto_match_bank_statement('PREMIUM-TRUST',current_date,current_date)=0,'maker auto-match skips both movements');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_settlement(%L,%L)',receipt_line,q.settlement_id),'INS_CASH_THIRD_PERSON','maker cannot reconcile receipt');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_settlement(%L,%L)',payment_line,outq.settlement_id),'INS_CASH_THIRD_PERSON','maker cannot reconcile remittance');
  perform pg_temp.jwt(checker);
  perform pg_temp.assert(auto_match_bank_statement('PREMIUM-TRUST',current_date,current_date)=0,'checker auto-match skips both movements');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_settlement(%L,%L)',receipt_line,q.settlement_id),'INS_CASH_THIRD_PERSON','checker/poster cannot reconcile');
  perform pg_temp.jwt(reconciler);
  rec:=match_bank_statement_line_to_settlement(receipt_line,q.settlement_id);
  reset role;
  perform pg_temp.expect_error(format('update bank_reconciliations set matched_by=%L where id=%L',maker,rec.id),
    'INS_CASH_RECONCILIATION','even an alternate writer cannot rewrite policy reconciliation evidence');
  perform pg_temp.expect_error(format('update bank_reconciliations set settlement_id=null where id=%L',rec.id),
    'INS_CASH_RECONCILIATION','cannot detach a policy source by updating the match');
  perform pg_temp.expect_error(format('insert into bank_reconciliations(tenant_id,bank_statement_line_id,settlement_id,matched_by,match_type,variance) values(%L,%L,%L,%L,''manual'',0)',
    ta,payment_line,outq.settlement_id,maker),'INS_CASH_RECONCILIATION','third user cannot forge matched_by through an alternate writer');
  set local role authenticated;
  perform pg_temp.jwt(maker);
  perform pg_temp.expect_error(format('select unmatch_bank_reconciliation(%L)',rec.id),'INS_CASH_THIRD_PERSON','maker cannot remove independent reconciliation');
  perform pg_temp.jwt(reconciler);
  perform unmatch_bank_reconciliation(rec.id);
  perform pg_temp.assert(auto_match_bank_statement('PREMIUM-TRUST',current_date,current_date)=2,'independent Finance auto-matches both movements');
  v:=ins_policy_cash_position(p.id);
  perform pg_temp.assert((select count(*) from jsonb_array_elements(v->'requests') r where (r->>'reconciled')::boolean)=2,'Insurance/Finance status exposes reconciliation');
  reset role;
  select id into rec2 from bank_reconciliations where settlement_id=outq.settlement_id;
  perform pg_temp.assert((select count(*) from ins_policy_cash_reconciliation_events where policy_id=p.id)=4,'match/unmatch evidence is append-only and retained');
  perform pg_temp.jwt(maker); set local role authenticated;
  perform pg_temp.expect_error(format('select fin_void_settlement(%L,''reverse reconciled payment'')',outq.settlement_id),'reconciled','cannot void reconciled remittance');
  perform pg_temp.jwt(reconciler);
  select * into rec from bank_reconciliations where settlement_id=q.settlement_id;
  perform unmatch_bank_reconciliation(rec.id); perform unmatch_bank_reconciliation(rec2);
  perform pg_temp.jwt(maker);
  perform fin_void_settlement(outq.settlement_id,'reverse partial remittance');
  perform fin_void_settlement(q.settlement_id,'reverse unspent premium receipt');
  v:=ins_policy_cash_position(p.id);
  perform pg_temp.assert((v->>'collected')::numeric=0 and (v->>'remitted')::numeric=0,'voided cash does not permanently consume funding');
  reset role;
  raise notice 'PASS: independent manual/auto reconciliation, independent unmatch, durable audit and effective-void accounting';

  -- Approval failure must leave the request pending, no journal, no partial cash.
  perform pg_temp.jwt(maker); set local role authenticated;
  broken:=ins_submit_policy_cash_request(p.id,'receipt',trust,100,current_date,gen_random_uuid());
  bankq:=ins_submit_policy_cash_request(p.id,'receipt',trust,200,current_date,gen_random_uuid());
  rejected:=ins_submit_policy_cash_request(p.id,'receipt',trust,25,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker);
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''reject'',''no'')',rejected.id),'INS_CASH_REASON','rejection requires reason');
  rejected:=ins_decide_policy_cash_request(rejected.id,'reject','incorrect bank reference');
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',rejected.id),'INS_CASH_DECIDED','rejected request cannot post');
  reset role;
  select count(*) into n from fin_settlements where tenant_id=ta;
  select count(*) into j from journal_entries where tenant_id=ta;
  delete from gl_posting_rules where tenant_id=ta and account_role='ar_control';
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',broken.id),'SETTLEMENT_UNMAPPED_ROLE','missing posting rule rolls back approval');
  reset role;
  perform pg_temp.assert((select status='pending' and checker_id is null and settlement_id is null from ins_policy_cash_requests where id=broken.id)
    and (select count(*) from fin_settlements where tenant_id=ta)=n and (select count(*) from journal_entries where tenant_id=ta)=j,'failed posting rolls back request, allocations, settlement and journal');
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values(ta,'ar_control',ar_gl);
  update fin_bank_accounts set is_active=false where id=trust;
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',bankq.id),'INS_CASH_BANK','bank revalidated at approval');
  reset role;
  update fin_bank_accounts set is_active=true where id=trust;
  perform pg_temp.jwt(checker); set local role authenticated;
  broken:=ins_decide_policy_cash_request(broken.id,'approve');
  reset role;
  perform pg_temp.assert(broken.status='posted','failed approval can be retried after configuration repair');
  delete from finance_team_members where user_id=checker and tenant_id=ta;
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',bankq.id),'INS_CASH_FORBIDDEN','revoked Finance role cannot approve');
  reset role;
  insert into finance_team_members(tenant_id,user_id,role) values(ta,checker,'finance');
  update tenants set read_only=true,read_only_reason='test financial freeze',read_only_since=now() where id=ta;
  perform pg_temp.jwt(checker); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',bankq.id),'TENANT_READ_ONLY','frozen tenant cannot post cash');
  reset role;
  update tenants set read_only=false,read_only_reason=null where id=ta;
  raise notice 'PASS: rejection, no repost, approval-time bank validation and full posting rollback';

  -- Reversal of a policy invalidates previously submitted requests at approval.
  perform pg_temp.jwt(maker); set local role authenticated;
  stale:=ins_submit_policy_cash_request(p2.id,'receipt',trust,100,current_date,gen_random_uuid());
  perform pg_temp.jwt(manager);
  perform ins_reverse_policy(p2.id,'issued in error',false,gen_random_uuid());
  perform pg_temp.jwt(checker);
  perform pg_temp.expect_error(format('select ins_decide_policy_cash_request(%L,''approve'')',stale.id),'INS_CASH_STATE','reversed policy cannot approve stale cash');
  reset role;
  perform pg_temp.jwt(other_fin); set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_policy_cash_reconciliation_events where tenant_id=ta)=0,'reconciliation audit tenant isolation');
  reset role;
  set local role anon;
  perform pg_temp.expect_state(format('select ins_policy_cash_position(%L)',p.id),'42501','anonymous status');
  perform pg_temp.expect_state(format('select * from ins_policy_cash_requests where id=%L',q.id),'42501','anonymous request evidence');
  reset role;
  raise notice 'PASS: reversed policy blocks stale cash, audit tenant isolation and anonymous denials';
end $$;
rollback;
