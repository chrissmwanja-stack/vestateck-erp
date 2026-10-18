-- Phase A, A3 slice 3a: procurement and cash posting triggers carry currency
-- (trg_post_supplier_invoice, trg_post_receivable_invoice, trg_post_cash_bank_transaction).
--
-- Covers: the reproduced bug (a USD 1,000 supplier invoice posted as UGX 1,000) now posts
-- USD 1,000 at the approved rate; UGX and default-currency documents post exactly as before;
-- VAT and withholding lines carry the currency; receivables and cash/bank transactions do
-- too; rounding works through the triggers; a missing rate or a stale rate refuses the
-- insert and keeps nothing; and the KNOWN LIMIT (a foreign invoice paid at a different rate
-- leaves a base residue on the control account until realised gain/loss exists, slice 3b).
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

-- Flush the deferred balance/rounding checks, then go back to deferred.
create function pg_temp.flush() returns void language plpgsql as $$
begin
  set constraints all immediate;
  set constraints all deferred;
end $$;

-- Lines of the journal posted for a source document, as 'account=debit/credit ccy@rate base d/c' text.
create function pg_temp.lines_of(p_source uuid) returns text language sql as $$
  select coalesce(string_agg(format('%s=%s/%s %s@%s base %s/%s%s', a.account_code, l.debit, l.credit, l.currency, l.fx_rate,
                                    l.base_debit, l.base_credit, case when l.is_rounding then ' R' else '' end),
                             ' | ' order by a.account_code, l.is_rounding), '(none)')
  from journal_entries e
  join journal_entry_lines l on l.journal_entry_id = e.id
  join gl_accounts a on a.id = l.gl_account_id
  where e.source_id = p_source
$$;

