create extension if not exists "pgcrypto";

-- Contract Types
create table if not exists public.law_contract_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

-- Case Types
create table if not exists public.law_case_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

-- Contracts
create table if not exists public.law_contracts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  contract_no text not null,
  title text not null,
  type_id uuid references public.law_contract_types(id) on delete set null,
  party_name text not null,
  status text not null default 'draft' check (status in ('draft','pending_approval','active','expired','terminated')),
  start_date date,
  end_date date,
  value numeric(14,2),
  currency text not null default 'USD',
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, contract_no)
);

-- Cases
create table if not exists public.law_cases (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  case_no text not null,
  title text not null,
  type_id uuid references public.law_case_types(id) on delete set null,
  status text not null default 'open' check (status in ('open','in_progress','closed','on_hold')),
  description text,
  lawyer_name text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, case_no)
);

-- Compliance Register
create table if not exists public.law_compliance_register (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  item_no text not null,
  title text not null,
  regulation text,
  status text not null default 'pending' check (status in ('compliant','non_compliant','pending','overdue')),
  due_date date,
  owner_id uuid references public.app_users(id),
  created_by uuid not null references public.app_users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  unique (tenant_id, item_no)
);

-- Indexes
create index if not exists idx_law_contract_types_tenant on public.law_contract_types(tenant_id);
create index if not exists idx_law_case_types_tenant on public.law_case_types(tenant_id);
create index if not exists idx_law_contracts_tenant on public.law_contracts(tenant_id);
create index if not exists idx_law_contracts_type on public.law_contracts(type_id);
create index if not exists idx_law_cases_tenant on public.law_cases(tenant_id);
create index if not exists idx_law_cases_type on public.law_cases(type_id);
create index if not exists idx_law_compliance_tenant on public.law_compliance_register(tenant_id);
create index if not exists idx_law_compliance_owner on public.law_compliance_register(owner_id);

-- RLS enable
alter table public.law_contract_types enable row level security;
alter table public.law_case_types enable row level security;
alter table public.law_contracts enable row level security;
alter table public.law_cases enable row level security;
alter table public.law_compliance_register enable row level security;

create policy "law_contract_types_select" on public.law_contract_types
  for select using (tenant_id = public.get_my_tenant_id());
create policy "law_contract_types_write" on public.law_contract_types
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('legal', array['admin']));

create policy "law_case_types_select" on public.law_case_types
  for select using (tenant_id = public.get_my_tenant_id());
create policy "law_case_types_write" on public.law_case_types
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('legal', array['admin']));

create policy "law_contracts_select" on public.law_contracts
  for select using (tenant_id = public.get_my_tenant_id());
create policy "law_contracts_write" on public.law_contracts
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('legal', array['admin','manager']));

create policy "law_cases_select" on public.law_cases
  for select using (tenant_id = public.get_my_tenant_id());
create policy "law_cases_write" on public.law_cases
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('legal', array['admin','manager']));

create policy "law_compliance_select" on public.law_compliance_register
  for select using (tenant_id = public.get_my_tenant_id());
create policy "law_compliance_insert" on public.law_compliance_register
  for insert with check (tenant_id = public.get_my_tenant_id() and public.has_module_role('legal', array['admin','manager']));
create policy "law_compliance_update" on public.law_compliance_register
  for update using (
    tenant_id = public.get_my_tenant_id() and (
      public.has_module_role('legal', array['admin','manager'])
      or owner_id = auth.uid()
    )
  );

-- Auto numbers via shared sequence function
create or replace function public.generate_law_contract_no()
returns trigger language plpgsql as $$
begin
  NEW.contract_no := public.next_doc_number(NEW.tenant_id, 'law_contract', 'LAW-C');
  return NEW;
end;
$$;
create trigger trg_law_contract_no before insert on public.law_contracts
  for each row execute function public.generate_law_contract_no();

create or replace function public.generate_law_case_no()
returns trigger language plpgsql as $$
begin
  NEW.case_no := public.next_doc_number(NEW.tenant_id, 'law_case', 'LAW-CASE');
  return NEW;
end;
$$;
create trigger trg_law_case_no before insert on public.law_cases
  for each row execute function public.generate_law_case_no();

create or replace function public.generate_law_compliance_no()
returns trigger language plpgsql as $$
begin
  NEW.item_no := public.next_doc_number(NEW.tenant_id, 'law_compliance', 'LAW-COMP');
  return NEW;
end;
$$;
create trigger trg_law_compliance_no before insert on public.law_compliance_register
  for each row execute function public.generate_law_compliance_no();

create trigger trg_law_contracts_upd before update on public.law_contracts
  for each row execute function public.handle_updated_at_generic();
create trigger trg_law_cases_upd before update on public.law_cases
  for each row execute function public.handle_updated_at_generic();
