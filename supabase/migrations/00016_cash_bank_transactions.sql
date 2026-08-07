-- Cash and Bank Operations: a single ledger of payments/receipts that can
-- settle against a supplier invoice, an expenditure slip, or a receivable
-- invoice. reference_type + reference_id is a polymorphic reference
-- (Option 1) — validated in the app layer, not enforced by a DB FK, since
-- one column can't carry a real foreign key to three different tables.
create table if not exists cash_bank_transactions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  transaction_type text not null check (transaction_type in ('payment', 'receipt')),
  reference_type text check (reference_type in ('supplier_invoice', 'expenditure_slip', 'receivable_invoice')),
  reference_id uuid,
  amount numeric(14,2) not null check (amount > 0),
  currency text not null default 'UGX',
  transaction_date date not null,
  payment_method text not null,
  account_name text,
  description text,
  recorded_by uuid not null references app_users(id),
  created_at timestamptz not null default now(),
  -- both null (a general/unattached transaction) or both set — never one
  -- without the other, so the app layer always has a complete pointer.
  constraint reference_pair_complete check (
    (reference_type is null and reference_id is null) or
    (reference_type is not null and reference_id is not null)
  )
);

alter table cash_bank_transactions enable row level security;

create index if not exists idx_cash_bank_transactions_tenant on cash_bank_transactions(tenant_id);
create index if not exists idx_cash_bank_transactions_reference on cash_bank_transactions(reference_type, reference_id);
create index if not exists idx_cash_bank_transactions_date on cash_bank_transactions(transaction_date);