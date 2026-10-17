-- Insurance claim payments (20261013090000_ins_claim_payments.sql).
--
-- Covers: the per-insurer setting and its default (insurer-direct), the mode
-- being copied onto the claim at approval and surviving a later change to the
-- insurer, insurer-direct payments (evidence only, nothing posted, partial and
-- full, auto-settle, void and revert, validation, authorization), brokerage-
-- managed claims (accrual journal and open items, receipt into client money,
-- payout to the client, the rule that the brokerage never pays ahead of the
-- insurer, void rules from both the claim and Finance), the lock on settling a
-- claim item from the generic Finance screen, manual "settled" being refused,
-- a missing posting rule leaving nothing behind, closed claims, direct-write
-- lockout, tenant isolation, anon, and the posting roles and template.
--
-- Run against a fresh local stack only (`supabase start` / `supabase db reset`).
-- Everything runs in one transaction that ROLLBACKs, so no fixture data is left
-- behind; any RAISE EXCEPTION is a real assertion failure and makes psql exit
-- non-zero (same convention as the other files in this directory).

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

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- Runs a statement that must fail with an error whose text contains p_needle.
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

-- The RPCs set the transaction-local flag `ins.via_rpc` and it stays on for the
-- rest of the transaction. Clear it before probing the direct-write guards, so a
-- test does not pass or fail because an earlier RPC left the flag on.
create function pg_temp.flag_off()
returns void language sql as $$ select set_config('ins.via_rpc', 'off', true); $$;
create function pg_temp.flag_on()
returns void language sql as $$ select set_config('ins.via_rpc', 'on', true); $$;

-- Owner-side numeric reader, so assertions do not depend on the caller's RLS.
create function pg_temp.scalar(p_sql text)
returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric;
begin
  execute p_sql into v;
  return v;
end $$;

