-- Phase A, A3 slice 3b: realised foreign-exchange gain and loss
-- (roles fx_gain_realised / fx_loss_realised, platform_fx_settlement,
-- platform_fx_realised_line, the per-line rate source in the gateway, and the cash/bank
-- posting trigger that settles at the invoice's original rate).
--
-- Covers: a receipt against a USD receivable books a realised gain; a payment against a USD
-- supplier invoice books a realised loss; partial payments each settle at the original rate
-- and the control account nets to zero in USD and base; same-rate settlement books no FX
-- line; a currency mismatch is refused and keeps nothing; payroll in a foreign currency is
-- refused while UGX payroll is unchanged; an expense slip paid in USD is not a settlement;
-- the calculation and its sign; a company without the role is refused; the per-line rate
-- source only accepts a rate the referenced entry used and is cleared afterwards; voiding a
-- settlement reverses it exactly.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

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

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.flush() returns void language plpgsql as $$
begin
  set constraints all immediate;
  set constraints all deferred;
end $$;

create function pg_temp.lines_of(p_source uuid) returns text language sql as $$
  select coalesce(string_agg(format('%s=%s/%s %s@%s base %s/%s', a.account_code, l.debit, l.credit, l.currency, l.fx_rate,
                                    l.base_debit, l.base_credit), ' | ' order by a.account_code, l.debit), '(none)')
  from journal_entries e
  join journal_entry_lines l on l.journal_entry_id = e.id
  join gl_accounts a on a.id = l.gl_account_id
  where e.source_id = p_source
$$;

-- Net of one account over the journals of the given source documents: USD net and base net.
create function pg_temp.net_of(p_account uuid, p_sources uuid[], out ccy_net numeric, out base_net numeric)
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0), coalesce(sum(l.base_debit - l.base_credit), 0)
  from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
  where e.source_id = any (p_sources) and l.gl_account_id = p_account
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  u uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  org uuid; cc uuid;
  g_exp uuid; g_ap uuid; g_ar uuid; g_rev uuid; g_bank uuid; g_rnd uuid; g_gain uuid; g_loss uuid; g_sal uuid;
  reg_id uuid; fx_id uuid;
  ri uuid; rc uuid; si uuid; si_b uuid; si_ugx uuid; p1 uuid; p2 uuid; p_same uuid; si_same uuid; slip uuid; run uuid;
  e_inv uuid; e_p1 uuid; v_rev uuid; v_line jsonb; r record; n integer;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Realised FX Co'), (tb, 'No Roles Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated', 'rf-' || u || '@test.local',
          extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}',
          now(), now(), '', '');
  insert into app_users (id, tenant_id, name, email, is_company_admin)
  values (u, ta, 'RF Admin', 'rf-' || u || '@test.local', true);
  insert into finance_team_members (tenant_id, user_id, role) values (ta, u, 'finance');
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);

  insert into organizations (tenant_id, company_code, site_name) values (ta, 'RF', 'Site') returning id into org;
  insert into cost_centers (tenant_id, name) values (ta, 'CC') returning id into cc;

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank', 'asset'), (ta, '1100', 'AR', 'asset'), (ta, '2000', 'AP', 'liability'),
    (ta, '2300', 'Salaries payable', 'liability'),
    (ta, '4000', 'Revenue', 'revenue'), (ta, '5000', 'Expense', 'expense'), (ta, '6999', 'FX rounding', 'expense'),
    (ta, '4900', 'Realised FX gain', 'revenue'), (ta, '5910', 'Realised FX loss', 'expense');
  select id into g_bank from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into g_ar   from gl_accounts where tenant_id = ta and account_code = '1100';
  select id into g_ap   from gl_accounts where tenant_id = ta and account_code = '2000';
  select id into g_sal  from gl_accounts where tenant_id = ta and account_code = '2300';
  select id into g_rev  from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into g_exp  from gl_accounts where tenant_id = ta and account_code = '5000';
  select id into g_rnd  from gl_accounts where tenant_id = ta and account_code = '6999';
  select id into g_gain from gl_accounts where tenant_id = ta and account_code = '4900';
  select id into g_loss from gl_accounts where tenant_id = ta and account_code = '5910';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta, 'bank', g_bank), (ta, 'ar_control', g_ar), (ta, 'ap_control', g_ap), (ta, 'salaries_payable', g_sal),
    (ta, 'default_revenue', g_rev), (ta, 'default_expense', g_exp), (ta, 'fx_rounding', g_rnd),
    (ta, 'fx_gain_realised', g_gain), (ta, 'fx_loss_realised', g_loss);

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3800, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  -------------------------------------------------------------------
  -- 1. The calculation and its sign
  -------------------------------------------------------------------
  select * into r from platform_fx_settlement(ta, 'USD', 333.33, 3700, current_date, true);
  perform pg_temp.assert(r.settlement_rate = 3800 and r.base_original = 1233321.00 and r.base_settlement = 1266654.00 and r.result = -33333.00,
    format('payment calculation wrong: rate %s orig %s settle %s result %s', r.settlement_rate, r.base_original, r.base_settlement, r.result));
  select * into r from platform_fx_settlement(ta, 'USD', 333.33, 3700, current_date, false);
  perform pg_temp.assert(r.result = 33333.00, format('receipt calculation must be a gain of 33,333, got %s', r.result));
  select * into r from platform_fx_settlement(ta, 'USD', 500, 3800, current_date, true);
  perform pg_temp.assert(r.result = 0, 'same rate must give a zero result');
  perform pg_temp.expect_error(format($q$select * from platform_fx_settlement(%L, 'USD', -1, 3700, current_date, true)$q$, ta),
    'FX_ARGUMENT', 'negative amount');
  perform pg_temp.expect_error(format($q$select * from platform_fx_settlement(%L, 'USD', 1, 0, current_date, true)$q$, ta),
    'FX_ARGUMENT', 'zero original rate');
  raise notice 'PASS: the settlement calculation rounds like the ledger and signs gain and loss correctly';

  -------------------------------------------------------------------
  -- 2. The realised line, and the role being required
  -------------------------------------------------------------------
  perform pg_temp.assert(platform_fx_realised_line(ta, 0) is null, 'a zero result needs no line');
  v_line := platform_fx_realised_line(ta, -250.5);
  perform pg_temp.assert((v_line ->> 'gl_account_id')::uuid = g_loss and (v_line ->> 'debit')::numeric = 250.5
                         and (v_line ->> 'credit')::numeric = 0 and v_line ->> 'currency' = 'UGX',
    format('loss line wrong: %s', v_line));
  v_line := platform_fx_realised_line(ta, 99);
  perform pg_temp.assert((v_line ->> 'gl_account_id')::uuid = g_gain and (v_line ->> 'credit')::numeric = 99 and (v_line ->> 'debit')::numeric = 0,
    format('gain line wrong: %s', v_line));
  perform pg_temp.expect_error(format('select platform_fx_realised_line(%L, 10)', tb), 'FX_REALISED_ACCOUNT_MISSING', 'company with no gain role');
  perform pg_temp.expect_error(format('select platform_fx_realised_line(%L, -10)', tb), 'FX_REALISED_ACCOUNT_MISSING', 'company with no loss role');
  raise notice 'PASS: gain is a credit and loss a debit in the functional currency; a missing role is refused';

  -------------------------------------------------------------------
  -- 3. A receipt against a USD receivable books a realised gain
  -------------------------------------------------------------------
  insert into receivable_invoices (tenant_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number)
    values (ta, 'AR-RF-1', current_date - 1, 1000, 0, 'USD', org, 'PRF-RF1') returning id into ri;
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
    values (ta, 'receipt', 'bank', 'receivable_invoice', ri, 1000, 'USD', current_date) returning id into rc;
  perform pg_temp.flush();
  perform pg_temp.assert(exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                 where e.source_id = rc and l.gl_account_id = g_ar and l.credit = 1000 and l.fx_rate = 3700 and l.base_credit = 3700000),
    format('receivable side must be USD 1,000 at the invoice''s 3700: %s', pg_temp.lines_of(rc)));
  perform pg_temp.assert(exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                 where e.source_id = rc and l.gl_account_id = g_bank and l.debit = 1000 and l.fx_rate = 3800 and l.base_debit = 3800000),
    'bank side must be USD 1,000 at today''s 3800');
  perform pg_temp.assert(exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                 where e.source_id = rc and l.gl_account_id = g_gain and l.credit = 100000 and l.currency = 'UGX'),
    'a realised gain of UGX 100,000 must be booked');
  select * into r from pg_temp.net_of(g_ar, array[ri, rc]);
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0, format('receivables must net to zero in USD and base, got %s / %s', r.ccy_net, r.base_net));
  raise notice 'PASS: a USD receipt at a higher rate books a realised gain and receivables net to zero';

  -------------------------------------------------------------------
  -- 4. Partial payments each settle at the original rate
  -------------------------------------------------------------------
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
    values (ta, cc, 'USD-RF-1', current_date - 1, 1000, 0, 0, 'USD', org, 'PRF-RF2') returning id into si;
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
    values (ta, 'payment', 'bank', 'supplier_invoice', si, 400, 'USD', current_date) returning id into p1;
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
    values (ta, 'payment', 'bank', 'supplier_invoice', si, 600, 'USD', current_date) returning id into p2;
  perform pg_temp.flush();
  select * into r from pg_temp.net_of(g_ap, array[si, p1, p2]);
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0, format('payables must net to zero after two partial payments, got %s / %s', r.ccy_net, r.base_net));
  select coalesce(sum(l.debit), 0) into r from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
   where e.source_id in (p1, p2) and l.gl_account_id = g_loss;
  perform pg_temp.assert(r.coalesce = 100000, format('the two losses must total 100,000 (40,000 + 60,000), got %s', r.coalesce));
  raise notice 'PASS: two partial payments each settle at the original rate; losses total 100,000; payables net to zero';

  -------------------------------------------------------------------
  -- 5. Same-rate settlement books no FX line
  -------------------------------------------------------------------
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
    values (ta, cc, 'USD-RF-SAME', current_date - 1, 500, 0, 0, 'USD', org, 'PRF-RF3') returning id into si_same;
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
    values (ta, 'payment', 'bank', 'supplier_invoice', si_same, 500, 'USD', current_date - 1) returning id into p_same;
  perform pg_temp.flush();
  select count(*) into n from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id where e.source_id = p_same;
  perform pg_temp.assert(n = 2, format('a same-rate settlement must have exactly two lines, found %s: %s', n, pg_temp.lines_of(p_same)));
  raise notice 'PASS: settling at the booked rate books no gain or loss line';

  -------------------------------------------------------------------
  -- 6. Currency mismatches are refused and keep nothing
  -------------------------------------------------------------------
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
    values (ta, cc, 'UGX-RF-1', current_date - 1, 100000, 0, 0, 'UGX', org, 'PRF-RF4') returning id into si_ugx;
  perform pg_temp.expect_error(format(
    $q$insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, transaction_date)
       values (%L, 'payment', 'bank', 'supplier_invoice', %L, 100, current_date)$q$, ta, si),
    'CASH_CURRENCY_MISMATCH', 'UGX payment against a USD invoice');
  perform pg_temp.expect_error(format(
    $q$insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
       values (%L, 'payment', 'bank', 'supplier_invoice', %L, 100, 'USD', current_date)$q$, ta, si_ugx),
    'CASH_CURRENCY_MISMATCH', 'USD payment against a UGX invoice');
  perform pg_temp.assert((select count(*) from cash_bank_transactions where reference_id = si_ugx) = 0 and
                         (select count(*) from cash_bank_transactions where reference_id = si and amount = 100) = 0,
    'a refused transaction must leave no row behind');
  raise notice 'PASS: a payment in the wrong currency for its invoice is refused and keeps nothing';

  -------------------------------------------------------------------
  -- 7. Payroll and expense slips
  -------------------------------------------------------------------
  run := gen_random_uuid();
  perform pg_temp.expect_error(format(
    $q$insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
       values (%L, 'payment', 'bank', 'payroll_run', %L, 100, 'USD', current_date)$q$, ta, run),
    'CASH_PAYROLL_CURRENCY', 'payroll payment in USD');
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, transaction_date)
    values (ta, 'payment', 'bank', 'payroll_run', run, 100000, current_date);
  perform pg_temp.flush();
  perform pg_temp.assert(exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                 where e.source_id = (select id from cash_bank_transactions where reference_id = run) and l.gl_account_id = g_sal and l.currency = 'UGX' and l.fx_rate = 1),
    'a UGX payroll payment must post as before');
  slip := gen_random_uuid();
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
    values (ta, 'payment', 'bank', 'expenditure_slip', slip, 50, 'USD', current_date) returning id into p1;
  perform pg_temp.flush();
  perform pg_temp.assert(pg_temp.lines_of(p1) like '%USD@3800%' and pg_temp.lines_of(p1) not like '%UGX%',
    format('an expense paid in USD is recognised at the payment-date rate with no gain or loss line: %s', pg_temp.lines_of(p1)));
  raise notice 'PASS: payroll in a foreign currency is refused; an expense slip is not a settlement';

  -------------------------------------------------------------------
  -- 8. Voiding a settlement reverses it exactly
  -------------------------------------------------------------------
  select id into e_p1 from journal_entries where source_id = p2 and source_type = 'cash_bank_transaction';
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into v_rev from void_journal_entry(e_p1, 'void the 600 payment test');
  reset role;
  perform pg_temp.flush();
  select coalesce(sum(l.base_debit - l.base_credit), 0) as base_net, coalesce(sum(l.debit - l.credit) filter (where l.currency = 'USD'), 0) as usd_net
    into r from journal_entry_lines l where l.journal_entry_id in (e_p1, v_rev);
  perform pg_temp.assert(r.base_net = 0 and r.usd_net = 0, format('voided settlement plus its reversal must net to zero, got %s base / %s USD', r.base_net, r.usd_net));
  perform pg_temp.assert((select coalesce(sum(l.base_debit - l.base_credit), 0) from journal_entry_lines l where l.journal_entry_id in (e_p1, v_rev) and l.gl_account_id = g_loss) = 0,
    'the realised loss must be reversed too');
  raise notice 'PASS: voiding a settlement reverses currency, rates and the realised line exactly';

  -------------------------------------------------------------------
  -- 9. The per-line rate source accepts only rates the referenced entry used
  -------------------------------------------------------------------
  select id into e_inv from journal_entries where source_id = si and source_type = 'supplier_invoice';
  perform pg_temp.expect_error(format(
    $q$select post_journal_entry(%L, 'manual', null, current_date, 'bad rate source', %L::jsonb)$q$,
    ta, jsonb_build_array(
      jsonb_build_object('gl_account_id', g_ap, 'debit', 1, 'currency', 'USD', 'rate_from_entry', e_inv, 'fx_rate', 1234),
      jsonb_build_object('gl_account_id', g_bank, 'credit', 1, 'currency', 'USD'))::text),
    'JOURNAL_LINE_RATE', 'a rate the referenced entry never used');
  perform pg_temp.expect_error(format(
    $q$select post_journal_entry(%L, 'manual', null, current_date, 'foreign entry', %L::jsonb)$q$,
    tb, jsonb_build_array(
      jsonb_build_object('gl_account_id', g_ap, 'debit', 1, 'currency', 'USD', 'rate_from_entry', e_inv, 'fx_rate', 3700))::text),
    'not authorized to post journals for this tenant', 'posting for another company');
  perform pg_temp.assert(coalesce(current_setting('fin.rate_from', true), '') = '', 'the per-line rate source must be cleared after the gateway call');
  perform pg_temp.assert(not exists (select 1 from journal_entries where description = 'bad rate source'), 'a refused posting must leave no entry');
  raise notice 'PASS: the per-line rate source only accepts a rate the referenced entry used and is cleared afterwards';
end $$;

do $$ begin raise notice 'PASS: realised foreign exchange (A3 slice 3b) tests'; end $$;

rollback;
