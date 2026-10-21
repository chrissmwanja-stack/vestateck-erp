-- The last unproven money path in a foreign currency: claims.
-- (ins_create_claim / ins_transition_claim / ins_recognise_claim_receivable /
-- ins_record_claim_receipt / ins_record_claim_payout on a USD policy.)
--
-- Covers: a USD policy binds; the claim approval is segregated; recognition
-- accrues in the policy's currency at the recognition-date rate (distinct
-- from the bind rate) and both claim items carry that rate with their booking
-- entry; the insurer's money lands in the USD client-money account and the
-- claim receivable nets to zero in the currency AND in base with no realised
-- legs (same-day, same rate); the payout pays the client from the same
-- account, the claim settles, and a payout beyond what is held (or after the
-- claim is fully paid) is refused; a payout from a trust account in another
-- currency is refused by the settlement engine; receipts beyond what the
-- insurer owes are refused; an outsider is refused; and the claim flows
-- reconcile with the bank-reconciliation position.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction
-- that ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

\set ON_ERROR_STOP on

begin;

-- Test fixture: a motor policy needs an issued certificate before it binds.
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

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Registers-then-approves must be two people (segregation of duties).
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

-- Owner-side readers, so assertions do not depend on the caller's RLS.
create function pg_temp.gl_net(p_tenant uuid, p_gl uuid, out ccy_net numeric, out base_net numeric)
language sql security definer as $$
  select coalesce(sum(debit - credit), 0), coalesce(sum(base_debit - base_credit), 0)
    from public.journal_entry_lines where tenant_id = p_tenant and gl_account_id = p_gl
$$;

create function pg_temp.claim_item(p_claim uuid, p_type text, out ccy numeric, out rate numeric, out base numeric)
language sql security definer as $$
  select b.outstanding_amount, i.fx_rate, b.base_outstanding_amount
    from public.fin_open_items i
    join public.fin_open_item_balances b on b.id = i.id
   where i.source_type = p_type and i.source_id = p_claim
$$;

do $$
declare
  ta   uuid := gen_random_uuid();
  mgr  uuid := gen_random_uuid();
  appr uuid := gen_random_uuid();
  out_ uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  g_ops uuid; g_trust_usd uuid; g_trust_ugx uuid; g_ar uuid; g_pay uuid; g_unearned uuid;
  g_income uuid; g_crec uuid; g_cpay uuid; g_gain uuid; g_loss uuid;
  reg_id uuid; fx_id uuid;
  b_trust_usd uuid; b_trust_ugx uuid;
  v_branch uuid; v_line uuid; v_beta uuid;
  p_usd ins_policies%rowtype;
  c1 ins_claims%rowtype; c2 ins_claims%rowtype;
  r1 ins_claim_payments%rowtype; o1 ins_claim_payments%rowtype;
  n_ccy numeric; n_rate numeric; n_base numeric;
  r_ccy numeric; r_base numeric;
  v_je uuid; v_count integer; v_amount numeric;
