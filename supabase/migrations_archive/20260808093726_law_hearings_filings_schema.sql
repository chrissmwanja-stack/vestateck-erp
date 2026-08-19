create extension if not exists "pgcrypto";

-- Case Hearings (linked to law_cases)
create table if not exists public.law_case_hearings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  case_id uuid not null references public.law_cases(id) on delete cascade,
  hearing_date timestamptz not null,
  location text,
  outcome text,
  notes text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now()
);

-- Regulatory Filings (standalone submissions to regulators, not tied to a case)
create table if not exists public.law_regulatory_filings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  title text not null,
  filing_type text,
  reference_no text,
  status text not null default 'pending' check (status in ('pending','filed','approved','rejected')),
  filing_date date,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_law_hearings_tenant on public.law_case_hearings(tenant_id);
create index if not exists idx_law_hearings_case on public.law_case_hearings(case_id);
create index if not exists idx_law_filings_tenant on public.law_regulatory_filings(tenant_id);

-- RLS
alter table public.law_case_hearings enable row level security;
alter table public.law_regulatory_filings enable row level security;

create policy "law_hearings_select" on public.law_case_hearings
  for select using (tenant_id = public.get_my_tenant_id());
create policy "law_hearings_write" on public.law_case_hearings
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('legal', array['admin','manager']));

create policy "law_filings_select" on public.law_regulatory_filings
  for select using (tenant_id = public.get_my_tenant_id());
create policy "law_filings_write" on public.law_regulatory_filings
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('legal', array['admin','manager']));
