-- Cost Transactions Inquiry: all cost-center-scoped transactions in one feed
create view public.v_cost_transactions_inquiry with (security_invoker = true) as
select tenant_id, cost_center_id, 'supplier_invoice'::text as source_type, id as source_id,
       invoice_number as reference_no, invoice_date as transaction_date, amount_incl_vat as amount, currency
from public.supplier_invoices
where cost_center_id is not null
union all
select tenant_id, cost_center_id, 'expenditure_slip', id, slip_number, slip_date, amount, currency
from public.expenditure_slips
union all
select r.tenant_id, r.cost_center_id, 'purchase_order', po.id, po.po_number, po.generated_at::date, po.amount, 'UGX'
from public.purchase_orders po
join public.requests r on r.id = po.request_id
where r.cost_center_id is not null;

-- Current Account Extract: a per-vendor/client ledger (debits = invoices, credits = payments/receipts)
create view public.v_account_ledger with (security_invoker = true) as
select tenant_id, vendor_account_id as account_id, 'supplier_invoice'::text as source_type, id as source_id,
       invoice_number as reference_no, invoice_date as transaction_date, amount_incl_vat as debit, 0::numeric as credit, currency
from public.supplier_invoices
where vendor_account_id is not null
union all
select tenant_id, client_account_id, 'receivable_invoice', id, invoice_number, invoice_date, amount_incl_vat, 0::numeric, currency
from public.receivable_invoices
where client_account_id is not null
union all
select cbt.tenant_id,
       case when cbt.reference_type = 'supplier_invoice' then si.vendor_account_id
            when cbt.reference_type = 'receivable_invoice' then ri.client_account_id
       end as account_id,
       'cash_bank_transaction', cbt.id, cbt.description, cbt.transaction_date, 0::numeric, cbt.amount, cbt.currency
from public.cash_bank_transactions cbt
left join public.supplier_invoices si on cbt.reference_type = 'supplier_invoice' and cbt.reference_id = si.id
left join public.receivable_invoices ri on cbt.reference_type = 'receivable_invoice' and cbt.reference_id = ri.id
where cbt.reference_type in ('supplier_invoice', 'receivable_invoice');

-- Trial Balance: net balance per account
create view public.v_trial_balance with (security_invoker = true) as
select a.tenant_id, a.id as account_id, a.account_code, a.name as account_name, ac.name as category_name,
       l.currency, sum(l.debit) as total_debit, sum(l.credit) as total_credit, sum(l.debit) - sum(l.credit) as balance
from public.accounts a
left join public.account_categories ac on ac.id = a.category_id
left join public.v_account_ledger l on l.account_id = a.id
group by a.tenant_id, a.id, a.account_code, a.name, ac.name, l.currency;

-- VAT Report: vat_amount from both invoice types, side by side
create view public.v_vat_report with (security_invoker = true) as
select tenant_id, organization_id, 'supplier_invoice'::text as source_type, id as source_id,
       invoice_number, invoice_date, vat_amount, amount_incl_vat, currency
from public.supplier_invoices
union all
select tenant_id, organization_id, 'receivable_invoice', id, invoice_number, invoice_date, vat_amount, amount_incl_vat, currency
from public.receivable_invoices;

-- Durations (aging): receivable_invoices use their stored status; supplier_invoices have no status
-- column, so "outstanding" is derived by netting against matched cash_bank_transactions
create view public.v_durations with (security_invoker = true) as
select ri.tenant_id, 'receivable_invoice'::text as source_type, ri.id as source_id, ri.invoice_number,
       ri.invoice_date, ri.amount_incl_vat as outstanding_amount, ri.currency, ri.status,
       (current_date - ri.invoice_date) as days_outstanding
from public.receivable_invoices ri
where ri.status = 'open'
union all
select si.tenant_id, 'supplier_invoice', si.id, si.invoice_number, si.invoice_date,
       si.amount_incl_vat - coalesce(paid.total_paid, 0), si.currency,
       'open'::text as status,
       (current_date - si.invoice_date)
from public.supplier_invoices si
left join (
  select reference_id, sum(amount) as total_paid
  from public.cash_bank_transactions
  where reference_type = 'supplier_invoice'
  group by reference_id
) paid on paid.reference_id = si.id
where si.amount_incl_vat - coalesce(paid.total_paid, 0) > 0;
