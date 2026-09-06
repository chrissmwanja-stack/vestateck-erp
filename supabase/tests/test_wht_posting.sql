-- Workstream D functional test: WHT (withholding tax) posting path
-- on supplier invoices (trg_post_supplier_invoice's WHT branch) and
-- the v_wht_report view.
--
-- Run against a fresh local stack only (`supabase start` in the
-- db-shadow-replay CI job, or `supabase db reset` locally) -- see
-- test_gl_posting_and_period_close.sql's header for the same caveat
-- about not running this against a linked/remote project.
--
-- Fails loudly: any RAISE EXCEPTION here is a real assertion failure
-- and should fail the CI step (psql -f exits non-zero on an uncaught
-- error).

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tenant_id uuid := gen_random_uuid();
  v_user_id uuid := gen_random_uuid();
  v_org_id uuid := gen_random_uuid();
  v_cost_center_id uuid;
  v_vendor_account_id uuid;
  v_expense_account uuid;
  v_ap_account uuid;
  v_vat_account uuid;
  v_wht_account uuid;
  v_invoice_id uuid;
  v_entry_id uuid;
  v_line_count int;
  v_line_sum numeric;
  v_report record;
begin
  -------------------------------------------------------------------
  -- Fixtures: one tenant, one finance-team auth user, one org, a
  -- cost center (supplier_invoices requires PO or cost center), and
  -- the default_expense/ap_control/vat_input posting rules --
  -- deliberately WITHOUT a wht_payable rule yet, so the first test
  -- below can exercise the "not configured" skip path.
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_tenant_id, 'WHT Posting Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_user_id, 'authenticated', 'authenticated',
    'wht-test-' || v_user_id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );

  insert into app_users (id, tenant_id, name, email)
  values (v_user_id, v_tenant_id, 'WHT Test Finance User', 'wht-test-' || v_user_id || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role)
  values (v_tenant_id, v_user_id, 'finance');

  -- Impersonate the finance user from here on, since get_my_tenant_id()/
  -- is_finance_team_member() both read auth.uid() from session-local JWT
  -- claims -- and this must happen before organizations (its
  -- set_organization_defaults() trigger needs it) and before any RLS-
  -- gated insert below.
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_id)::text, true);
  set local role authenticated;

  insert into organizations (tenant_id, company_code, site_name)
  values (v_tenant_id, 'WHTT', 'WHT Test Site')
  returning id into v_org_id;

  insert into accounts (tenant_id, account_code, name, account_type, tax_id)
  values (v_tenant_id, 'V-001', 'Test Vendor Ltd', 'vendor', 'TIN-1234567')
  returning id into v_vendor_account_id;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant_id, '5000', 'Test Expense', 'expense')
  returning id into v_expense_account;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant_id, '2000', 'Test AP Control', 'liability')
  returning id into v_ap_account;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant_id, '1500', 'Test VAT Input', 'asset')
  returning id into v_vat_account;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
  values
    (v_tenant_id, 'default_expense', v_expense_account),
    (v_tenant_id, 'ap_control', v_ap_account),
    (v_tenant_id, 'vat_input', v_vat_account);

  -- cost_centers' INSERT policy requires has_po_access() (a procurement
  -- approval-chain check), which a plain finance-team member legitimately
  -- doesn't have -- so this one fixture row is inserted with RLS bypassed
  -- via reset role. Its own set_cost_center_defaults() trigger still needs
  -- auth.uid() resolvable, which the JWT claims set above already provide
  -- regardless of role.
  reset role;
  insert into cost_centers (tenant_id, name)
  values (v_tenant_id, 'WHT Test Cost Center')
  returning id into v_cost_center_id;
  set local role authenticated;

  -------------------------------------------------------------------
  -- 1. A WHT-bearing invoice posted BEFORE a wht_payable posting rule
  --    exists should skip posting entirely -- same "skip, don't
  --    guess" posture as a missing default_expense/ap_control rule --
  --    rather than credit AP for the full gross amount (which would
  --    overstate what's actually owed once WHT is configured).
  -------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, organization_id, invoice_number, invoice_date, cost_center_id,
    amount_incl_vat, vat_amount, wht_amount, wht_rate, vendor_account_id
  ) values (
    v_tenant_id, v_org_id, 'INV-WHT-001', current_date, v_cost_center_id,
    1000000, 0, 60000, 6, v_vendor_account_id
  )
  returning id into v_invoice_id;

  if exists (select 1 from journal_entries where tenant_id = v_tenant_id and source_type = 'supplier_invoice' and source_id = v_invoice_id) then
    raise exception 'FAIL: a WHT invoice posted before wht_payable was configured, expected it to be skipped';
  end if;

  raise notice 'PASS: a WHT-bearing invoice is skipped (not posted) while no wht_payable posting rule exists';

  -------------------------------------------------------------------
  -- Now configure the wht_payable posting rule for the rest of the
  -- test.
  -------------------------------------------------------------------
  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant_id, '2200', 'Test WHT Payable', 'liability')
  returning id into v_wht_account;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
  values (v_tenant_id, 'wht_payable', v_wht_account);

  -------------------------------------------------------------------
  -- 2. WHT + VAT invoice, normal case: AP is credited net of BOTH
  --    VAT and WHT, and WHT Payable is credited the withheld amount.
  --    amount_incl_vat=1,180,000, vat=180,000 (net 1,000,000 excl
  --    VAT), wht=60,000 (6% of the 1,000,000 net) -- realistic
  --    Uganda VAT+WHT invoice shape.
  -------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, organization_id, invoice_number, invoice_date, cost_center_id,
    amount_incl_vat, vat_amount, wht_amount, wht_rate, vendor_account_id
  ) values (
    v_tenant_id, v_org_id, 'INV-WHT-002', date '2026-03-10', v_cost_center_id,
    1180000, 180000, 60000, 6, v_vendor_account_id
  )
  returning id into v_invoice_id;

  select je.id into v_entry_id
  from journal_entries je
  where je.tenant_id = v_tenant_id and je.source_type = 'supplier_invoice' and je.source_id = v_invoice_id;

  if v_entry_id is null then
    raise exception 'FAIL: WHT+VAT invoice did not create a journal_entries row once wht_payable was configured';
  end if;

  select count(*), coalesce(sum(debit), 0) - coalesce(sum(credit), 0)
    into v_line_count, v_line_sum
    from journal_entry_lines
    where journal_entry_id = v_entry_id;

  if v_line_count != 4 then
    raise exception 'FAIL: WHT+VAT journal entry has % lines, expected 4 (expense, vat_input, wht_payable, ap_control)', v_line_count;
  end if;
  if v_line_sum != 0 then
    raise exception 'FAIL: WHT+VAT journal entry is not balanced (debit-credit = %)', v_line_sum;
  end if;

  if not exists (select 1 from journal_entry_lines where journal_entry_id = v_entry_id and gl_account_id = v_expense_account and debit = 1000000) then
    raise exception 'FAIL: expense line is not a 1,000,000 debit (net of VAT)';
  end if;
  if not exists (select 1 from journal_entry_lines where journal_entry_id = v_entry_id and gl_account_id = v_vat_account and debit = 180000) then
    raise exception 'FAIL: VAT input line is not a 180,000 debit';
  end if;
  if not exists (select 1 from journal_entry_lines where journal_entry_id = v_entry_id and gl_account_id = v_wht_account and credit = 60000) then
    raise exception 'FAIL: WHT payable line is not a 60,000 credit';
  end if;
  if not exists (select 1 from journal_entry_lines where journal_entry_id = v_entry_id and gl_account_id = v_ap_account and credit = 1120000) then
    raise exception 'FAIL: AP control line is not a 1,120,000 credit (gross 1,180,000 less 60,000 WHT)';
  end if;

  raise notice 'PASS: a WHT+VAT invoice posts AP net of both VAT and WHT, with WHT credited to WHT Payable';

  -------------------------------------------------------------------
  -- 3. v_wht_report exposes this invoice with the correct
  --    net_payable, vendor details, and remittance due date (15th of
  --    the month after the invoice date -- fixed invoice_date above
  --    makes this deterministic: 2026-03-10 -> due 2026-04-15).
  -------------------------------------------------------------------
  select * into v_report from v_wht_report where source_id = v_invoice_id;

  if v_report.source_id is null then
    raise exception 'FAIL: WHT invoice does not appear in v_wht_report';
  end if;
  if v_report.net_payable != 1120000 then
    raise exception 'FAIL: v_wht_report net_payable is %, expected 1,120,000', v_report.net_payable;
  end if;
  if v_report.vendor_name != 'Test Vendor Ltd' or v_report.vendor_tax_id != 'TIN-1234567' then
    raise exception 'FAIL: v_wht_report did not join the correct vendor details';
  end if;
  if v_report.remittance_due_date != date '2026-04-15' then
    raise exception 'FAIL: v_wht_report remittance_due_date is %, expected 2026-04-15', v_report.remittance_due_date;
  end if;

  raise notice 'PASS: v_wht_report reports the correct net_payable, vendor details, and remittance due date';

  -------------------------------------------------------------------
  -- 4. Fully-withheld edge case: wht_amount = amount_incl_vat leaves
  --    nothing for the AP leg. The AP credit line must be omitted
  --    entirely (a zero-amount line would fail the journal_entry_lines
  --    "one side, non-zero" check) rather than post a zero-value line.
  -------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, organization_id, invoice_number, invoice_date, cost_center_id,
    amount_incl_vat, vat_amount, wht_amount, wht_rate, vendor_account_id
  ) values (
    v_tenant_id, v_org_id, 'INV-WHT-003', current_date, v_cost_center_id,
    500000, 0, 500000, 100, v_vendor_account_id
  )
  returning id into v_invoice_id;

  select je.id into v_entry_id
  from journal_entries je
  where je.tenant_id = v_tenant_id and je.source_type = 'supplier_invoice' and je.source_id = v_invoice_id;

  if v_entry_id is null then
    raise exception 'FAIL: fully-withheld invoice did not create a journal_entries row';
  end if;

  select count(*), coalesce(sum(debit), 0) - coalesce(sum(credit), 0)
    into v_line_count, v_line_sum
    from journal_entry_lines
    where journal_entry_id = v_entry_id;

  if v_line_count != 2 then
    raise exception 'FAIL: fully-withheld journal entry has % lines, expected 2 (expense + wht_payable, no AP leg)', v_line_count;
  end if;
  if v_line_sum != 0 then
    raise exception 'FAIL: fully-withheld journal entry is not balanced (debit-credit = %)', v_line_sum;
  end if;
  if exists (select 1 from journal_entry_lines where journal_entry_id = v_entry_id and gl_account_id = v_ap_account) then
    raise exception 'FAIL: a 100%%-WHT invoice still posted an AP control line (should be omitted, not zero)';
  end if;

  raise notice 'PASS: a fully-withheld invoice omits the AP leg entirely rather than posting a zero-amount line';

  -------------------------------------------------------------------
  -- 5. A regular (non-WHT) invoice is unaffected by any of the
  --    above: full gross posted to AP, no WHT line, and it does NOT
  --    appear in v_wht_report.
  -------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, organization_id, invoice_number, invoice_date, cost_center_id,
    amount_incl_vat, vat_amount, wht_amount
  ) values (
    v_tenant_id, v_org_id, 'INV-WHT-004', current_date, v_cost_center_id,
    200000, 0, 0
  )
  returning id into v_invoice_id;

  select je.id into v_entry_id
  from journal_entries je
  where je.tenant_id = v_tenant_id and je.source_type = 'supplier_invoice' and je.source_id = v_invoice_id;

  if v_entry_id is null then
    raise exception 'FAIL: a plain non-WHT invoice did not create a journal_entries row';
  end if;

  if not exists (select 1 from journal_entry_lines where journal_entry_id = v_entry_id and gl_account_id = v_ap_account and credit = 200000) then
    raise exception 'FAIL: a plain non-WHT invoice was not credited to AP for the full gross amount';
  end if;
  if exists (select 1 from journal_entry_lines where journal_entry_id = v_entry_id and gl_account_id = v_wht_account) then
    raise exception 'FAIL: a plain non-WHT invoice unexpectedly posted a WHT payable line';
  end if;
  if exists (select 1 from v_wht_report where source_id = v_invoice_id) then
    raise exception 'FAIL: a plain non-WHT invoice (wht_amount = 0) appeared in v_wht_report';
  end if;

  raise notice 'PASS: a plain non-WHT invoice posts full gross to AP and is excluded from v_wht_report';

  -------------------------------------------------------------------
  -- 6. Data integrity guard: wht_amount cannot exceed amount_incl_vat
  --    (supplier_invoices_wht_amount_check).
  -------------------------------------------------------------------
  begin
    insert into supplier_invoices (
      tenant_id, organization_id, invoice_number, invoice_date, cost_center_id,
      amount_incl_vat, vat_amount, wht_amount
    ) values (
      v_tenant_id, v_org_id, 'INV-WHT-005', current_date, v_cost_center_id,
      100000, 0, 150000
    );
    raise exception 'FAIL: an invoice with wht_amount > amount_incl_vat was NOT rejected';
  exception
    when check_violation then
      null; -- expected
  end;

  raise notice 'PASS: wht_amount > amount_incl_vat is rejected by the check constraint';

  raise notice 'ALL WHT POSTING PATH TESTS PASSED';
end $$;

rollback;
