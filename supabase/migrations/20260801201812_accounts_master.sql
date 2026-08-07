
create table accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  account_code text not null,
  name text not null,
  account_type text not null check (account_type in ('vendor', 'client', 'both')),
  contact_name text,
  contact_phone text,
  contact_email text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, account_code)
);

alter table accounts enable row level security;

create index idx_accounts_tenant on accounts(tenant_id);

create trigger accounts_touch_updated_at
  before update on accounts
  for each row execute function touch_updated_at();

-- Read: any finance team member (any role) can browse the account master,
-- same visibility level as the four ledger tables.
create policy accounts_select on accounts
  for select
  using (is_finance_team_member(null) and tenant_id = get_my_tenant_id());

-- Write: restricted to the 'finance' role, matching the write policies on
-- supplier_invoices / receivable_invoices / expenditure_slips / cash_bank_transactions.
create policy accounts_insert on accounts
  for insert
  with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

create policy accounts_update on accounts
  for update
  using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id())
  with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

create policy accounts_delete on accounts
  for delete
  using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

-- Link supplier_invoices to a vendor/both account instead of free-text vendor_name.
alter table supplier_invoices
  add column vendor_account_id uuid references accounts(id);

alter table supplier_invoices drop column vendor_name;

-- Link receivable_invoices to a client/both account instead of free-text client_name.
alter table receivable_invoices
  add column client_account_id uuid references accounts(id);

alter table receivable_invoices drop column client_name;
