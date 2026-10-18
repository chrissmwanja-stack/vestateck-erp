-- Phase A, A3 slice 3a (see docs/insurance-brokerage/CURRENCY_REVIEW.md, finding F1):
-- the supplier invoice, receivable invoice and cash/bank posting triggers now carry
-- the document's currency into the journal.
--
-- Problem (proved by insert, 18 Oct 2026): these triggers never read the `currency`
-- column, and nothing restricts it, so a supplier invoice entered as USD 1,000
-- posted expense UGX 1,000 and payables UGX 1,000, both labelled UGX.
--
-- Change: each line now carries 'currency' = the document's currency. The gateway
-- (20261017140000) does the rest:
--   * a document in the functional currency (or with no currency) posts exactly as
--     before, at rate 1;
--   * a foreign document posts in its own currency at the approved rate for its date;
--   * with no approved rate, or no approved fx.rate_max_age_days, the insert is
--     refused loudly (FX_RATE_MISSING / FX_RATE_STALE / REG_PARAM_MISSING) instead of
--     being booked wrongly;
--   * a base-currency rounding difference goes to the company's fx_rounding account,
--     and a company without one is refused (JOURNAL_ROUNDING_ACCOUNT_MISSING) the
--     first time rounding is needed.
--
-- Nothing else changes. The skip-when-posting-rules-are-missing behaviour, the
-- trigger events (AFTER INSERT) and each function's search_path are as they were.
-- No open item is involved in these three flows, so no currency guard applies to them.
--
-- KNOWN LIMIT until A3 slice 3b (realised gain and loss): a foreign invoice that is
-- paid at a different rate than it was booked leaves a base-currency residue on the
-- control account (its balance in the document currency is zero, its base balance is
-- the rate difference), and the matching gain or loss is not yet posted. This is the
-- same figure a realised gain/loss posting will later book; it is far smaller than the
-- misstatement being fixed here and is visible in the ledger.

create or replace function public.trg_post_supplier_invoice()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_expense uuid; v_vat_in uuid; v_wht uuid; v_ap uuid;
  v_net numeric;
  v_ap_amount numeric;
  v_lines jsonb;
begin
  v_expense := get_posting_account(new.tenant_id, 'default_expense');
  v_ap := get_posting_account(new.tenant_id, 'ap_control');
  if v_expense is null or v_ap is null then
    -- Tenant hasn't set up (or hasn't finished setting up) their
    -- posting rules yet -- skip posting rather than fail the insert.
    return new;
  end if;

  if new.wht_amount > 0 then
    v_wht := get_posting_account(new.tenant_id, 'wht_payable');
    if v_wht is null then
      -- Can't post correctly without knowing where the withheld
      -- amount goes -- skip the whole entry.
      return new;
    end if;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;
  v_ap_amount := new.amount_incl_vat - new.wht_amount;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_expense, 'debit', v_net, 'currency', new.currency)
  );
  if new.vat_amount > 0 then
    v_vat_in := get_posting_account(new.tenant_id, 'vat_input');
    if v_vat_in is null then
      return new;
    end if;
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_vat_in, 'debit', new.vat_amount, 'currency', new.currency);
  end if;
  if new.wht_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_wht, 'credit', new.wht_amount, 'currency', new.currency);
  end if;
  if v_ap_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ap, 'credit', v_ap_amount, 'currency', new.currency);
  end if;

  perform post_journal_entry(new.tenant_id, 'supplier_invoice', new.id, new.invoice_date,
    'Supplier invoice ' || new.invoice_number, v_lines);

  return new;
end;
$function$;

create or replace function public.trg_post_receivable_invoice()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ar uuid; v_revenue uuid; v_vat_out uuid;
  v_net numeric;
  v_lines jsonb;
begin
  v_ar := get_posting_account(new.tenant_id, 'ar_control');
  v_revenue := get_posting_account(new.tenant_id, 'default_revenue');
  if v_ar is null or v_revenue is null then
    return new;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ar, 'debit', new.amount_incl_vat, 'currency', new.currency),
    jsonb_build_object('gl_account_id', v_revenue, 'credit', v_net, 'currency', new.currency)
  );
  if new.vat_amount > 0 then
    v_vat_out := get_posting_account(new.tenant_id, 'vat_output');
    if v_vat_out is null then
      return new;
    end if;
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_vat_out, 'credit', new.vat_amount, 'currency', new.currency);
  end if;

  perform post_journal_entry(new.tenant_id, 'receivable_invoice', new.id, new.invoice_date,
    'Receivable invoice ' || new.invoice_number, v_lines);

  return new;
end;
$function$;

create or replace function public.trg_post_cash_bank_transaction()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cash_side uuid;
  v_other_side uuid;
  v_other_role text;
  v_lines jsonb;
begin
  v_other_role := case new.reference_type
    when 'supplier_invoice' then 'ap_control'
    when 'receivable_invoice' then 'ar_control'
    when 'expenditure_slip' then 'default_expense'
    when 'payroll_run' then 'salaries_payable'
    else null
  end;
  if v_other_role is null then
    return new;
  end if;

  v_cash_side := get_posting_account(new.tenant_id, case when new.payment_method = 'bank' then 'bank' else 'cash' end);
  v_other_side := get_posting_account(new.tenant_id, v_other_role);
  if v_cash_side is null or v_other_side is null then
    return new;  -- e.g. this role not mapped yet
  end if;

  if new.transaction_type = 'payment' then
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_other_side, 'debit', new.amount, 'currency', new.currency),
      jsonb_build_object('gl_account_id', v_cash_side, 'credit', new.amount, 'currency', new.currency)
    );
  else -- 'receipt'
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_cash_side, 'debit', new.amount, 'currency', new.currency),
      jsonb_build_object('gl_account_id', v_other_side, 'credit', new.amount, 'currency', new.currency)
    );
  end if;

  perform post_journal_entry(new.tenant_id, 'cash_bank_transaction', new.id, new.transaction_date,
    coalesce(new.description, initcap(new.transaction_type) || ' - ' || new.reference_type), v_lines);

  return new;
end;
$function$;