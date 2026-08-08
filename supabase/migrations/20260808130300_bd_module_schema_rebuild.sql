-- Rebuild of the Business Development schema.
-- The original 20260805090723_bd_module_schema.sql shipped a different design
-- (inline enum columns, clients modeled as bd_client_profiles attached to
-- accounts) than the 32 frontend screens actually built against (FK'd lookup
-- tables, standalone bd_clients/bd_contacts/bd_activities, auto-numbered
-- lead_no/opportunity_no/proposal_no/tender_no). All bd_* tables are still
-- empty in production, so this drops and replaces them rather than papering
-- over the mismatch with a second, parallel set of tables.

create extension if not exists "pgcrypto";

drop table if exists public.bd_client_contacts cascade;
drop table if exists public.bd_client_profiles cascade;
drop table if exists public.bd_proposals cascade;
drop table if exists public.bd_opportunities cascade;
drop table if exists public.bd_tenders cascade;
drop table if exists public.bd_leads cascade;

drop function if exists public.set_proposal_number() cascade;
drop function if exists public.next_proposal_number(uuid) cascade;
drop function if exists public.set_tender_number() cascade;
drop function if exists public.next_tender_number(uuid) cascade;

-- ============ Lookup / config tables ============

create table public.bd_client_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create table public.bd_lead_sources (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create table public.bd_lead_statuses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  status text not null check (status in ('new','contacted','qualified','unqualified','converted','lost')),
  label text not null,
  color text not null default '#90caf9',
  order_index int not null default 0,
  is_active boolean not null default true,
  unique (tenant_id, status)
);

create table public.bd_opportunity_stages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  stage text not null check (stage in ('identification','qualification','proposal','negotiation','closed_won','closed_lost')),
  label text not null,
  probability_default int not null default 10 check (probability_default between 0 and 100),
  color text not null default '#90caf9',
  order_index int not null default 0,
  is_active boolean not null default true,
  unique (tenant_id, stage)
);

create table public.bd_proposal_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create table public.bd_proposal_statuses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  status text not null check (status in ('draft','in_review','pending_approval','approved','sent','accepted','rejected','expired')),
  label text not null,
  color text not null default '#bdbdbd',
  order_index int not null default 0,
  is_active boolean not null default true,
  unique (tenant_id, status)
);

create table public.bd_tender_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

-- ============ Client entities ============

create table public.bd_clients (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  category_id uuid references public.bd_client_categories(id) on delete set null,
  industry text,
  email text,
  phone text,
  website text,
  is_active boolean not null default true,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.bd_contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  client_id uuid not null references public.bd_clients(id) on delete cascade,
  first_name text not null,
  last_name text not null,
  email text,
  phone text,
  position text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.bd_activities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  client_id uuid references public.bd_clients(id) on delete set null,
  type text not null default 'call' check (type in ('call','email','meeting','note','other')),
  subject text not null,
  description text,
  activity_date timestamptz not null default now(),
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now()
);

-- ============ Pipeline: leads -> opportunities -> proposals, plus tenders ============

create table public.bd_leads (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  lead_no text unique,
  company_name text not null,
  contact_name text not null,
  email text,
  phone text,
  source_id uuid references public.bd_lead_sources(id) on delete set null,
  status text not null default 'new' check (status in ('new','contacted','qualified','unqualified','converted','lost')),
  estimated_value numeric(14,2),
  currency text not null default 'USD',
  notes text,
  converted_opportunity_id uuid,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.bd_opportunities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  opportunity_no text unique,
  title text not null,
  client_id uuid references public.bd_clients(id) on delete set null,
  lead_id uuid references public.bd_leads(id) on delete set null,
  stage text not null default 'identification' check (stage in ('identification','qualification','proposal','negotiation','closed_won','closed_lost')),
  probability int check (probability between 0 and 100),
  estimated_value numeric(14,2),
  currency text not null default 'USD',
  expected_close_date date,
  description text,
  lost_reason text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, stage) references public.bd_opportunity_stages(tenant_id, stage)
);

alter table public.bd_leads
  add constraint bd_leads_converted_opportunity_fk
  foreign key (converted_opportunity_id) references public.bd_opportunities(id) on delete set null;

create table public.bd_proposals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  proposal_no text unique,
  title text not null,
  client_id uuid references public.bd_clients(id) on delete set null,
  opportunity_id uuid references public.bd_opportunities(id) on delete set null,
  type_id uuid references public.bd_proposal_types(id) on delete set null,
  total_value numeric(14,2) not null check (total_value > 0),
  currency text not null default 'USD',
  status text not null default 'draft' check (status in ('draft','in_review','pending_approval','approved','sent','accepted','rejected','expired')),
  version int not null default 1,
  valid_until date,
  content text,
  decided_by uuid references public.app_users(id),
  decided_at timestamptz,
  decision_notes text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, status) references public.bd_proposal_statuses(tenant_id, status)
);

create table public.bd_tenders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  tender_no text unique,
  title text not null,
  client_id uuid references public.bd_clients(id) on delete set null,
  type_id uuid references public.bd_tender_types(id) on delete set null,
  status text not null default 'open' check (status in ('open','submitted','under_evaluation','awarded','lost','cancelled')),
  submission_deadline timestamptz,
  estimated_value numeric(14,2),
  currency text not null default 'USD',
  portal_url text,
  description text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============ Indexes ============

