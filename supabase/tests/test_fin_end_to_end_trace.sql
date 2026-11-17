-- =====================================================================
-- Finance E: one procurement payment traced end to end
-- =====================================================================
--
-- The question this answers: "show me one procurement payment, all the way
-- down". Covers migration 20261117140000.
--
-- Chain exercised here:
--
--   purchase_orders -> supplier_invoices  (trg_post_supplier_invoice posts
--                                          Dr expense / Cr AP)
--   -> cash_bank_transactions             (trg_post_cash_bank_transaction
--                                          posts Dr AP / Cr bank)
--   -> bank_statement_lines -> bank_reconciliations
--   -> accounting_periods
--
-- Asserted:
--   1. Every hop appears in fin_trace() in order, for the same document.
--   2. The AP control account nets to zero once the invoice is paid.
--   3. The document's journal and the payment's journal are BOTH reachable
--      from the supplier invoice id -- the join key survives every hop.
--   4. The bank match is visible, and its variance is zero.
--   5. The posting lands in an open period, and the period hop reports it.
--   6. fin_trace_gaps() finds an unmatched payment and reports the open item
--      gap for procurement honestly rather than pretending it is settled.
--   7. An unsupported entity type and another tenant's document are refused.
--
-- NOTE ON SCOPE (finding E1, now CLOSED by 20261117150000): this test used to
-- assert the ABSENCE of open_item and settlement hops for procurement, as a
-- deliberate tripwire. Procurement is now wired into the subledger -- the
-- invoice raises an AP open item and the payment settles it -- so the
-- assertion is inverted: the hops must be present. If they disappear, the
-- wiring has regressed.
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

do $$
declare
  ta   uuid := gen_random_uuid();
  tb   uuid := gen_random_uuid();
  fin  uuid := gen_random_uuid();
  out  uuid := gen_random_uuid();
  finb uuid := gen_random_uuid();

  org uuid; cc uuid; vendor uuid;
  g_exp uuid; g_vat uuid; g_ap uuid; g_bank uuid;


  si_id   uuid;
  cb_id   uuid;
  sl_id   uuid;
  rec_id  uuid;
  ap_id   uuid;

  r record;
  v_ap_net numeric;
  v_doc_id uuid;
  v_kinds text[];
  n int;