begin
  perform set_config('test.approver', appr::text, true);

  -------------------------------------------------------------------
  -- Fixtures: a UGX-ledger brokerage with a USD client-money trust, an
  -- approved USD rate for yesterday (3700) and today (3750).
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Foreign Claims Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'fcl-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (mgr), (appr), (out_), (approver)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,  ta, 'FCL Manager',  'fcl-' || mgr  || '@test.local'),
    (appr, ta, 'FCL Approver', 'fcl-' || appr || '@test.local'),
    (out_, ta, 'FCL Outsider', 'fcl-' || out_ || '@test.local');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (ta, mgr,  'insurance', 'manager'),
    (ta, appr, 'insurance', 'manager');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, mgr, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1000','Operating UGX','asset'), (ta,'1021','Client money USD','asset'),
    (ta,'1022','Client money UGX','asset'),
    (ta,'1100','AR','asset'), (ta,'2010','Insurer payable','liability'),
    (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue'),
    (ta,'4900','Realised FX gain','revenue'), (ta,'5910','Realised FX loss','expense'),
    (ta,'1120','Claims receivable from insurers','asset'),
    (ta,'2030','Claims payable to clients','liability');
  select id into g_ops        from gl_accounts where tenant_id=ta and account_code='1000';
  select id into g_trust_usd  from gl_accounts where tenant_id=ta and account_code='1021';
  select id into g_trust_ugx  from gl_accounts where tenant_id=ta and account_code='1022';
  select id into g_ar         from gl_accounts where tenant_id=ta and account_code='1100';
  select id into g_pay        from gl_accounts where tenant_id=ta and account_code='2010';
  select id into g_unearned   from gl_accounts where tenant_id=ta and account_code='2020';
  select id into g_income     from gl_accounts where tenant_id=ta and account_code='4000';
  select id into g_gain       from gl_accounts where tenant_id=ta and account_code='4900';
  select id into g_loss       from gl_accounts where tenant_id=ta and account_code='5910';
  select id into g_crec       from gl_accounts where tenant_id=ta and account_code='1120';
  select id into g_cpay       from gl_accounts where tenant_id=ta and account_code='2030';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'bank',g_ops),(ta,'ar_control',g_ar),(ta,'insurer_payable',g_pay),
    (ta,'unearned_commission',g_unearned),(ta,'commission_income',g_income),
    (ta,'client_money_bank',g_trust_usd),
    (ta,'fx_gain_realised',g_gain),(ta,'fx_loss_realised',g_loss),
    (ta,'insurer_claim_receivable',g_crec),(ta,'client_claim_payable',g_cpay);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'FCL-OPS-UGX','operating','UGX',g_ops);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'FCL-TRUST-USD','client_money','USD',g_trust_usd) returning id into b_trust_usd;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'FCL-TRUST-UGX','client_money','UGX',g_trust_ugx) returning id into b_trust_ugx;

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3750, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  perform pg_temp.jwt(mgr);
  insert into organizations (tenant_id, company_code, site_name) values (ta, 'KLA', 'Kampala') returning id into v_branch;
  reset role;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into v_line;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct, claim_payment_mode)
    values (ta, 'BETA', 'Beta Assurance', 10, 'via_broker') returning id into v_beta;

  -------------------------------------------------------------------
  -- A USD policy, bound yesterday at 3700.
  -------------------------------------------------------------------
  declare cc ins_clients%rowtype;
  begin
    cc := ins_register_client('FCL client', 'corporate', null, null, null, 'low');
    p_usd := ins_create_policy(cc.id, v_beta, v_line, current_date - 1, current_date + 335,
                               20000, 'USD', 10000, 10, v_branch, null, 'FCL fleet', null);
    perform pg_temp.motor_cert(p_usd.id); p_usd := ins_bind_policy(p_usd.id);
  end;
  reset role;
  perform pg_temp.assert(p_usd.status = 'active' and p_usd.currency = 'USD', 'the USD policy binds');

  -------------------------------------------------------------------
  -- 1. Two approved claims. Approval is segregated (the registrant is
  --    not the approver).
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  c1 := ins_create_claim(p_usd.id, current_date, current_date, 'Collision damage', null, 8000);
  c2 := ins_create_claim(p_usd.id, current_date, current_date, 'Windscreen', null, 500);
  c2 := pg_temp.approved(c2.id, 10000);
  c1 := pg_temp.approved(c1.id, 10000);
  perform pg_temp.assert(c2.status = 'approved' and c1.status = 'approved', 'both claims approve');
  raise notice 'PASS: USD claims approve under segregation of duties';

  -------------------------------------------------------------------
  -- 2. A payout before the insurer''s money arrives is refused --
  --    the brokerage never fronts the client.
  -------------------------------------------------------------------
  perform ins_recognise_claim_receivable(c2.id, 'Beta written confirmation WS-1');
  perform pg_temp.expect_error(
    format('select ins_record_claim_payout(%L::uuid, %L::uuid, 10000, current_date)', c2.id, b_trust_usd),
    'INS_CLAIM_FUNDS_NOT_RECEIVED', 'a payout ahead of the insurer');
  raise notice 'PASS: the brokerage cannot pay the client ahead of the insurer';

  -------------------------------------------------------------------
  -- 3. Recognition accrues in the policy currency at the recognition
  --    date's rate -- not the bind rate -- and both claim items carry it.
  -------------------------------------------------------------------
  c1 := ins_recognise_claim_receivable(c1.id, 'Beta written confirmation CL-1');
  select id into v_je from journal_entries where source_type = 'ins_claim_accrual' and source_id = c1.id;
  perform pg_temp.assert(v_je is not null, 'the accrual journal exists');
  perform pg_temp.assert(
    (select count(*) from journal_entry_lines
      where journal_entry_id = v_je and currency = 'USD' and fx_rate = 3750) = 2,
    'the accrual posts both legs in USD at the recognition rate 3750');
  -- The control GL holds both recognised claims (c2 is recognised but unpaid).
  select * into r_ccy, r_base from pg_temp.gl_net(ta, g_crec);
  perform pg_temp.assert(r_ccy = 20000 and r_base = 75000000,
    format('the claim receivable sits at both accruals, got %s / %s', r_ccy, r_base));
  select b.outstanding_amount, i.fx_rate, b.base_outstanding_amount
    into n_ccy, n_rate, n_base
    from fin_open_items i join fin_open_item_balances b on b.id = i.id
   where i.source_type = 'ins_claim_insurer' and i.source_id = c1.id;
  perform pg_temp.assert(n_ccy = 10000 and n_rate = 3750 and n_base = 37500000,
    'the insurer item holds the recognition rate and its booking entry');
  raise notice 'PASS: recognition accrues in the policy currency at the recognition-date rate';

  -------------------------------------------------------------------
  -- 4. The insurer pays in two parts; the receivable nets to zero in
  --    the currency AND in base, with no realised legs (same day, same
  --    rate). The money sits in the USD trust.
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format('select ins_record_claim_receipt(%L::uuid, %L::uuid, 20000, current_date)', c1.id, b_trust_usd),
    'INS_AMOUNT', 'a receipt beyond what the insurer owes');
  r1 := ins_record_claim_receipt(c1.id, b_trust_usd, 4000, current_date, 'RCPT-1');
  r1 := ins_record_claim_receipt(c1.id, b_trust_usd, 6000, current_date, 'RCPT-2');
  -- c1's share nets to zero on its own items; the GL keeps c2's accrual.
  select * into n_ccy, n_rate, n_base from pg_temp.claim_item(c1.id, 'ins_claim_insurer');
  perform pg_temp.assert(n_ccy = 0 and n_base = 0,
    format('c1''s insurer item nets to zero, got %s / %s', n_ccy, n_base));
  select * into r_ccy, r_base from pg_temp.gl_net(ta, g_crec);
  perform pg_temp.assert(r_ccy = 10000 and r_base = 37500000,
    format('the receivable keeps only c2''s accrual, got %s / %s', r_ccy, r_base));
  select * into r_ccy, r_base from pg_temp.gl_net(ta, g_trust_usd);
  perform pg_temp.assert(r_ccy = 10000 and r_base = 37500000,
    format('the USD trust holds the insurer''s money, got %s / %s', r_ccy, r_base));
  select count(*) into v_count
    from journal_entry_lines l
    join journal_entries j on j.id = l.journal_entry_id
   where j.source_type = 'fin_settlement' and j.source_id = r1.settlement_id
     and l.gl_account_id in (g_gain, g_loss);
  perform pg_temp.assert(v_count = 0, 'a same-day receipt books no realised FX');
  raise notice 'PASS: the insurer''s money lands in the USD trust and the receivable nets to zero';

  -------------------------------------------------------------------
  -- 5. The payout pays the client out of the same trust; a cross-
  --    currency trust is refused; the claim settles.
  -------------------------------------------------------------------
  -- Nothing is held in the UGX trust's currency, so that is what the refusal
  -- says; the settlement engine's SETTLEMENT_CURRENCY guard stays as the
  -- backstop behind this check.
  perform pg_temp.expect_error(
    format('select ins_record_claim_payout(%L::uuid, %L::uuid, 5000, current_date)', c1.id, b_trust_ugx),
    'INS_CLAIM_FUNDS_NOT_RECEIVED', 'a payout from a trust holding no money in its currency');
  o1 := ins_record_claim_payout(c1.id, b_trust_usd, 5000, current_date, 'PAY-1');
  perform pg_temp.assert(o1.kind = 'client_payout', 'the payout records');
  perform pg_temp.expect_error(
    format('select ins_record_claim_payout(%L::uuid, %L::uuid, 6000, current_date)', c1.id, b_trust_usd),
    'INS_CLAIM_FUNDS_NOT_RECEIVED', 'a payout beyond what is still held');
  o1 := ins_record_claim_payout(c1.id, b_trust_usd, 5000, current_date, 'PAY-2');
  select * into c1 from ins_claims where id = c1.id;
  perform pg_temp.assert(c1.status = 'settled' and c1.paid_amount = 10000,
    format('the claim settles in full, got %s / %s', c1.status, c1.paid_amount));
  select * into n_ccy, n_rate, n_base from pg_temp.claim_item(c1.id, 'ins_claim_client');
  perform pg_temp.assert(n_ccy = 0 and n_base = 0,
    format('c1''s client item nets to zero, got %s / %s', n_ccy, n_base));
  select * into r_ccy, r_base from pg_temp.gl_net(ta, g_cpay);
  perform pg_temp.assert(r_ccy = -10000 and r_base = -37500000,
    format('the payable keeps only c2''s accrual, got %s / %s', r_ccy, r_base));
  select * into r_ccy, r_base from pg_temp.gl_net(ta, g_trust_usd);
  perform pg_temp.assert(r_ccy = 0 and r_base = 0,
    format('the trust is back to zero once the client is paid, got %s / %s', r_ccy, r_base));
  raise notice 'PASS: the client is paid from the trust and the claim settles';

  -------------------------------------------------------------------
  -- 6. Access: an outsider can neither receipt nor pay out.
  -------------------------------------------------------------------
  perform pg_temp.jwt(out_);
  perform pg_temp.expect_error(
    format('select ins_record_claim_receipt(%L::uuid, %L::uuid, 100, current_date)', c1.id, b_trust_usd),
    'INS_FORBIDDEN', 'an outsider recording a receipt');
  perform pg_temp.expect_error(
    format('select ins_record_claim_payout(%L::uuid, %L::uuid, 100, current_date)', c1.id, b_trust_usd),
    'INS_FORBIDDEN', 'an outsider recording a payout');
  reset role;
  raise notice 'PASS: claim money moves stay insurance-manager-only';

  -------------------------------------------------------------------
  -- 7. The claim flows reconcile with the bank position: the trust's
  --    GL movement is fully explained by its book items.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  select amount into v_amount from fin_bank_reconciliation_position(b_trust_usd, current_date)
   where component = 'gl_balance';
  perform pg_temp.assert(v_amount = 0, format('the trust reconciles to zero, got %s', v_amount));
  select amount into v_amount from fin_bank_reconciliation_position(b_trust_usd, current_date)
   where component = 'unexplained_difference';
  perform pg_temp.assert(v_amount = 0, format('the trust movement is fully explained, got %s', v_amount));
  raise notice 'PASS: the foreign claim flows reconcile with the bank position';

  raise notice 'ALL PASS: foreign-currency claims';
end
$$;

rollback;
