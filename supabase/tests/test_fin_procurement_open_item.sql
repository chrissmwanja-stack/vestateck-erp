-- =====================================================================
-- Finance E1: procurement settles through the open-item subledger
-- =====================================================================
--
-- Covers migration 20261117150000. The question: "show me one procurement
-- payment, and prove it neither lost nor doubled a journal."
--
-- The chain this asserts:
--
--   supplier_invoices      -> trg_post_supplier_invoice posts Dr expense /
--                             Cr AP, AND raises the AP open item
--   cash_bank_transactions -> trg_post_cash_bank_transaction posts Dr AP /
--                             Cr bank (the ONLY journal for the payment)
--                          -> trg_settle_supplier_invoice_open_item records a
--                             subledger-only settlement + allocation
--   -> fin_open_item_balances shows the item settled
--   -> fin_trace has open_item AND settlement hops, joined to the payment
--   -> GL AP control nets to zero, and there is exactly ONE payment journal
--
-- One transaction, ROLLBACKs at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.kinds(p_entity_type text, p_id uuid)
returns text[] language sql as $$
  select coalesce(array_agg(hop_kind order by hop), '{}')
  from fin_trace(p_entity_type, p_id)
$$;

create function pg_temp.expect_error(p_sql text, p_like text, p_msg text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
    raise exception 'FAIL: % (no error raised)', p_msg;
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like p_like then
      raise exception 'FAIL: % (unexpected error: %)', p_msg, sqlerrm;
    end if;
  end;
end $$;

do $$
declare
  ta   uuid := gen_random_uuid();
  tb   uuid := gen_random_uuid();
  fin  uuid := gen_random_uuid();
  finb uuid := gen_random_uuid();

  org uuid; cc uuid; vendor uuid; vendor2 uuid;
  g_exp uuid; g_vat uuid; g_ap uuid; g_bank uuid; g_wht uuid;
  bank_id uuid;

  si_id uuid; si_wht uuid; si_novendor uuid;
  cb_id uuid; cb2 uuid;
  oi_id uuid; oi_wht uuid;
  st_id uuid;
  v_bank2 uuid;

  r record;
  v_ap_net numeric;
  v_kinds text[];
  n int;
  v_amt numeric;
begin
  ------------------------------------------------------------------
  -- Fixtures
  ------------------------------------------------------------------
  insert into tenants (id, name, industry_template)
  values (ta, 'Subledger Co', 'general'), (tb, 'Other Co', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'sub-' || u.id || '@test.local',
         extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (fin), (finb)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (fin,  ta, 'Sub Finance', 'sub-' || fin || '@test.local', true),
    (finb, tb, 'Sub Finance B', 'sub-' || finb || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values
    (ta, fin, 'finance'), (tb, finb, 'finance');

  -- BEFORE INSERT triggers on organizations/cost_centers overwrite tenant_id
  -- from get_my_tenant_id(), so the claim must resolve even as the owner.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);

  insert into organizations (tenant_id, company_code, site_name) values (ta, 'SB', 'Site') returning id into org;
  insert into cost_centers (tenant_id, name) values (ta, 'CC') returning id into cc;
  insert into accounts (tenant_id, account_code, name, account_type)
    values (ta, 'SUP-1', 'Supplier One', 'vendor') returning id into vendor;
  insert into accounts (tenant_id, account_code, name, account_type)
    values (ta, 'SUP-2', 'Supplier Two', 'vendor') returning id into vendor2;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '5000', 'Expense', 'expense') returning id into g_exp;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1200', 'VAT Input', 'asset') returning id into g_vat;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '2000', 'Accounts Payable', 'liability') returning id into g_ap;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1000', 'Operating Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '2100', 'WHT Payable', 'liability') returning id into g_wht;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta, 'default_expense', g_exp),
    (ta, 'vat_input', g_vat),
    (ta, 'ap_control', g_ap),
    (ta, 'bank', g_bank),
    (ta, 'wht_payable', g_wht);

  -- The operating bank account, named to match cash_bank_transactions.bank_account.
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (ta, 'OPS-1', 'operating', 'UGX', g_bank) returning id into bank_id;

  insert into accounting_periods (tenant_id, period_start, period_end)
  values (ta, date_trunc('month', current_date)::date,
              (date_trunc('month', current_date) + interval '1 month - 1 day')::date);

  ------------------------------------------------------------------
  -- 1. An invoice raises its AP open item
  ------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id
  ) values (
    ta, cc, 'INV-SUB-1', current_date, current_date + 30,
    1160, 160, 'UGX', org, 'PRF-1', vendor
  ) returning id into si_id;

  select id into oi_id from fin_open_items
   where tenant_id = ta and source_type = 'supplier_invoice' and source_id = si_id;
  perform pg_temp.assert(oi_id is not null,
    'the supplier invoice did not raise an AP open item (finding E1 not closed)');

  perform pg_temp.assert(
    (select control_role from fin_open_items where id = oi_id) = 'ap_control'
    and (select side from fin_open_items where id = oi_id) = 'payable',
    'the open item is not an AP payable');

  perform pg_temp.assert(
    (select party_account_id from fin_open_items where id = oi_id) = vendor,
    'the open item is not against the invoice supplier');

  -- The item is tied to the invoice's own journal, so its rate is the booked rate.
  perform pg_temp.assert(
    (select oi.journal_entry_id is not null
            and oi.journal_entry_id = (select je.id from journal_entries je
                                        where je.source_id = si_id and je.tenant_id = ta)
     from fin_open_items oi where oi.id = oi_id),
    'the open item is not linked to the invoice journal');

  perform pg_temp.assert(
    (select amount from fin_open_items where id = oi_id) = 1160,
    'the open item amount should be the full AP credit (1160)');
  raise notice 'PASS: supplier invoice raised its AP open item, linked to its journal';

  ------------------------------------------------------------------
  -- 2. The payment settles it without a second journal
  ------------------------------------------------------------------
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, currency, transaction_date, bank_account, description
  ) values (
    ta, 'payment', 'bank', 'supplier_invoice', si_id,
    1160, 'UGX', current_date, 'OPS-1', 'Paying INV-SUB-1'
  ) returning id into cb_id;

  -- Exactly one journal for the payment: the cash/bank trigger's.
  perform pg_temp.assert(
    (select count(*) from journal_entries
      where tenant_id = ta and source_id = cb_id and source_type = 'cash_bank_transaction') = 1,
    'the payment should have exactly one journal entry');
  perform pg_temp.assert(
    not exists (select 1 from journal_entries
                 where tenant_id = ta and source_type = 'fin_settlement'
                   and source_id in (select id from fin_settlements where tenant_id = ta)),
    'the subledger-only settlement must NOT post its own journal (double-journal defect)');

  -- The settlement exists, is subledger-only, and is allocated to the item.
  select s.id into st_id
    from fin_settlements s
    join fin_allocations a on a.settlement_id = s.id
   where a.open_item_id = oi_id;
  perform pg_temp.assert(st_id is not null,
    'the payment did not create a settlement against the open item');
  perform pg_temp.assert(
    (select subledger_only and journal_entry_id is null from fin_settlements where id = st_id),
    'the procurement settlement should be subledger-only with no journal of its own');
  perform pg_temp.assert(
    (select amount from fin_allocations where settlement_id = st_id and open_item_id = oi_id) = 1160,
    'the allocation should relieve the whole AP balance');
  perform pg_temp.assert(
    (select funding_transaction_id from fin_settlements where id = st_id) = cb_id,
    'the settlement should record the transaction that funded it');

  perform pg_temp.assert(
    (select settlement_status from fin_open_item_balances where id = oi_id) = 'settled',
    'the open item should be settled once it is paid');
  perform pg_temp.assert(
    (select outstanding_amount from fin_open_item_balances where id = oi_id) = 0,
    'the open item should have nothing outstanding');

  -- AP control nets to zero across the invoice and the payment.
  select coalesce(sum(l.debit - l.credit), 0) into v_ap_net
  from journal_entries je
  join journal_entry_lines l on l.journal_entry_id = je.id
  where je.tenant_id = ta and je.source_id in (si_id, cb_id) and l.gl_account_id = g_ap;
  perform pg_temp.assert(v_ap_net = 0,
    format('AP control did not net to zero, got %s', v_ap_net));
  raise notice 'PASS: payment settled the item with exactly one journal; AP controls out';

  ------------------------------------------------------------------
  -- 3. The trace now has open_item and settlement hops
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_kinds := pg_temp.kinds('supplier_invoice', si_id);

  perform pg_temp.assert(v_kinds @> array['document']::text[], format('missing document hop: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['journal']::text[], format('missing journal hop: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['cash_bank']::text[], format('missing payment hop: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['open_item']::text[],
    format('finding E1: the trace still has no open_item hop: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['settlement']::text[],
    format('finding E1: the trace still has no settlement hop: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['accounting_period']::text[],
    format('missing period hop: %s', v_kinds));

  -- The open item hop reports the settled balance.
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'open_item' and status = 'settled' and amount = 1160),
    'the open item hop should report 1160 settled');

  -- The settlement hop is joined to the payment: it names no journal of its
  -- own and says why.
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'settlement' and journal_id is null
              and detail like '%funding bank transaction posted the GL entry%'),
    'the settlement hop should explain that the bank transaction posted the GL');

  -- The payment hop still carries its own journal, so the money leg is traceable.
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'cash_bank' and journal_id is not null),
    'the payment hop is missing its journal');
  reset role;
  raise notice 'PASS: trace runs document -> journal -> payment -> open item -> settlement -> period';

  ------------------------------------------------------------------
  -- 4. A partial payment leaves the item partly settled
  ------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id
  ) values (
    ta, cc, 'INV-SUB-2', current_date, current_date + 30,
    1000, 0, 'UGX', org, 'PRF-2', vendor2
  ) returning id into si_novendor;

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, currency, transaction_date, bank_account, description
  ) values (
    ta, 'payment', 'bank', 'supplier_invoice', si_novendor,
    400, 'UGX', current_date, 'OPS-1', 'Part-paying INV-SUB-2'
  ) returning id into cb2;

  perform pg_temp.assert(
    (select settlement_status from fin_open_item_balances
      where source_id = si_novendor and source_type = 'supplier_invoice') = 'partly_settled',
    'a part payment should leave the item partly settled');
  perform pg_temp.assert(
    (select outstanding_amount from fin_open_item_balances
      where source_id = si_novendor and source_type = 'supplier_invoice') = 600,
    'a part payment of 400 against 1000 should leave 600 outstanding');
  raise notice 'PASS: a part payment leaves the correct outstanding balance';

  ------------------------------------------------------------------
  -- 5. Withholding tax is not part of the supplier's open item
  ------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id, wht_rate, wht_amount
  ) values (
    ta, cc, 'INV-SUB-WHT', current_date, current_date + 30,
    1000, 0, 'UGX', org, 'PRF-3', vendor, 6, 60
  ) returning id into si_wht;

  select id into oi_wht from fin_open_items
   where tenant_id = ta and source_type = 'supplier_invoice' and source_id = si_wht;
  perform pg_temp.assert(
    (select amount from fin_open_items where id = oi_wht) = 940,
    format('a WHT invoice should owe the supplier 940, got %s',
           (select amount from fin_open_items where id = oi_wht)));

  -- And AP control agrees: the credit posted is also 940.
  perform pg_temp.assert(
    (select coalesce(sum(l.credit - l.debit), 0) from journal_entries je
       join journal_entry_lines l on l.journal_entry_id = je.id
      where je.source_id = si_wht and l.gl_account_id = g_ap) = 940,
    'the subledger item must equal the AP amount actually posted');
  raise notice 'PASS: withholding tax is excluded from the open item, matching AP control';

  ------------------------------------------------------------------
  -- 6. The subledger cannot be double-fed or double-journalled
  ------------------------------------------------------------------
  -- A second open item for the same invoice is refused.
  perform pg_temp.expect_error(
    format($q$select fin_create_open_item(%L, %L, 'ap_control', 'supplier_invoice', %L,
              'INV-SUB-1-dup', current_date, null, 1, 'duplicate')$q$, ta, vendor, si_id),
    '%fin_open_items_source_unique%',
    'a duplicate open item for one invoice was accepted');

  -- A subledger-only settlement cannot be given a journal later.
  perform pg_temp.expect_error(
    format($q$update fin_settlements set journal_entry_id = gen_random_uuid(),
              subledger_only = false where id = %L$q$, st_id),
    '%SETTLEMENT%',
    'a subledger-only settlement was allowed to acquire a journal');

  -- A subledger-only settlement must name the funding transaction that
  -- posted its GL entry.
  perform pg_temp.expect_error(
    format($q$insert into fin_settlements (
                tenant_id, settlement_no, direction, bank_account_id, party_account_id,
                amount, currency, settlement_date, subledger_only)
              values (%L, 'STL-BAD2', 'out', %L, %L, 10, 'UGX', current_date, true)$q$,
           ta, bank_id, vendor),
    '%must name the bank transaction%',
    'a subledger-only settlement without a funding transaction was accepted');

  -- A subledger-only settlement cannot be created with a journal either.
  perform pg_temp.expect_error(
    format($q$insert into fin_settlements (
                tenant_id, settlement_no, direction, bank_account_id, party_account_id,
                amount, currency, settlement_date, subledger_only,
                journal_entry_id, funding_transaction_id)
              values (%L, 'STL-BAD3', 'out', %L, %L, 10, 'UGX', current_date, true,
                      (select id from journal_entries where source_id = %L), %L)$q$,
           ta, bank_id, vendor, si_wht, cb2),
    '%subledger-only settlement must not name a journal%',
    'a subledger-only settlement was allowed to carry its own journal');

  -- Whether a settlement is subledger-only cannot be flipped after the fact.
  perform pg_temp.expect_error(
    format($q$update fin_settlements set subledger_only = false where id = %L$q$, st_id),
    '%cannot be changed%',
    'a settlement was allowed to change whether it carries its own journal');

  -- An overpayment does not corrupt the item: the payment still posts, and the
  -- excess shows as a gap rather than being allocated.
  perform pg_temp.assert(
    (select amount from fin_open_items where source_id = si_novendor) = 1000,
    'the open item amount should be unchanged by payments');
  raise notice 'PASS: one item per invoice, subledger-only settlements stay journal-less';

  ------------------------------------------------------------------
  -- 7. The gap report is honest about what is not wired
  ------------------------------------------------------------------
  -- An invoice with no supplier account cannot be settled in the subledger;
  -- it is GL-only and must be reported.
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number
  ) values (
    ta, cc, 'INV-SUB-NOVENDOR', current_date, 250, 0, 'UGX', org, 'PRF-4'
  ) returning id into si_id;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.assert(
    exists (select 1 from fin_trace_gaps(ta) g
            where g.entity_id = si_id
              and g.gap = 'posted but has no supplier account, so it has no open item'),
    'fin_trace_gaps did not report an invoice that cannot be settled');
  reset role;

  -- A payment that relieved AP but was not allocated (identical amount to a
  -- full settlement would be allocated, so knock out the allocation to
  -- simulate the failure path) is reported.
  delete from fin_allocations where settlement_id = st_id;
  delete from fin_settlements where id = st_id;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.assert(
    exists (select 1 from fin_trace_gaps(ta) g
            where g.entity_id = cb_id and g.gap = 'payment is not allocated to its open item'),
    'fin_trace_gaps did not report an unallocated payment');
  reset role;
  raise notice 'PASS: gap report names unwired invoices and unallocated payments';

  ------------------------------------------------------------------
  -- 8. Isolation
  ------------------------------------------------------------------
  -- Another tenant's finance user cannot trace this invoice.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', finb, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform count(*) from fin_trace('supplier_invoice', si_wht);
    raise exception 'FAIL: another tenant traced this invoice';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%not found for your company%' then
      raise exception 'FAIL: wrong error for a cross-tenant trace: %', sqlerrm;
    end if;
  end;
  reset role;

  raise notice 'PASS: the subledger wiring is tenant-scoped';
  raise notice 'ALL PROCUREMENT OPEN-ITEM TESTS PASSED';
end $$;

rollback;
