-- Organizations: site/route hierarchy, distinct from cost_centers (budget envelopes)
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  company_code text not null,
  site_name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, company_code, site_name)
);

alter table public.organizations enable row level security;

create policy organizations_select on public.organizations
  for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());

create policy organizations_insert on public.organizations
  for insert with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

create policy organizations_update on public.organizations
  for update using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id())
  with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

create policy organizations_delete on public.organizations
  for delete using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

-- Account categories: MAKS-style "Account Type" (FIRMAC etc.) that filters Account List.
-- Distinct from accounts.account_type, which is a vendor/client/both role flag.
create table public.account_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

alter table public.account_categories enable row level security;

create policy account_categories_select on public.account_categories
  for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());

create policy account_categories_insert on public.account_categories
  for insert with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

create policy account_categories_update on public.account_categories
  for update using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id())
  with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

create policy account_categories_delete on public.account_categories
  for delete using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

-- Link accounts to their category (nullable: not every account needs one yet)
alter table public.accounts
  add column category_id uuid references public.account_categories(id);

-- Organization scoping on the same transaction tables that already carry cost_center_id
alter table public.supplier_invoices
  add column organization_id uuid references public.organizations(id);

alter table public.receivable_invoices
  add column organization_id uuid references public.organizations(id);

alter table public.expenditure_slips
  add column organization_id uuid references public.organizations(id);
