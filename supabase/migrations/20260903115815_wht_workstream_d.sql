-- Workstream D: WHT (withholding tax) on supplier invoices. Uganda WHT
-- on goods/services and professional fees paid to residents is 6% of
-- the gross invoice value, required of URA-designated withholding
-- agents on payments (aggregate per supplier/contract) over UGX
-- 1,000,000 -- confirmed against current URA guidance as of Sep 2026.
-- Rates and thresholds are set by the Income Tax Act and can change
-- with a Finance Act; reconfirm before assuming 6% still applies.
-- This migration only captures and posts the amount -- whether a
-- given tenant is a designated agent and whether a given supplier is
-- exempt is a business judgment made in the UI at entry time, not
-- enforced here (same spirit as vat_amount today).

alter table public.supplier_invoices
  add column if not exists wht_rate numeric,
  add column if not exists wht_amount numeric not null default 0;

alter table public.supplier_invoices
  add constraint supplier_invoices_wht_rate_check
    check (wht_rate is null or (wht_rate >= 0 and wht_rate <= 100)),
  add constraint supplier_invoices_wht_amount_check
    check (wht_amount >= 0 and wht_amount <= amount_incl_vat);

comment on column public.supplier_invoices.wht_rate is
  'WHT rate applied at entry time, as a percentage (e.g. 6 for 6%). Null when the invoice is not subject to WHT. Uganda''s standard rate for goods/services/professional fees to residents is 6% as of Sep 2026 -- confirm against current URA guidance before assuming it still applies.';
comment on column public.supplier_invoices.wht_amount is
  'WHT withheld from this invoice, reducing the net cash payable to the vendor. Posted to the WHT Payable control account (gl_control_accounts.wht_payable_account_id) as part of the invoice journal entry -- see trg_post_supplier_invoice().';

-- WHT Payable control account -- nullable. Existing tenants already
-- have a gl_control_accounts row; a new NOT NULL column would break
-- it. The posting trigger below skips WHT posting (same "skip, don't
-- guess" pattern used when a tenant has no control accounts at all)
-- when an invoice carries wht_amount but this isn't configured yet.
alter table public.gl_control_accounts
  add column if not exists wht_payable_account_id uuid references public.gl_accounts(id);

-- Re-post supplier invoices: same Dr expense (net) / Dr VAT input as
-- before. The AP control credit is now net of any WHT withheld, and
-- the withheld amount is credited to WHT Payable instead -- so the
-- vendor is only ever owed, and only ever paid (via the existing,
-- unchanged cash_bank_transaction trigger), the net-of-WHT amount.
create or replace function public.trg_post_supplier_invoice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctl gl_control_accounts%rowtype;
  v_net numeric;
  v_ap_amount numeric;
  v_lines jsonb;
begin
  select * into v_ctl from gl_control_accounts where tenant_id = new.tenant_id;
  if not found then
    -- Tenant hasn't run seed_default_chart_of_accounts() yet -- skip
    -- posting rather than fail the invoice insert.
    return new;
  end if;

  if new.wht_amount > 0 and v_ctl.wht_payable_account_id is null then
    -- Can't post correctly without knowing where the withheld amount
    -- goes -- skip the whole entry rather than credit AP for the full
    -- gross amount, which would overstate what's actually owed.
    return new;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;
  v_ap_amount := new.amount_incl_vat - new.wht_amount;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ctl.default_expense_account_id, 'debit', v_net)
  );
  if new.vat_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.vat_input_account_id, 'debit', new.vat_amount);
  end if;
  if new.wht_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.wht_payable_account_id, 'credit', new.wht_amount);
  end if;
  -- Guard against a (pathological) 100%-WHT invoice leaving nothing
  -- for the AP leg -- a zero-amount line would fail the "one side,
  -- non-zero" check on journal_entry_lines.
  if v_ap_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.ap_control_account_id, 'credit', v_ap_amount);
  end if;

  perform post_journal_entry(new.tenant_id, 'supplier_invoice', new.id, new.invoice_date,
    'Supplier invoice ' || new.invoice_number, v_lines);

  return new;
