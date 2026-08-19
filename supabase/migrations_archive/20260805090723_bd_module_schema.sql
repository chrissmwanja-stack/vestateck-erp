
-- Business Development department (mirrors the IT Support / department-based
-- role pattern already used by is_it_support()). The set_department_defaults
-- trigger overwrites tenant_id from auth.uid(), which isn't set in a
-- migration context, so bypass it for this seed insert only.
alter table departments disable trigger trg_set_department_defaults;

insert into departments (id, tenant_id, name)
select '00000000-0000-0000-0000-000000000016', t.id, 'Business Development'
from tenants t
where not exists (select 1 from departments where name = 'Business Development');

alter table departments enable trigger trg_set_department_defaults;

create or replace function public.is_business_dev()
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from app_users u
    join departments d on d.id = u.department_id
    where u.id = auth.uid()
      and (d.name = 'Business Development' or u.is_platform_admin)
  );
$$;

-- Leads
create table public.bd_leads (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  company_name text not null,
  contact_name text,
  contact_email text,
  contact_phone text,
  source text check (source is null or source in ('referral','website','cold_outreach','event','other')),
  status text not null default 'new' check (status in ('new','contacted','qualified','disqualified','converted')),
  notes text,
  owner_id uuid references app_users(id),
  converted_opportunity_id uuid,
  created_by uuid not null default auth.uid() references app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Opportunities
create table public.bd_opportunities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  name text not null,
  client_account_id uuid references accounts(id),
  lead_id uuid references bd_leads(id),
  amount numeric check (amount is null or amount >= 0),
  currency text not null default 'UGX',
  stage text not null default 'prospecting' check (stage in ('prospecting','qualification','proposal','negotiation','won','lost')),
  probability integer check (probability is null or (probability between 0 and 100)),
  expected_close_date date,
  owner_id uuid references app_users(id),
  lost_reason text,
  created_by uuid not null default auth.uid() references app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz
);

alter table public.bd_leads
  add constraint bd_leads_converted_opportunity_id_fkey
  foreign key (converted_opportunity_id) references bd_opportunities(id);

-- Proposals
create table public.bd_proposals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  opportunity_id uuid not null references bd_opportunities(id),
  proposal_number text unique,
  title text not null,
  amount numeric not null check (amount > 0),
  currency text not null default 'UGX',
  status text not null default 'draft' check (status in ('draft','pending_approval','approved','rejected','sent')),
  submitted_by uuid not null default auth.uid() references app_users(id),
  decided_by uuid references app_users(id),
  decided_at timestamptz,
  decision_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Client profiles: 1:1 extension of accounts for BD-specific context.
-- Keeps accounts (used by receivable/supplier invoices) as the single
-- source of truth for the underlying party.
create table public.bd_client_profiles (
  account_id uuid primary key references accounts(id),
  tenant_id uuid not null references tenants(id),
  industry text,
  account_manager_id uuid references app_users(id),
  relationship_stage text not null default 'active' check (relationship_stage in ('prospect','active','dormant','churned')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.bd_client_contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  account_id uuid not null references accounts(id),
  name text not null,
  title text,
  email text,
  phone text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

-- Tenders
create table public.bd_tenders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  tender_number text unique,
  title text not null,
  client_account_id uuid references accounts(id),
  client_name text,
  estimated_value numeric check (estimated_value is null or estimated_value >= 0),
  currency text not null default 'UGX',
  submission_deadline date,
  status text not null default 'identified' check (status in ('identified','preparing','submitted','shortlisted','won','lost','withdrawn')),
  assigned_to uuid references app_users(id),
  notes text,
  created_by uuid not null default auth.uid() references app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz
);

alter table public.bd_leads enable row level security;
alter table public.bd_opportunities enable row level security;
alter table public.bd_proposals enable row level security;
alter table public.bd_client_profiles enable row level security;
alter table public.bd_client_contacts enable row level security;
alter table public.bd_tenders enable row level security;

create policy bd_leads_select on public.bd_leads for select using (tenant_id = get_my_tenant_id() and is_business_dev());
create policy bd_opportunities_select on public.bd_opportunities for select using (tenant_id = get_my_tenant_id() and is_business_dev());
create policy bd_proposals_select on public.bd_proposals for select using (tenant_id = get_my_tenant_id() and is_business_dev());
create policy bd_client_profiles_select on public.bd_client_profiles for select using (tenant_id = get_my_tenant_id() and is_business_dev());
create policy bd_client_contacts_select on public.bd_client_contacts for select using (tenant_id = get_my_tenant_id() and is_business_dev());
create policy bd_tenders_select on public.bd_tenders for select using (tenant_id = get_my_tenant_id() and is_business_dev());