create index idx_bd_clients_tenant on public.bd_clients(tenant_id);
create index idx_bd_clients_category on public.bd_clients(category_id);
create index idx_bd_contacts_tenant on public.bd_contacts(tenant_id);
create index idx_bd_contacts_client on public.bd_contacts(client_id);
create index idx_bd_activities_tenant on public.bd_activities(tenant_id);
create index idx_bd_activities_client on public.bd_activities(client_id);
create index idx_bd_leads_tenant on public.bd_leads(tenant_id);
create index idx_bd_leads_source on public.bd_leads(source_id);
create index idx_bd_opportunities_tenant on public.bd_opportunities(tenant_id);
create index idx_bd_opportunities_client on public.bd_opportunities(client_id);
create index idx_bd_opportunities_lead on public.bd_opportunities(lead_id);
create index idx_bd_proposals_tenant on public.bd_proposals(tenant_id);
create index idx_bd_proposals_client on public.bd_proposals(client_id);
create index idx_bd_proposals_opportunity on public.bd_proposals(opportunity_id);
create index idx_bd_tenders_tenant on public.bd_tenders(tenant_id);
create index idx_bd_tenders_client on public.bd_tenders(client_id);

-- ============ Auto numbering (lead_no / opportunity_no / proposal_no / tender_no) ============

create or replace function public.generate_bd_lead_no()
returns trigger language plpgsql as $$
begin
  if NEW.lead_no is null then
    NEW.lead_no := public.next_doc_number(NEW.tenant_id, 'bd_lead', 'BD-L');
  end if;
  return NEW;
end;
$$;
create trigger trg_bd_lead_no before insert on public.bd_leads
  for each row execute function public.generate_bd_lead_no();

create or replace function public.generate_bd_opportunity_no()
returns trigger language plpgsql as $$
begin
  if NEW.opportunity_no is null then
    NEW.opportunity_no := public.next_doc_number(NEW.tenant_id, 'bd_opportunity', 'BD-O');
  end if;
  return NEW;
end;
$$;
create trigger trg_bd_opportunity_no before insert on public.bd_opportunities
  for each row execute function public.generate_bd_opportunity_no();

create or replace function public.generate_bd_proposal_no()
returns trigger language plpgsql as $$
begin
  if NEW.proposal_no is null then
    NEW.proposal_no := public.next_doc_number(NEW.tenant_id, 'bd_proposal', 'BD-P');
  end if;
  return NEW;
end;
$$;
create trigger trg_bd_proposal_no before insert on public.bd_proposals
  for each row execute function public.generate_bd_proposal_no();

create or replace function public.generate_bd_tender_no()
returns trigger language plpgsql as $$
begin
  if NEW.tender_no is null then
    NEW.tender_no := public.next_doc_number(NEW.tenant_id, 'bd_tender', 'BD-T');
  end if;
  return NEW;
end;
$$;
create trigger trg_bd_tender_no before insert on public.bd_tenders
  for each row execute function public.generate_bd_tender_no();

create trigger trg_bd_clients_upd before update on public.bd_clients
  for each row execute function public.handle_updated_at_generic();
create trigger trg_bd_leads_upd before update on public.bd_leads
  for each row execute function public.handle_updated_at_generic();
create trigger trg_bd_opportunities_upd before update on public.bd_opportunities
  for each row execute function public.handle_updated_at_generic();
create trigger trg_bd_proposals_upd before update on public.bd_proposals
  for each row execute function public.handle_updated_at_generic();
create trigger trg_bd_tenders_upd before update on public.bd_tenders
  for each row execute function public.handle_updated_at_generic();

-- ============ RLS ============

alter table public.bd_client_categories enable row level security;
alter table public.bd_lead_sources enable row level security;
alter table public.bd_lead_statuses enable row level security;
alter table public.bd_opportunity_stages enable row level security;
alter table public.bd_proposal_types enable row level security;
alter table public.bd_proposal_statuses enable row level security;
alter table public.bd_tender_types enable row level security;
alter table public.bd_clients enable row level security;
alter table public.bd_contacts enable row level security;
alter table public.bd_activities enable row level security;
alter table public.bd_leads enable row level security;
alter table public.bd_opportunities enable row level security;
alter table public.bd_proposals enable row level security;
alter table public.bd_tenders enable row level security;

-- Lookup tables: any BD user can read; admin manages
create policy "bd_client_categories_select" on public.bd_client_categories for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_client_categories_write" on public.bd_client_categories for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_lead_sources_select" on public.bd_lead_sources for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_lead_sources_write" on public.bd_lead_sources for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_lead_statuses_select" on public.bd_lead_statuses for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_lead_statuses_write" on public.bd_lead_statuses for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_opportunity_stages_select" on public.bd_opportunity_stages for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_opportunity_stages_write" on public.bd_opportunity_stages for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_proposal_types_select" on public.bd_proposal_types for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_proposal_types_write" on public.bd_proposal_types for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_proposal_statuses_select" on public.bd_proposal_statuses for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_proposal_statuses_write" on public.bd_proposal_statuses for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_tender_types_select" on public.bd_tender_types for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_tender_types_write" on public.bd_tender_types for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

-- Core entities: BD users read/write within tenant
create policy "bd_clients_select" on public.bd_clients for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_clients_write" on public.bd_clients for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_contacts_select" on public.bd_contacts for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_contacts_write" on public.bd_contacts for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_activities_select" on public.bd_activities for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_activities_write" on public.bd_activities for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_leads_select" on public.bd_leads for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_leads_write" on public.bd_leads for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_opportunities_select" on public.bd_opportunities for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_opportunities_write" on public.bd_opportunities for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_proposals_select" on public.bd_proposals for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_proposals_write" on public.bd_proposals for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create policy "bd_tenders_select" on public.bd_tenders for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_tenders_write" on public.bd_tenders for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());