-- Workstream A, phase 1 continued: auto-post to the new journal_entries
-- ledger whenever a supplier invoice, receivable invoice, or cash/bank
-- transaction is recorded. The existing screens (SupplierInvoices,
-- ReceivableInvoice, CashBankOperations) are untouched -- they keep
-- writing to the subledger tables exactly as before; these triggers
-- are additive and fire after that insert to create the matching
-- journal entry underneath.
--
-- payroll_run cash_bank_transactions are deliberately NOT posted here
-- (see the cash_bank_transaction trigger below) -- Workstream F
-- (PAYE/NSSF) will define proper Salaries/PAYE/NSSF Payable control
-- accounts, and posting payroll disbursement to the generic expense
-- account now would just need to be re-posted differently later.
-- Better to leave it unposted with a clear TODO than guess.

-- Generic poster: one journal entry + N balanced lines from a jsonb
-- array. Shared by all three triggers below so the "insert entry,
-- insert lines, let the deferred balance trigger validate" sequence
-- lives in one place.
create or replace function public.post_journal_entry(
    p_tenant_id uuid,
    p_source_type text,
    p_source_id uuid,
    p_entry_date date,
    p_description text,
    p_lines jsonb  -- array of {gl_account_id, debit, credit, description?}
)
returns public.journal_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry journal_entries%rowtype;
  v_line jsonb;
begin
  insert into journal_entries (tenant_id, entry_date, source_type, source_id, description, posted_by)
  values (p_tenant_id, p_entry_date, p_source_type, p_source_id, p_description, auth.uid())
  returning * into v_entry;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, description)
    values (
      v_entry.id,
      p_tenant_id,
      (v_line ->> 'gl_account_id')::uuid,
      coalesce((v_line ->> 'debit')::numeric, 0),
      coalesce((v_line ->> 'credit')::numeric, 0),
      v_line ->> 'description'
    );
  end loop;

  return v_entry;
end;
$$;

-- Supplier invoice -> Dr expense (net), Dr VAT input (if any), Cr AP control.
create or replace function public.trg_post_supplier_invoice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctl gl_control_accounts%rowtype;
  v_net numeric;
  v_lines jsonb;
begin
  select * into v_ctl from gl_control_accounts where tenant_id = new.tenant_id;
  if not found then
    -- Tenant hasn't run seed_default_chart_of_accounts() yet -- skip
    -- posting rather than fail the invoice insert. The invoice still
    -- saves; it just won't appear on the GL until the tenant sets up
    -- their chart of accounts and (in a later phase) a backfill runs.
    return new;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ctl.default_expense_account_id, 'debit', v_net)
  );
  if new.vat_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.vat_input_account_id, 'debit', new.vat_amount);
  end if;
  v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.ap_control_account_id, 'credit', new.amount_incl_vat);

  perform post_journal_entry(new.tenant_id, 'supplier_invoice', new.id, new.invoice_date,
    'Supplier invoice ' || new.invoice_number, v_lines);

  return new;
end;
$$;

drop trigger if exists trg_post_supplier_invoice on public.supplier_invoices;
create trigger trg_post_supplier_invoice
    after insert on public.supplier_invoices
    for each row execute function public.trg_post_supplier_invoice();

-- Receivable invoice -> Dr AR control, Cr revenue (net), Cr VAT output (if any).
create or replace function public.trg_post_receivable_invoice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctl gl_control_accounts%rowtype;
  v_net numeric;
  v_lines jsonb;
begin
  select * into v_ctl from gl_control_accounts where tenant_id = new.tenant_id;
  if not found then
    return new;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ctl.ar_control_account_id, 'debit', new.amount_incl_vat),
    jsonb_build_object('gl_account_id', v_ctl.default_revenue_account_id, 'credit', v_net)
  );
  if new.vat_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.vat_output_account_id, 'credit', new.vat_amount);
  end if;

  perform post_journal_entry(new.tenant_id, 'receivable_invoice', new.id, new.invoice_date,
    'Receivable invoice ' || new.invoice_number, v_lines);

  return new;
end;
$$;

drop trigger if exists trg_post_receivable_invoice on public.receivable_invoices;
create trigger trg_post_receivable_invoice
    after insert on public.receivable_invoices
    for each row execute function public.trg_post_receivable_invoice();

-- Cash/bank movement -> settles a prior AP/AR control balance, or (for
-- an expenditure slip, which has no prior AP leg) posts straight to
-- the default expense account. payroll_run is deliberately skipped --
-- see file header.
create or replace function public.trg_post_cash_bank_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctl gl_control_accounts%rowtype;
  v_cash_side uuid;
  v_other_side uuid;
  v_lines jsonb;
begin
  if new.reference_type = 'payroll_run' then
    return new;  -- TODO(Workstream F): post to Salaries/PAYE/NSSF Payable once those control accounts exist.
  end if;

  select * into v_ctl from gl_control_accounts where tenant_id = new.tenant_id;
  if not found then
    return new;
  end if;

  v_cash_side := case when new.payment_method = 'bank' then v_ctl.bank_account_id else v_ctl.cash_account_id end;

  -- The non-cash leg depends only on reference_type; which side of
  -- the entry it lands on depends on transaction_type. Driving both
  -- off transaction_type (rather than hardcoding "supplier_invoice
  -- always debits AP") means an unusual-but-valid case like a
  -- supplier refund (a 'receipt' against a supplier_invoice) still
  -- posts the right direction instead of being silently backwards.
  v_other_side := case new.reference_type
    when 'supplier_invoice' then v_ctl.ap_control_account_id
    when 'receivable_invoice' then v_ctl.ar_control_account_id
    when 'expenditure_slip' then v_ctl.default_expense_account_id
    else null
  end;
  if v_other_side is null then
    return new;
  end if;

  if new.transaction_type = 'payment' then
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_other_side, 'debit', new.amount),
      jsonb_build_object('gl_account_id', v_cash_side, 'credit', new.amount)
    );
  else -- 'receipt'
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_cash_side, 'debit', new.amount),
      jsonb_build_object('gl_account_id', v_other_side, 'credit', new.amount)
    );
  end if;

  perform post_journal_entry(new.tenant_id, 'cash_bank_transaction', new.id, new.transaction_date,
    coalesce(new.description, initcap(new.transaction_type) || ' - ' || new.reference_type), v_lines);

  return new;
end;
$$;

drop trigger if exists trg_post_cash_bank_transaction on public.cash_bank_transactions;
create trigger trg_post_cash_bank_transaction
    after insert on public.cash_bank_transactions
    for each row execute function public.trg_post_cash_bank_transaction();