-- Net (debit minus credit) of one account, in base and in a given currency.
create function pg_temp.net(p_tenant uuid, p_code text, p_ccy text, out base_net numeric, out ccy_net numeric)
language sql as $$
  select coalesce(sum(l.base_debit - l.base_credit), 0),
         coalesce(sum(l.debit - l.credit) filter (where l.currency = p_ccy), 0)
  from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
  where l.tenant_id = p_tenant and a.account_code = p_code
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  u uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  org uuid; cc uuid;
  g_exp uuid; g_ap uuid; g_ar uuid; g_rev uuid; g_vatin uuid; g_vatout uuid; g_bank uuid; g_rnd uuid;
  reg_id uuid; fx_id uuid;
  si_ugx uuid; si_null uuid; si_usd uuid; si_tax uuid; si_rnd uuid; ri_usd uuid; cb1 uuid; cb2 uuid;
  t text; n numeric; r record;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Procurement Currency Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated', 'pc-' || u || '@test.local',
          extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}',
          now(), now(), '', '');
  insert into app_users (id, tenant_id, name, email, is_company_admin)
  values (u, ta, 'Proc Admin', 'pc-' || u || '@test.local', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);

  insert into organizations (tenant_id, company_code, site_name) values (ta, 'PC', 'Site') returning id into org;
  insert into cost_centers (tenant_id, name) values (ta, 'CC') returning id into cc;

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank', 'asset'), (ta, '1100', 'AR', 'asset'), (ta, '1400', 'VAT input', 'asset'),
    (ta, '2000', 'AP', 'liability'), (ta, '2200', 'VAT output', 'liability'),
    (ta, '4000', 'Revenue', 'revenue'), (ta, '5000', 'Expense', 'expense'), (ta, '6999', 'FX rounding', 'expense');
  select id into g_bank   from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into g_ar     from gl_accounts where tenant_id = ta and account_code = '1100';
  select id into g_vatin  from gl_accounts where tenant_id = ta and account_code = '1400';
  select id into g_ap     from gl_accounts where tenant_id = ta and account_code = '2000';
  select id into g_vatout from gl_accounts where tenant_id = ta and account_code = '2200';
  select id into g_rev    from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into g_exp    from gl_accounts where tenant_id = ta and account_code = '5000';
  select id into g_rnd    from gl_accounts where tenant_id = ta and account_code = '6999';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta, 'bank', g_bank), (ta, 'ar_control', g_ar), (ta, 'vat_input', g_vatin), (ta, 'ap_control', g_ap),
    (ta, 'vat_output', g_vatout), (ta, 'default_revenue', g_rev), (ta, 'default_expense', g_exp),
    (ta, 'fx_rounding', g_rnd);

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  -- USD 3700 yesterday, USD 3800 today, EUR 1.5 yesterday.
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3800, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'EUR', current_date - 1, 1.5, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  -------------------------------------------------------------------
  -- 1. UGX and default-currency supplier invoices post exactly as before
  -------------------------------------------------------------------
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
    values (ta, cc, 'UGX-1', current_date - 1, 1000, 0, 0, 'UGX', org, 'PRF-U1') returning id into si_ugx;
  -- No currency given: the column default applies (UGX).
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, organization_id, prf_oif_number)
    values (ta, cc, 'DEFAULT-1', current_date - 1, 2000, 0, 0, org, 'PRF-N1') returning id into si_null;
  perform pg_temp.flush();
  perform pg_temp.assert(not exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                     where e.source_id in (si_ugx, si_null) and (l.currency <> 'UGX' or l.fx_rate <> 1 or l.is_rounding)),
    'UGX and default-currency invoices must post UGX at rate 1 with no rounding line');
  raise notice 'PASS: UGX and default-currency supplier invoices post exactly as before';

  -------------------------------------------------------------------
  -- 2. The reproduced bug: USD 1,000 now posts as USD at the approved rate
  -------------------------------------------------------------------
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
    values (ta, cc, 'USD-1', current_date - 1, 1000, 0, 0, 'USD', org, 'PRF-D1') returning id into si_usd;
  perform pg_temp.flush();
  select * into r from pg_temp.net(ta, '5000', 'USD');
  -- expense account carries UGX 1,000 (si_ugx) + 2,000 (si_null) + USD 1,000 at 3,700
  perform pg_temp.assert(exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                 where e.source_id = si_usd and l.currency = 'USD' and l.fx_rate = 3700 and l.base_debit = 3700000),
    format('USD invoice must post a USD line at 3700 with base 3,700,000; got %s', pg_temp.lines_of(si_usd)));
  perform pg_temp.assert(exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                 where e.source_id = si_usd and l.currency = 'USD' and l.credit = 1000 and l.base_credit = 3700000),
    'the payables line must also be USD 1,000 with base 3,700,000');
  perform pg_temp.assert(not exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                     where e.source_id = si_usd and l.currency = 'UGX'),
    'a USD invoice must have no UGX-labelled line');
  raise notice 'PASS: a USD 1,000 supplier invoice posts USD 1,000 at 3,700 (base 3,700,000), not UGX 1,000';

  -------------------------------------------------------------------
  -- 3. VAT and withholding lines carry the currency
  -------------------------------------------------------------------
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
    values (ta, cc, 'USD-TAX', current_date - 1, 1180, 180, 0, 'USD', org, 'PRF-D2') returning id into si_tax;
  perform pg_temp.flush();
  perform pg_temp.assert((select count(*) from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                          where e.source_id = si_tax and l.currency = 'USD' and l.fx_rate = 3700) = 3,
    format('expense, VAT input and payables must all be USD at 3700: %s', pg_temp.lines_of(si_tax)));
  perform pg_temp.assert((select sum(l.base_debit - l.base_credit) from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                          where e.source_id = si_tax) = 0, 'USD invoice with VAT must balance in base');
  raise notice 'PASS: VAT lines carry the document currency and the journal balances in base';

  -------------------------------------------------------------------
  -- 4. Receivable invoices
  -------------------------------------------------------------------
  insert into receivable_invoices (tenant_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number)
    values (ta, 'AR-USD-1', current_date - 1, 590, 90, 'USD', org, 'PRF-R1') returning id into ri_usd;
  perform pg_temp.flush();
  perform pg_temp.assert((select count(*) from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                          where e.source_id = ri_usd and l.currency = 'USD' and l.fx_rate = 3700) = 3,
    format('receivable lines must all be USD at 3700: %s', pg_temp.lines_of(ri_usd)));
  perform pg_temp.assert(exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                 where e.source_id = ri_usd and l.debit = 590 and l.base_debit = 2183000),
    'receivable debit must be USD 590 with base 2,183,000');
  raise notice 'PASS: a USD receivable invoice posts in USD at the approved rate';

  -------------------------------------------------------------------
  -- 5. Rounding works through the trigger
  -------------------------------------------------------------------
  -- EUR at 1.5: net 0.67 -> 1.01, VAT 0.33 -> 0.50, payables 1.00 -> 1.50: one cent short on the credit side.
  insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
    values (ta, cc, 'EUR-RND', current_date - 1, 1.00, 0.33, 0, 'EUR', org, 'PRF-E1') returning id into si_rnd;
  perform pg_temp.flush();
  perform pg_temp.assert((select count(*) from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                          where e.source_id = si_rnd and l.is_rounding) = 1,
    format('expected one rounding line: %s', pg_temp.lines_of(si_rnd)));
  perform pg_temp.assert((select sum(l.base_debit - l.base_credit) from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                          where e.source_id = si_rnd) = 0, 'rounded invoice must balance in base');
  raise notice 'PASS: a base rounding difference is absorbed through the trigger';

  -------------------------------------------------------------------
  -- 6. Refusals keep nothing
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format($q$insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
              values (%L, %L, 'KES-1', current_date - 1, 100, 0, 0, 'KES', %L, 'PRF-K1')$q$, ta, cc, org),
    'FX_RATE_MISSING', 'invoice in a currency with no approved rate');
  perform pg_temp.assert(not exists (select 1 from supplier_invoices where invoice_number = 'KES-1'),
    'a refused invoice must leave no row behind');
  perform pg_temp.expect_error(
    format($q$insert into supplier_invoices (tenant_id, cost_center_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, wht_amount, currency, organization_id, prf_oif_number)
              values (%L, %L, 'USD-STALE', current_date + 100, 100, 0, 0, 'USD', %L, 'PRF-S1')$q$, ta, cc, org),
    'FX_RATE_STALE', 'invoice dated beyond the approved maximum rate age');
  perform pg_temp.expect_error(
    format($q$insert into receivable_invoices (tenant_id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number)
              values (%L, 'AR-KES-1', current_date - 1, 100, 0, 'KES', %L, 'PRF-R9')$q$, ta, org),
    'FX_RATE_MISSING', 'receivable in a currency with no approved rate');
  raise notice 'PASS: a missing or stale rate refuses the insert and keeps nothing';

  -------------------------------------------------------------------
  -- 7. Cash/bank transactions, and the KNOWN LIMIT
  -------------------------------------------------------------------
  -- Pay the USD 1,000 invoice today (rate 3800) in USD.
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date)
    values (ta, 'payment', 'bank', 'supplier_invoice', si_usd, 1000, 'USD', current_date) returning id into cb1;
  perform pg_temp.flush();
  perform pg_temp.assert(pg_temp.lines_of(cb1) like '%USD@3800%' and pg_temp.lines_of(cb1) not like '%UGX%',
    format('USD payment must post USD at today''s 3800: %s', pg_temp.lines_of(cb1)));

  -- Payables for USD-1 alone: its invoice entry plus this payment.
  select coalesce(sum(l.debit - l.credit), 0) as usd_net, coalesce(sum(l.base_debit - l.base_credit), 0) as base_net
    into r
    from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
   where e.source_id in (si_usd, cb1) and l.gl_account_id = g_ap;
  perform pg_temp.assert(r.usd_net = 0, format('payables for USD-1 must be zero in USD after payment, got %s', r.usd_net));
  -- KNOWN LIMIT: zero in USD, but +100,000 in base (paid at 3,800, booked at 3,700). Slice 3b books the loss.
  perform pg_temp.assert(r.base_net = 100000,
    format('KNOWN LIMIT changed: expected a 100,000 base residue on payables until realised gain/loss exists, got %s', r.base_net));
  raise notice 'PASS: a USD payment posts in USD at today''s rate; KNOWN LIMIT pinned: 100,000 base residue until slice 3b';

  -- A UGX payment (default currency) is unchanged.
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, transaction_date)
    values (ta, 'payment', 'bank', 'supplier_invoice', si_ugx, 1000, current_date - 1) returning id into cb2;
  perform pg_temp.flush();
  perform pg_temp.assert(not exists (select 1 from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
                                     where e.source_id = cb2 and (l.currency <> 'UGX' or l.fx_rate <> 1 or l.is_rounding)),
    'a UGX payment must post UGX at rate 1');
  raise notice 'PASS: a UGX payment is unchanged';
end $$;

do $$ begin raise notice 'PASS: procurement posting currency (A3 slice 3a) tests'; end $$;

rollback;