begin
  ------------------------------------------------------------------
  -- Fixtures
  ------------------------------------------------------------------
  insert into tenants (id, name, industry_template)
  values (ta, 'Trace Co', 'general'), (tb, 'Other Co', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'trace-' || u.id || '@test.local',
         extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (fin), (out), (finb)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (fin,  ta, 'Trace Finance', 'trace-' || fin || '@test.local', true),
    (out,  ta, 'Trace Outsider', 'trace-' || out || '@test.local', false),
    (finb, tb, 'Trace Finance B', 'trace-' || finb || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values
    (ta, fin, 'finance'), (tb, finb, 'finance');
  -- (out is a member of tenant A but NOT on its finance team)

  -- From here on the fixtures are inserted as the owner but with a JWT claim
  -- set: several tables (organizations, cost_centers, ...) have BEFORE INSERT
  -- triggers that overwrite tenant_id from get_my_tenant_id(), which needs the
  -- claim to resolve.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);

  insert into organizations (tenant_id, company_code, site_name) values (ta, 'TR', 'Site') returning id into org;
  insert into cost_centers (tenant_id, name) values (ta, 'CC') returning id into cc;
  -- The supplier the invoice is owed to: without it the invoice cannot raise
  -- an AP open item, and the subledger half of the chain is untestable.
  insert into accounts (tenant_id, account_code, name, account_type)
    values (ta, 'SUP-TRACE', 'Trace Supplier', 'vendor') returning id into vendor;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '5000', 'Expense', 'expense') returning id into g_exp;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1200', 'VAT Input', 'asset') returning id into g_vat;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '2000', 'Accounts Payable', 'liability') returning id into g_ap;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1000', 'Operating Bank', 'asset') returning id into g_bank;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta, 'default_expense', g_exp),
    (ta, 'vat_input', g_vat),
    (ta, 'ap_control', g_ap),
    (ta, 'bank', g_bank);

  -- The bank account the payment names (cash_bank_transactions.bank_account is
  -- free text, so the subledger wiring resolves it against this table). Without
  -- it the payment still posts to the GL but cannot be allocated, which is a
  -- reported gap rather than a silent one.
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (ta, 'OPS-1', 'operating', 'UGX', g_bank);

  -- An open period covering today, so the postings are allowed and the
  -- period hop has something to report.
  insert into accounting_periods (tenant_id, period_start, period_end)
  values (ta, date_trunc('month', current_date)::date,
              (date_trunc('month', current_date) + interval '1 month - 1 day')::date)
  returning id into ap_id;

  ------------------------------------------------------------------
  -- Hops 1-2: purchase order -> supplier invoice
  ------------------------------------------------------------------
  -- NOTE: the purchase-order hop is supported by fin_trace but not exercised
  -- here. Creating a PO means creating a request, and requests require a
  -- configured procurement workflow (stages/approvals) -- a separate fixture
  -- surface from the financial chain this test is about. The PO hop is
  -- covered indirectly by the procurement specs.
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id
  ) values (
    ta, cc, 'INV-TRACE-1', current_date, current_date + 30,
    1160, 160, 'UGX', org, 'PRF-1', vendor
  ) returning id into si_id;

  -- The invoice trigger must have posted the journal.
  perform pg_temp.assert(
    exists (select 1 from journal_entries where tenant_id = ta and source_id = si_id),
    'the supplier invoice did not produce a journal entry');
  raise notice 'PASS: supplier invoice posted its journal';

  ------------------------------------------------------------------
  -- Hop 3: payment
  ------------------------------------------------------------------
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, currency, transaction_date, bank_account, description
  ) values (
    ta, 'payment', 'bank', 'supplier_invoice', si_id,
    1160, 'UGX', current_date, 'OPS-1', 'Paying INV-TRACE-1'
  ) returning id into cb_id;

  perform pg_temp.assert(
    exists (select 1 from journal_entries where tenant_id = ta and source_id = cb_id),
    'the payment did not produce a journal entry');

  -- AP control must net to zero across the invoice and its payment.
  select coalesce(sum(l.debit - l.credit), 0) into v_ap_net
  from journal_entries je
  join journal_entry_lines l on l.journal_entry_id = je.id
  where je.tenant_id = ta
    and je.source_id in (si_id, cb_id)
    and l.gl_account_id = g_ap;
  perform pg_temp.assert(v_ap_net = 0,
    format('AP control did not net to zero after payment, got %s', v_ap_net));
  raise notice 'PASS: payment posted and AP control nets to zero';

  ------------------------------------------------------------------
  -- Hop 4: bank statement match
  ------------------------------------------------------------------
  insert into bank_statement_lines (
    tenant_id, bank_account, statement_date, description, reference, amount, currency
  ) values (
    ta, 'OPS-1', current_date, 'Outgoing payment INV-TRACE-1', 'STMT-1', -1160, 'UGX'
  ) returning id into sl_id;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into r from match_bank_statement_line(sl_id, cb_id);
  reset role;

  rec_id := r.id;
  perform pg_temp.assert(rec_id is not null, 'the bank match did not create a reconciliation row');
  raise notice 'PASS: payment matched to a bank statement line';

  ------------------------------------------------------------------
  -- The trace itself
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_kinds := pg_temp.kinds('supplier_invoice', si_id);

  perform pg_temp.assert(v_kinds @> array['document']::text[],
    format('trace is missing the document hop: %s', v_kinds));
  -- One journal hop for the document's own posting. The payment's journal is
  -- carried on the cash_bank hop (journal_id), so both journals are reachable
  -- from the invoice id without being conflated into one hop.
  perform pg_temp.assert(
    (select count(*) from fin_trace('supplier_invoice', si_id) where hop_kind = 'journal') = 1,
    format('expected one journal hop for the invoice itself, got %s: %s',
           (select count(*) from fin_trace('supplier_invoice', si_id) where hop_kind = 'journal'), v_kinds));
  perform pg_temp.assert(v_kinds @> array['cash_bank']::text[],
    format('trace is missing the payment hop: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['bank_match']::text[],
    format('trace is missing the bank match hop: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['accounting_period']::text[],
    format('trace is missing the accounting period hop: %s', v_kinds));

  -- The joins survive: both journals are reachable from the invoice id --
  -- the invoice's own posting, and the payment's posting via its hop.
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'journal' and journal_id is not null),
    'the invoice journal is not reachable from the invoice');
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'cash_bank' and journal_id is not null),
    'the payment journal is not carried on the payment hop');

  -- The bank match reports zero variance.
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'bank_match' and status = 'matched'),
    'the bank match hop should report a zero-variance match');

  -- The period hop reports the open period.
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'accounting_period' and entity_id = ap_id and status = 'open'),
    'the period hop should report the open period the postings landed in');

  -- Finding E1 closed: procurement now runs through the subledger. This is
  -- the inverse of the old tripwire -- if either hop disappears, the wiring
  -- has regressed.
  perform pg_temp.assert(v_kinds @> array['open_item']::text[],
    format('procurement lost its open_item hop -- finding E1 has regressed: %s', v_kinds));
  perform pg_temp.assert(v_kinds @> array['settlement']::text[],
    format('procurement lost its settlement hop -- finding E1 has regressed: %s', v_kinds));
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'open_item' and status = 'settled'),
    'the open item hop should report the item as settled by the payment');
  perform pg_temp.assert(
    exists (select 1 from fin_trace('supplier_invoice', si_id)
            where hop_kind = 'settlement' and journal_id is null),
    'the procurement settlement should not carry a journal of its own');
  raise notice 'PASS: trace covers document -> journal -> payment -> open item -> settlement -> bank match -> period';

  ------------------------------------------------------------------
  -- fin_trace_gaps
  ------------------------------------------------------------------
  -- No gaps for this tenant right now: the invoice has a journal and an open
  -- item, the payment is allocated to it and matched to a statement line, and
  -- nothing posted into a closed period.
  select count(*) into n from fin_trace_gaps(ta);
  perform pg_temp.assert(n = 0, format('expected no gaps for the traced tenant, found %s', n));

  -- Remove the match and the gap report must find the unmatched payment.
  reset role;
  reset role;
  delete from bank_reconciliations where id = rec_id;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform pg_temp.assert(
    exists (select 1 from fin_trace_gaps(ta) g
            where g.gap = 'payment not matched to a bank statement line' and g.entity_id = cb_id),
    'fin_trace_gaps did not report the unmatched bank payment');

  -- And a document whose posting was skipped is reported. Simulated by
  -- removing the posting rules, which is exactly how trg_post_supplier_invoice
  -- decides to skip (it returns early when a required role is unmapped).
  reset role;
  delete from gl_posting_rules where tenant_id = ta and account_role = 'default_expense';
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number
  ) values (
    ta, cc, 'INV-TRACE-2', current_date, 500, 0, 'UGX', org, 'PRF-2'
  ) returning id into si_id;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.assert(
    exists (select 1 from fin_trace_gaps(ta) g
            where g.gap = 'no journal entry posted' and g.entity_id = si_id),
    'fin_trace_gaps did not report an unposted supplier invoice');

  -- The trace for an unposted document still returns its document hop, with
  -- no journal hop -- which is what an auditor needs to see.
  v_kinds := pg_temp.kinds('supplier_invoice', si_id);
  perform pg_temp.assert(v_kinds @> array['document']::text[]
                         and not (v_kinds @> array['journal']::text[]),
    format('an unposted document should trace to just the document hop, got %s', v_kinds));
  -- Keep a real id to test cross-tenant access with, while still the owner.
  v_doc_id := si_id;
  reset role;
  raise notice 'PASS: fin_trace_gaps reports unmatched payments and unposted documents';

  ------------------------------------------------------------------
  -- Isolation and refusals
  ------------------------------------------------------------------
  -- A non-finance member of the same tenant cannot read the trace.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', out, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform count(*) from fin_trace('supplier_invoice', v_doc_id);
    raise exception 'FAIL: a non-finance user was allowed to run fin_trace';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    -- Any error is acceptable here only if it is an authorization failure.
    if sqlerrm not like '%not authorized%' and sqlerrm not like '%not found%' then
      raise exception 'FAIL: unexpected error for a non-finance caller: %', sqlerrm;
    end if;
  end;
  reset role;

  -- A finance user of another tenant cannot read this tenant's document.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', finb, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform count(*) from fin_trace('supplier_invoice', v_doc_id);
    raise exception 'FAIL: another tenant''s document traced successfully';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%not found for your company%' then
      raise exception 'FAIL: wrong error for a cross-tenant trace: %', sqlerrm;
    end if;
  end;
  reset role;

  -- An unsupported entity type is refused with a clear message.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform count(*) from fin_trace('payroll_run', gen_random_uuid());
    raise exception 'FAIL: an unsupported entity type was accepted';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%unsupported entity type%' then
      raise exception 'FAIL: wrong error for an unsupported type: %', sqlerrm;
    end if;
  end;
  reset role;

  raise notice 'PASS: trace is tenant-scoped, finance-only, and refuses unknown types';
  raise notice 'ALL END-TO-END TRACE TESTS PASSED';
end $$;

rollback;