end;
$$;

-- Extend the starter COA seed with a WHT Payable control account, for
-- tenants seeding fresh going forward. Already-seeded tenants aren't
-- retrofitted (seed_default_chart_of_accounts() is a one-time,
-- idempotent-by-refusal setup call) -- they add the account and set
-- the mapping via Chart of Accounts admin, same as any other
-- post-seed COA change.
create or replace function public.seed_default_chart_of_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_ap uuid; v_ar uuid; v_bank uuid; v_cash uuid;
  v_vat_in uuid; v_vat_out uuid; v_expense uuid; v_revenue uuid; v_wht uuid;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to set up the chart of accounts';
  end if;

  if exists (select 1 from gl_accounts where tenant_id = v_tenant_id) then
    raise exception 'chart of accounts already exists for this tenant';
  end if;

  insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account) values
    (v_tenant_id, '1000', 'Bank', 'asset', true),
    (v_tenant_id, '1010', 'Cash', 'asset', true),
    (v_tenant_id, '1100', 'Accounts Receivable Control', 'asset', true),
    (v_tenant_id, '1200', 'VAT Input', 'asset', true),
    (v_tenant_id, '2000', 'Accounts Payable Control', 'liability', true),
    (v_tenant_id, '2100', 'VAT Output', 'liability', true),
    (v_tenant_id, '2200', 'WHT Payable', 'liability', true),
    (v_tenant_id, '4000', 'Sales Revenue', 'revenue', false),
    (v_tenant_id, '5000', 'General Expense', 'expense', false);

  select id into v_bank from gl_accounts where tenant_id = v_tenant_id and account_code = '1000';
  select id into v_cash from gl_accounts where tenant_id = v_tenant_id and account_code = '1010';
  select id into v_ar from gl_accounts where tenant_id = v_tenant_id and account_code = '1100';
  select id into v_vat_in from gl_accounts where tenant_id = v_tenant_id and account_code = '1200';
  select id into v_ap from gl_accounts where tenant_id = v_tenant_id and account_code = '2000';
  select id into v_vat_out from gl_accounts where tenant_id = v_tenant_id and account_code = '2100';
  select id into v_wht from gl_accounts where tenant_id = v_tenant_id and account_code = '2200';
  select id into v_revenue from gl_accounts where tenant_id = v_tenant_id and account_code = '4000';
  select id into v_expense from gl_accounts where tenant_id = v_tenant_id and account_code = '5000';

  insert into gl_control_accounts (
    tenant_id, ap_control_account_id, ar_control_account_id, bank_account_id, cash_account_id,
    vat_input_account_id, vat_output_account_id, default_expense_account_id, default_revenue_account_id,
    wht_payable_account_id
  ) values (
    v_tenant_id, v_ap, v_ar, v_bank, v_cash, v_vat_in, v_vat_out, v_expense, v_revenue, v_wht
  );
end;
$$;

-- Remittance + certificate reporting. One row per WHT-bearing supplier
-- invoice. Remittance due date is the 15th of the month after the
-- invoice date -- same filing deadline URA sets for VAT (Income Tax
-- Act / URA practice as of Sep 2026; reconfirm if this migrates).
-- security_invoker relies on supplier_invoices/accounts RLS, same
-- pattern as v_vat_report.
create or replace view public.v_wht_report with (security_invoker = true) as
select
  si.tenant_id,
  si.organization_id,
  si.id as source_id,
  si.invoice_number,
  si.invoice_date,
  si.wht_rate,
  si.wht_amount,
  si.amount_incl_vat,
  si.currency,
  (si.amount_incl_vat - si.wht_amount) as net_payable,
  a.id as vendor_account_id,
  a.name as vendor_name,
  a.account_code as vendor_account_code,
  a.tax_id as vendor_tax_id,
  (date_trunc('month', si.invoice_date) + interval '1 month' + interval '14 days')::date as remittance_due_date
from public.supplier_invoices si
left join public.accounts a on a.id = si.vendor_account_id
where si.wht_amount > 0;

grant select on public.v_wht_report to authenticated;