create function pg_temp.je_net(p_je uuid, p_gl uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines
  where journal_entry_id = p_je and gl_account_id = p_gl
$$;
create function pg_temp.je_bal(p_je uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines where journal_entry_id = p_je
$$;
create function pg_temp.je_lines(p_je uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.journal_entry_lines where journal_entry_id = p_je
$$;
create function pg_temp.n_items_for(p_policy uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.fin_open_items
  where source_id = p_policy and source_type in ('ins_policy_premium', 'ins_policy_insurer')
$$;

create function pg_temp.item(p_policy uuid, p_type text) returns uuid
language sql security definer as $$
  select id from public.fin_open_items where source_id = p_policy and source_type = p_type
$$;
create function pg_temp.bal(p_tenant uuid, p_gl uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines
  where tenant_id = p_tenant and gl_account_id = p_gl
$$;
create function pg_temp.newpol(p_client uuid, p_insurer uuid, p_line uuid, p_gross numeric, p_rate numeric)
returns public.ins_policies language sql as $$
  select * from public.ins_create_policy(p_client, p_insurer, p_line, current_date, current_date + 365,
                                         50000000, 'UGX', p_gross, p_rate, null, null)
$$;
create function pg_temp.pay(p_bank uuid, p_dir text, p_party uuid, p_item uuid, p_amount numeric)
returns public.fin_settlements language sql as $$
  select * from public.fin_record_settlement(p_bank, p_dir, p_party, p_amount, current_date,
    jsonb_build_array(jsonb_build_object('open_item_id', p_item, 'amount', p_amount)))
$$;


create function pg_temp.newclaim(p_policy uuid, p_reserve numeric)
returns public.ins_claims language sql as $$
  select * from public.ins_create_claim(p_policy, current_date, current_date, 'Collision damage', null, p_reserve)
$$;

-- Registers-then-approves must be two people (segregation of duties). The caller
-- registers the claim; the approver named by test.approver approves it; the caller is restored.
create function pg_temp.approved(p_claim uuid, p_amount numeric)
returns public.ins_claims language plpgsql as $$
declare c public.ins_claims;
  v_prev text := current_setting('request.jwt.claims', true);
begin
  perform public.ins_transition_claim(p_claim, 'assessing', null);
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.approver'), 'role', 'authenticated')::text, true);
  c := public.ins_transition_claim(p_claim, 'approved', 'ok', p_amount);
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return c;
end $$;

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  u_mgr   uuid := gen_random_uuid();
  u_mem   uuid := gen_random_uuid();
  u_fin   uuid := gen_random_uuid();
  u_mgr_b uuid := gen_random_uuid();
  u_appr  uuid := gen_random_uuid();
  u_appr_b uuid := gen_random_uuid();

  g_bank uuid; g_trust uuid; g_ar uuid; g_pay uuid; g_unear uuid; g_inc uuid; g_crec uuid; g_cpay uuid;
  gb_ar uuid; gb_pay uuid; gb_unear uuid; gb_inc uuid;
  v_pl uuid; v_alpha uuid; v_beta uuid; v_pl_b uuid; v_insr_b uuid;
  c1 ins_clients%rowtype; cb ins_clients%rowtype;
  pa ins_policies%rowtype; pbk ins_policies%rowtype; pb ins_policies%rowtype;
  cl_d ins_claims%rowtype; cl_x ins_claims%rowtype; cl_u ins_claims%rowtype; cl_r ins_claims%rowtype; cl_b ins_claims%rowtype; cl_b2 ins_claims%rowtype; cl_t ins_claims%rowtype;
  pay1 ins_claim_payments%rowtype; pay2 ins_claim_payments%rowtype;
  r1 ins_claim_payments%rowtype; r2 ins_claim_payments%rowtype; o1 ins_claim_payments%rowtype; o2 ins_claim_payments%rowtype;
  v_trust_bank uuid; v_oper_bank uuid;
  v_n integer; v_before integer; v_je uuid; v_item_ins uuid; v_item_cli uuid;
  v_pcli uuid; v_pins uuid;
begin
  -------------------------------------------------------------------
  -- The approver the helper uses. Approval must be by someone other than the registrant.
  perform set_config('test.approver', u_appr::text, true);

  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Claims A'), (v_tb, 'Claims B');
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'insclm-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (u_mgr), (u_mem), (u_fin), (u_mgr_b), (u_appr), (u_appr_b)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (u_mgr,   v_ta, 'Claims Manager A', 'insclm-' || u_mgr   || '@test.local'),
    (u_mem,   v_ta, 'Claims Member A',  'insclm-' || u_mem   || '@test.local'),
    (u_fin,   v_ta, 'Claims Finance A', 'insclm-' || u_fin   || '@test.local'),
    (u_mgr_b, v_tb, 'Claims Manager B', 'insclm-' || u_mgr_b || '@test.local'),
    (u_appr,  v_ta, 'Claims Approver A', 'insclm-' || u_appr || '@test.local'),
    (u_appr_b, v_tb, 'Claims Approver B', 'insclm-' || u_appr_b || '@test.local');
  insert into tenant_modules (tenant_id, module) values (v_ta, 'insurance'), (v_tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_ta, u_mgr,   'insurance', 'manager'),
    (v_ta, u_mem,   'insurance', 'member'),
    (v_ta, u_appr,  'insurance', 'manager'),
    (v_tb, u_mgr_b, 'insurance', 'manager'),
    (v_tb, u_appr_b, 'insurance', 'manager');
  insert into finance_team_members (tenant_id, user_id, role) values (v_ta, u_fin, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank', 'asset') returning id into g_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1100', 'AR Control', 'asset') returning id into g_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1120', 'Claims Receivable from Insurers', 'asset') returning id into g_crec;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into g_pay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2020', 'Unearned Commission', 'liability') returning id into g_unear;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2030', 'Claims Payable to Clients', 'liability') returning id into g_cpay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '4000', 'Commission Income', 'revenue') returning id into g_inc;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', g_bank), (v_ta, 'client_money_bank', g_trust), (v_ta, 'ar_control', g_ar),
    (v_ta, 'insurer_payable', g_pay), (v_ta, 'unearned_commission', g_unear), (v_ta, 'commission_income', g_inc),
    (v_ta, 'insurer_claim_receivable', g_crec), (v_ta, 'client_claim_payable', g_cpay);

  -- Tenant B: bindable, but no claim roles mapped.
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '1100', 'AR Control', 'asset') returning id into gb_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '2010', 'Insurer Payable', 'liability') returning id into gb_pay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '2020', 'Unearned Commission', 'liability') returning id into gb_unear;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '4000', 'Commission Income', 'revenue') returning id into gb_inc;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_tb, 'ar_control', gb_ar), (v_tb, 'insurer_payable', gb_pay), (v_tb, 'unearned_commission', gb_unear), (v_tb, 'commission_income', gb_inc);

  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (v_tb, 'MOTOR', 'Motor B') returning id into v_pl_b;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct, claim_payment_mode)
    values (v_tb, 'BETAB', 'Beta B', 10, 'via_broker') returning id into v_insr_b;
  cb := ins_register_client('Beta Client', 'corporate', null, null, null, 'medium');
  pb := pg_temp.newpol(cb.id, v_insr_b, v_pl_b, 100000, 10);
  perform pg_temp.motor_cert(pb.id); pb := ins_bind_policy(pb.id);
  reset role;

  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (v_ta, 'MOTOR', 'Motor') returning id into v_pl;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (v_ta, 'ALPHA', 'Alpha', 10) returning id into v_alpha;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct, claim_payment_mode) values (v_ta, 'BETA', 'Beta', 10, 'via_broker') returning id into v_beta;
  c1 := ins_register_client('Acme Holdings', 'corporate', null, null, null, 'low');
  pa := pg_temp.newpol(c1.id, v_alpha, v_pl, 1000000, 10); perform pg_temp.motor_cert(pa.id); pa := ins_bind_policy(pa.id);
  pbk := pg_temp.newpol(c1.id, v_beta,  v_pl, 1000000, 10); perform pg_temp.motor_cert(pbk.id); pbk := ins_bind_policy(pbk.id);
  reset role;
  select party_account_id into v_pcli from ins_clients where id = c1.id;
  select party_account_id into v_pins from ins_insurers where id = v_beta;

  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'TRUST-UGX', 'client_money', 'UGX', g_trust) returning id into v_trust_bank;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'OPER-UGX', 'operating', 'UGX', g_bank) returning id into v_oper_bank;
  reset role;

  -------------------------------------------------------------------
  -- 1. The setting: default is insurer-direct; only the two modes exist
  -------------------------------------------------------------------
  perform pg_temp.assert((select claim_payment_mode from ins_insurers where id = v_alpha) = 'insurer_direct',
                         'a new insurer defaults to insurer-direct claim payment');
  perform pg_temp.assert((select claim_payment_mode from ins_insurers where id = v_beta) = 'via_broker',
                         'an insurer can be set to brokerage-managed');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_state(format('update ins_insurers set claim_payment_mode = ''cash'' where id = %L', v_alpha),
                               '23514', 'an unknown claim payment mode');
  reset role;
  raise notice 'PASS: the claim payment mode defaults to insurer-direct and is constrained';

  -------------------------------------------------------------------
  -- 2. Insurer-direct: approval posts nothing and records the mode
  -------------------------------------------------------------------
  select count(*) into v_before from journal_entries where tenant_id = v_ta;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  cl_d := pg_temp.newclaim(pa.id, 1000000);
  cl_d := pg_temp.approved(cl_d.id, 1000000);
  reset role;
  perform pg_temp.assert(cl_d.payment_mode = 'insurer_direct' and cl_d.status = 'approved' and cl_d.paid_amount = 0,
                         'approving an insurer-direct claim copies the mode and pays nothing');
  perform pg_temp.assert((select count(*) from journal_entries where tenant_id = v_ta) = v_before
                         and (select count(*) from fin_open_items where source_id = cl_d.id) = 0,
                         'insurer-direct approval posts no journal and opens no items');
  raise notice 'PASS: insurer-direct approval posts nothing';

  -------------------------------------------------------------------
  -- 3. Insurer-direct payments: authorization, validation, partial, full
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 100, current_date, ''REF'')', cl_d.id),
                               'INS_FORBIDDEN', 'a member recording a claim payment');
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 0, current_date, ''REF'')', cl_d.id), 'INS_AMOUNT', 'zero payment');
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 1000001, current_date, ''REF'')', cl_d.id), 'INS_AMOUNT', 'payment above the approved amount');
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 100, current_date + 1, ''REF'')', cl_d.id), 'INS_DATE', 'future payment date');
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 100, current_date - 5, ''REF'')', cl_d.id), 'INS_DATE', 'payment dated before the claim was notified');
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 100, current_date, '' '')', cl_d.id), 'INS_REFERENCE_REQUIRED', 'payment with no insurer reference');
  perform pg_temp.expect_error(format('select ins_record_claim_receipt(%L, %L, 100, current_date)', cl_d.id, v_trust_bank), 'INS_CLAIM_MODE', 'a receipt on an insurer-direct claim');
  perform pg_temp.expect_error(format('select ins_record_claim_payout(%L, %L, 100, current_date)', cl_d.id, v_trust_bank), 'INS_CLAIM_MODE', 'a payout on an insurer-direct claim');
  pay1 := ins_record_claim_payment(cl_d.id, 400000, current_date, 'ALPHA-ADV-001', 'First instalment');
  reset role;
  select * into cl_d from ins_claims where id = cl_d.id;
  perform pg_temp.assert(cl_d.paid_amount = 400000 and cl_d.status = 'approved' and cl_d.settled_at is null,
                         'a part payment raises paid but leaves the claim approved');
  perform pg_temp.assert((select count(*) from journal_entries where tenant_id = v_ta) = v_before
                         and pay1.kind = 'insurer_direct' and pay1.settlement_id is null,
                         'an insurer-direct payment posts nothing and has no settlement');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  pay2 := ins_record_claim_payment(cl_d.id, 600000, current_date, 'ALPHA-ADV-002');
  reset role;
  select * into cl_d from ins_claims where id = cl_d.id;
  perform pg_temp.assert(cl_d.paid_amount = 1000000 and cl_d.status = 'settled' and cl_d.settled_at is not null,
                         'paying the approved amount settles the claim by itself');
  perform pg_temp.assert((select count(*) from ins_claim_events where claim_id = cl_d.id and from_status = 'approved' and to_status = 'settled') = 1,
                         'the automatic settlement is in the claim history');
  perform pg_temp.assert(pg_temp.scalar(format('select held_for_client from ins_claim_cash_position where claim_id = %L', cl_d.id)) = 0
                         and pg_temp.scalar(format('select paid_by_insurer_direct from ins_claim_cash_position where claim_id = %L', cl_d.id)) = 1000000,
                         'cash position: 1,000,000 paid by the insurer direct, nothing held');
  raise notice 'PASS: insurer-direct payments, partial then full, settle the claim without touching the ledger';

  -------------------------------------------------------------------
  -- 4. Void an insurer-direct payment: the claim reopens for payment
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_claim_payment(%L, ''no'')', pay2.id), 'INS_REASON_REQUIRED', 'void with a short reason');
  pay2 := ins_void_claim_payment(pay2.id, 'Insurer reversed the transfer');
  perform pg_temp.expect_error(format('select ins_void_claim_payment(%L, ''Insurer reversed again'')', pay2.id), 'INS_ALREADY_VOID', 'voiding twice');
  reset role;
  select * into cl_d from ins_claims where id = cl_d.id;
  perform pg_temp.assert(pay2.status = 'void' and cl_d.status = 'approved' and cl_d.paid_amount = 400000 and cl_d.settled_at is null,
                         'voiding a payment on a settled claim returns it to approved with the lower paid amount');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  pay2 := ins_record_claim_payment(cl_d.id, 600000, current_date, 'ALPHA-ADV-003');
  reset role;
  select * into cl_d from ins_claims where id = cl_d.id;
  perform pg_temp.assert(cl_d.status = 'settled' and cl_d.paid_amount = 1000000, 'the replacement payment settles the claim again');
  raise notice 'PASS: voiding an insurer-direct payment reopens the claim and a new payment settles it';

  -------------------------------------------------------------------
  -- 5. "Settled" can no longer be set by hand; closed claims are final
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  cl_x := pg_temp.newclaim(pa.id, 500000);
  cl_x := pg_temp.approved(cl_x.id, 500000);
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''settled'')', cl_x.id), 'INS_CLAIM_PAYMENT_REQUIRED', 'settling an unpaid claim by hand');
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 100, current_date, ''REF'')',
                                      (pg_temp.newclaim(pa.id, 1)).id), 'INS_CLAIM_STATE', 'a payment on a claim that is not approved');
  cl_d := ins_transition_claim(cl_d.id, 'closed', 'File closed');
  perform pg_temp.expect_error(format('select ins_void_claim_payment(%L, ''Too late to change'')', pay2.id), 'INS_CLAIM_CLOSED', 'voiding a payment on a closed claim');
  reset role;
  raise notice 'PASS: manual settling is refused and a closed claim keeps its payments';

  -------------------------------------------------------------------
  -- 6. Brokerage-managed approval: accrual journal and two open items
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  cl_b := pg_temp.newclaim(pbk.id, 1000000);
  cl_b := pg_temp.approved(cl_b.id, 1000000);
  reset role;
  perform pg_temp.assert(cl_b.payment_mode = 'via_broker', 'approving a claim for a brokerage-managed insurer copies the mode');
  perform pg_temp.assert(not exists (select 1 from journal_entries where tenant_id = v_ta and source_type = 'ins_claim_accrual' and source_id = cl_b.id)
                         and not exists (select 1 from fin_open_items where source_id = cl_b.id),
                         'approval posts nothing: the claim is approved, pending settlement');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_recognise_claim_receivable(%L, null)', cl_b.id), 'INS_NOTE_REQUIRED',
                               'recognition needs the insurer confirmation');
  perform pg_temp.expect_error(format('select ins_record_claim_receipt(%L, %L, 100, current_date)', cl_b.id, v_trust_bank),
                               'INS_CLAIM_NOT_RECOGNISED', 'no receipt before the receivable is recognised');
  perform pg_temp.expect_error(format('select ins_record_claim_payout(%L, %L, 100, current_date)', cl_b.id, v_trust_bank),
                               'INS_CLAIM_NOT_RECOGNISED', 'no payout before the payable is recognised');
  cl_b := ins_recognise_claim_receivable(cl_b.id, 'ALPHA-CONF-1');
  perform pg_temp.expect_error(format('select ins_recognise_claim_receivable(%L, %L)', cl_b.id, 'ALPHA-CONF-2'), 'INS_CLAIM_RECOGNISED',
                               'a claim is recognised once');
  reset role;
  perform pg_temp.assert(cl_b.recognised_at is not null and cl_b.status = 'approved', 'recognition is recorded on the claim');
  select id into v_je from journal_entries where tenant_id = v_ta and source_type = 'ins_claim_accrual' and source_id = cl_b.id;
  perform pg_temp.assert(v_je is not null and pg_temp.je_lines(v_je) = 2 and pg_temp.je_bal(v_je) = 0
                         and pg_temp.je_net(v_je, g_crec) = 1000000 and pg_temp.je_net(v_je, g_cpay) = -1000000,
                         'accrual: Dr claims receivable, Cr claims payable, for the approved amount');
  select id into v_item_ins from fin_open_items where source_type = 'ins_claim_insurer' and source_id = cl_b.id;
  select id into v_item_cli from fin_open_items where source_type = 'ins_claim_client'  and source_id = cl_b.id;
  perform pg_temp.assert(v_item_ins is not null and v_item_cli is not null
                         and (select control_role from fin_open_items where id = v_item_ins) = 'insurer_claim_receivable'
                         and (select side from fin_open_items where id = v_item_ins) = 'receivable'
                         and (select party_account_id from fin_open_items where id = v_item_ins) = v_pins
                         and (select control_role from fin_open_items where id = v_item_cli) = 'client_claim_payable'
                         and (select side from fin_open_items where id = v_item_cli) = 'payable'
                         and (select party_account_id from fin_open_items where id = v_item_cli) = v_pcli
                         and (select amount from fin_open_items where id = v_item_ins) = 1000000
                         and (select amount from fin_open_items where id = v_item_cli) = 1000000,
                         'one receivable item against the insurer and one payable item to the client');
  perform pg_temp.assert(pg_temp.scalar(format('select due_from_insurer from ins_claim_cash_position where claim_id = %L', cl_b.id)) = 1000000,
                         'cash position: the insurer owes the full amount');
  raise notice 'PASS: approval posts nothing; recognition posts the accrual and opens both items';

  -------------------------------------------------------------------
  -- 7. The mode is a snapshot, and cannot be edited on the claim
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  update ins_insurers set claim_payment_mode = 'insurer_direct' where id = v_beta;
  perform pg_temp.flag_off();
  perform pg_temp.expect_error(format('update ins_claims set payment_mode = ''insurer_direct'' where id = %L', cl_b.id),
                               'INS_CLAIM_RPC_ONLY', 'editing the claim payment mode directly');
  reset role;
  perform pg_temp.assert((select payment_mode from ins_claims where id = cl_b.id) = 'via_broker',
                         'changing the insurer setting does not change a claim already approved');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  update ins_insurers set claim_payment_mode = 'via_broker' where id = v_beta;
  reset role;
  raise notice 'PASS: the payment mode is copied at approval and is not editable on the claim';

  -------------------------------------------------------------------
  -- 8. Controls: finance cannot bypass, funds must arrive before they go out
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform pg_temp.expect_error(format('select fin_record_settlement(%L, ''in'', %L, 100, current_date, %L::jsonb)',
                                      v_trust_bank, v_pins, jsonb_build_array(jsonb_build_object('open_item_id', v_item_ins, 'amount', 100))::text),
                               'settled from the claim', 'Finance settling a claim receivable from the generic screen');
  perform pg_temp.expect_error(format('select fin_record_settlement(%L, ''out'', %L, 100, current_date, %L::jsonb)',
                                      v_trust_bank, v_pcli, jsonb_build_array(jsonb_build_object('open_item_id', v_item_cli, 'amount', 100))::text),
                               'settled from the claim', 'Finance settling a claim payable from the generic screen');
  reset role;
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_record_claim_receipt(%L, %L, 100, current_date)', cl_b.id, v_trust_bank), 'INS_FORBIDDEN', 'a member recording a receipt');
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_record_claim_payout(%L, %L, 100, current_date)', cl_b.id, v_trust_bank),
                               'INS_CLAIM_FUNDS_NOT_RECEIVED', 'paying the client before the insurer has paid');
  perform pg_temp.expect_error(format('select ins_record_claim_receipt(%L, %L, 100, current_date)', cl_b.id, v_oper_bank),
                               'INS_BANK_KIND', 'receiving claim money into an operating account');
  perform pg_temp.expect_error(format('select ins_record_claim_receipt(%L, %L, 1000001, current_date)', cl_b.id, v_trust_bank),
                               'INS_AMOUNT', 'receiving more than the insurer owes');
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 100, current_date, ''REF'')', cl_b.id),
                               'INS_CLAIM_MODE', 'a direct payment on a brokerage-managed claim');
  reset role;
  raise notice 'PASS: claim items cannot be settled from Finance and funds must arrive before they are paid out';

  -------------------------------------------------------------------
  -- 9. Receipt then payout, with the ledger following each step
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  r1 := ins_record_claim_receipt(cl_b.id, v_trust_bank, 600000, current_date, 'BETA-RCPT-1', 'First remittance');
  reset role;
  perform pg_temp.assert(pg_temp.bal(v_ta, g_trust) = 600000 and pg_temp.bal(v_ta, g_crec) = 400000 and pg_temp.bal(v_ta, g_cpay) = -1000000
                         and r1.kind = 'insurer_receipt' and r1.settlement_id is not null
                         and (select direction from fin_settlements where id = r1.settlement_id) = 'in',
                         'receipt: Dr client money, Cr claims receivable; claims payable untouched');
  select * into cl_b from ins_claims where id = cl_b.id;
  perform pg_temp.assert(cl_b.paid_amount = 0 and cl_b.status = 'approved'
                         and pg_temp.scalar(format('select held_for_client from ins_claim_cash_position where claim_id = %L', cl_b.id)) = 600000
                         and pg_temp.scalar(format('select due_from_insurer from ins_claim_cash_position where claim_id = %L', cl_b.id)) = 400000,
                         'a receipt alone does not mark the client as paid; 600,000 is held for them');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_record_claim_payout(%L, %L, 700000, current_date)', cl_b.id, v_trust_bank),
                               'INS_CLAIM_FUNDS_NOT_RECEIVED', 'paying out more than has been received');
  o1 := ins_record_claim_payout(cl_b.id, v_trust_bank, 600000, current_date, 'BETA-OUT-1');
  reset role;
  perform pg_temp.assert(pg_temp.bal(v_ta, g_trust) = 0 and pg_temp.bal(v_ta, g_cpay) = -400000
                         and (select direction from fin_settlements where id = o1.settlement_id) = 'out',
                         'payout: Dr claims payable, Cr client money');
  select * into cl_b from ins_claims where id = cl_b.id;
  perform pg_temp.assert(cl_b.paid_amount = 600000 and cl_b.status = 'approved', 'the client has been paid 600,000 and the claim is still open');
  raise notice 'PASS: receipt and payout post to client money and the claim control accounts';

  -------------------------------------------------------------------
  -- 10. A receipt that has been paid out cannot be voided (either route)
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_claim_payment(%L, ''Wrong remittance'')', r1.id),
                               'INS_CLAIM_FUNDS_PAID_OUT', 'voiding a paid-out receipt from the claim');
  reset role;
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform pg_temp.expect_error(format('select fin_void_settlement(%L, ''Wrong remittance'')', r1.settlement_id),
                               'INS_CLAIM_FUNDS_PAID_OUT', 'voiding a paid-out receipt from Finance');
  reset role;
  perform pg_temp.assert((select status from fin_settlements where id = r1.settlement_id) = 'posted'
                         and (select status from ins_claim_payments where id = r1.id) = 'posted',
                         'a refused void leaves the receipt posted');
  raise notice 'PASS: money the brokerage has paid out cannot be un-received';

  -------------------------------------------------------------------
  -- 11. Finish the claim; void a payout; Finance voids a receipt
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  r2 := ins_record_claim_receipt(cl_b.id, v_trust_bank, 400000, current_date, 'BETA-RCPT-2');
  o2 := ins_record_claim_payout(cl_b.id, v_trust_bank, 400000, current_date, 'BETA-OUT-2');
  reset role;
  select * into cl_b from ins_claims where id = cl_b.id;
  perform pg_temp.assert(cl_b.status = 'settled' and cl_b.paid_amount = 1000000 and cl_b.settled_at is not null
                         and pg_temp.bal(v_ta, g_trust) = 0 and pg_temp.bal(v_ta, g_crec) = 0 and pg_temp.bal(v_ta, g_cpay) = 0,
                         'paying the client in full settles the claim and every claim account nets to zero');
  perform pg_temp.assert(pg_temp.scalar(format('select held_for_client from ins_claim_cash_position where claim_id = %L', cl_b.id)) = 0
                         and pg_temp.scalar(format('select due_from_insurer from ins_claim_cash_position where claim_id = %L', cl_b.id)) = 0,
                         'cash position: nothing held, nothing due');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  o2 := ins_void_claim_payment(o2.id, 'Client account details were wrong');
  reset role;
  select * into cl_b from ins_claims where id = cl_b.id;
  perform pg_temp.assert(o2.status = 'void' and (select status from fin_settlements where id = o2.settlement_id) = 'void'
                         and cl_b.status = 'approved' and cl_b.paid_amount = 600000
                         and pg_temp.bal(v_ta, g_trust) = 400000 and pg_temp.bal(v_ta, g_cpay) = -400000,
                         'voiding a payout reverses its journal and reopens the claim');
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform fin_void_settlement(r2.settlement_id, 'Receipt was posted twice');
  reset role;
  perform pg_temp.assert((select status from ins_claim_payments where id = r2.id) = 'void'
                         and pg_temp.scalar(format('select held_for_client from ins_claim_cash_position where claim_id = %L', cl_b.id)) = 0
                         and pg_temp.scalar(format('select due_from_insurer from ins_claim_cash_position where claim_id = %L', cl_b.id)) = 400000,
                         'Finance voiding a claim receipt keeps the claim record in step');
  raise notice 'PASS: voids from the claim and from Finance keep the claim, the ledger and the cash position consistent';

  -------------------------------------------------------------------
  -- 12. A missing posting rule stops brokerage-managed approval and leaves nothing
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  cl_t := pg_temp.newclaim(pb.id, 50000);
  perform ins_transition_claim(cl_t.id, 'assessing');
  perform pg_temp.jwt(u_appr_b);
  perform ins_transition_claim(cl_t.id, 'approved', null, 50000);
  perform pg_temp.jwt(u_mgr_b);
  perform pg_temp.expect_error(format('select ins_recognise_claim_receivable(%L, %L)', cl_t.id, 'BETA-CONF-1'),
                               'INS_POSTING_RULE_MISSING', 'recognition without the claim posting roles');
  reset role;
  perform pg_temp.assert((select status from ins_claims where id = cl_t.id) = 'approved'
                         and (select payment_mode from ins_claims where id = cl_t.id) = 'via_broker'
                         and (select recognised_at from ins_claims where id = cl_t.id) is null
                         and (select count(*) from fin_open_items where source_id = cl_t.id) = 0
                         and pg_temp.scalar(format('select count(*) from journal_entries where tenant_id = %L and source_type = ''ins_claim_accrual''', v_tb)) = 0,
                         'approval is allowed without the posting roles; a refused recognition leaves the items and the ledger untouched');
  raise notice 'PASS: approval needs no claim posting roles; recognition stops cleanly when they are missing';

  -------------------------------------------------------------------
  -- 12b. Segregation of duties and un-approval
  -------------------------------------------------------------------
  -- The registrant cannot approve their own claim.
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  cl_u := pg_temp.newclaim(pa.id, 300000);
  perform ins_transition_claim(cl_u.id, 'assessing', null);
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''approved'', ''ok'', 300000)', cl_u.id),
                               'INS_SEGREGATION', 'the registrant approving their own claim');
  perform pg_temp.assert((select status from ins_claims where id = cl_u.id) = 'assessing',
                         'a refused self-approval leaves the claim assessing');

  -- Another manager approves; the registrant then un-approves before anything is recognised or paid.
  perform pg_temp.jwt(u_appr);
  cl_u := ins_transition_claim(cl_u.id, 'approved', 'ok', 300000);
  perform pg_temp.jwt(u_mgr);
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'', null)', cl_u.id),
                               'INS_NOTE_REQUIRED', 'un-approving without a reason');
  perform pg_temp.jwt(u_mem);
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'', ''wrong amount'')', cl_u.id),
                               'INS_FORBIDDEN', 'a member un-approving a claim');
  perform pg_temp.jwt(u_mgr);
  cl_u := ins_transition_claim(cl_u.id, 'assessing', 'Wrong amount, reassessing');
  perform pg_temp.assert(cl_u.status = 'assessing' and cl_u.approved_amount is null and cl_u.payment_mode is null,
                         'un-approval clears the decision');
  perform pg_temp.assert(exists (select 1 from ins_claim_events
                                  where claim_id = cl_u.id and from_status = 'approved' and to_status = 'assessing'
                                    and note = 'Wrong amount, reassessing'),
                         'un-approval is recorded in the claim history');

  -- It can be approved again, with a new amount, by the approver.
  perform pg_temp.jwt(u_appr);
  cl_u := ins_transition_claim(cl_u.id, 'approved', 'ok', 150000);
  perform pg_temp.assert(cl_u.status = 'approved' and cl_u.approved_amount = 150000,
                         're-approval after un-approval takes the new amount');
  perform pg_temp.jwt(u_mgr);

  -- A payment blocks un-approval.
  r1 := ins_record_claim_payment(cl_u.id, 50000, current_date, 'ALPHA-UNAP-1');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'', ''change of mind'')', cl_u.id),
                               'INS_CLAIM_PAID', 'un-approving after a payment');

  -- A recognised receivable blocks un-approval. Recognition needs posting roles this fixture does not
  -- set up, so recognised_at is set directly as the owner to simulate it (no entries are involved here).
  cl_r := pg_temp.newclaim(pa.id, 100000);
  perform pg_temp.jwt(u_mgr);
  perform ins_transition_claim(cl_r.id, 'assessing', null);
  perform pg_temp.jwt(u_appr);
  cl_r := ins_transition_claim(cl_r.id, 'approved', 'ok', 100000);
  perform pg_temp.jwt(u_mgr);
  reset role;
  update ins_claims set recognised_at = now() where id = cl_r.id;
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'', ''change of mind'')', cl_r.id),
                               'INS_CLAIM_RECOGNISED', 'un-approving a recognised claim');
  reset role;
  raise notice 'PASS: segregation refuses self-approval; un-approval needs a manager, a reason, and no recognition or payment';

  -------------------------------------------------------------------
  -- 13. Lockout, isolation, anon, roles and template
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_state(format('insert into ins_claim_payments (tenant_id, claim_id, kind, amount, payment_date) values (%L, %L, ''insurer_direct'', 1, current_date)', v_ta, cl_b.id),
                               '42501', 'writing a claim payment directly');
  perform pg_temp.expect_state(format('update ins_claim_payments set amount = 1 where id = %L', pay1.id), '42501', 'editing a claim payment directly');
  reset role;
  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  select count(*) into v_n from ins_claim_payments;
  perform pg_temp.assert(v_n = 0, 'tenant B sees none of tenant A''s claim payments');
  perform pg_temp.expect_error(format('select ins_record_claim_payment(%L, 100, current_date, ''REF'')', cl_x.id), 'INS_NOT_FOUND', 'tenant B recording against tenant A''s claim');
  perform pg_temp.expect_error(format('select ins_void_claim_payment(%L, ''Not your payment'')', pay1.id), 'INS_NOT_FOUND', 'tenant B voiding tenant A''s payment');
  reset role;
  set local role anon;
  perform pg_temp.expect_state(format('select ins_record_claim_payment(%L, 100, current_date, ''REF'')', cl_x.id), '42501', 'anon recording a payment');
  perform pg_temp.expect_state('select * from ins_claim_payments', '42501', 'anon reading claim payments');
  reset role;
  perform pg_temp.assert('insurer_claim_receivable' = any (platform_gl_posting_roles())
                         and 'client_claim_payable' = any (platform_gl_posting_roles())
                         and exists (select 1 from industry_template_items where template_key = 'insurance' and kind = 'posting_rule' and name = 'insurer_claim_receivable')
                         and exists (select 1 from industry_template_items where template_key = 'insurance' and kind = 'posting_rule' and name = 'client_claim_payable')
                         and exists (select 1 from industry_template_items where template_key = 'insurance' and kind = 'gl_account' and name = '1120')
                         and exists (select 1 from industry_template_items where template_key = 'insurance' and kind = 'gl_account' and name = '2030'),
                         'the two claim roles are platform roles and the insurance template carries their accounts and rules');
  raise notice 'PASS: direct writes are locked, tenants are isolated, anon is refused';

  raise notice 'ins_claim_payments: all assertions passed';
end
$$;

rollback;
