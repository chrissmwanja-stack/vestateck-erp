create extension if not exists "pgcrypto";

-- Initiative Categories (lookup)
create table if not exists public.sustainability_initiative_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

-- Metric Types (lookup) — carbon / energy / water / waste etc.
create table if not exists public.sustainability_metric_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  unit text,
  type text not null default 'carbon',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

-- Initiatives
create table if not exists public.sustainability_initiatives (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  title text not null,
  category_id uuid references public.sustainability_initiative_categories(id) on delete set null,
  status text not null default 'planned' check (status in ('planned','in_progress','completed','on_hold')),
  target_value numeric(14,2),
  current_value numeric(14,2),
  owner text,
  start_date date,
  end_date date,
  description text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Metrics (time series values against a metric type)
create table if not exists public.sustainability_metrics (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  metric_type_id uuid references public.sustainability_metric_types(id) on delete set null,
  type text not null default 'carbon',
  value numeric(14,2) not null,
  unit text,
  recorded_date date not null default current_date,
  notes text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now()
);

-- Audits
create table if not exists public.sustainability_audits (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  title text not null,
  type text,
  status text not null default 'scheduled' check (status in ('scheduled','in_progress','completed')),
  audit_date date,
  findings text,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now()
);

-- Certifications
create table if not exists public.sustainability_certifications (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  standard text,
  issue_date date,
  expiry_date date,
  status text not null default 'valid' check (status in ('valid','expired','pending_renewal')),
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_sustain_init_cat_tenant on public.sustainability_initiative_categories(tenant_id);
create index if not exists idx_sustain_metric_types_tenant on public.sustainability_metric_types(tenant_id);
create index if not exists idx_sustain_initiatives_tenant on public.sustainability_initiatives(tenant_id);
create index if not exists idx_sustain_initiatives_category on public.sustainability_initiatives(category_id);
create index if not exists idx_sustain_metrics_tenant on public.sustainability_metrics(tenant_id);
create index if not exists idx_sustain_metrics_type on public.sustainability_metrics(metric_type_id);
create index if not exists idx_sustain_metrics_recorded_date on public.sustainability_metrics(recorded_date);
create index if not exists idx_sustain_audits_tenant on public.sustainability_audits(tenant_id);
create index if not exists idx_sustain_certs_tenant on public.sustainability_certifications(tenant_id);
create index if not exists idx_sustain_certs_expiry on public.sustainability_certifications(expiry_date);

-- RLS
alter table public.sustainability_initiative_categories enable row level security;
alter table public.sustainability_metric_types enable row level security;
alter table public.sustainability_initiatives enable row level security;
alter table public.sustainability_metrics enable row level security;
alter table public.sustainability_audits enable row level security;
alter table public.sustainability_certifications enable row level security;

create policy "sustain_init_cat_select" on public.sustainability_initiative_categories
  for select using (tenant_id = public.get_my_tenant_id());
create policy "sustain_init_cat_write" on public.sustainability_initiative_categories
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('sustainability', array['admin']));

create policy "sustain_metric_types_select" on public.sustainability_metric_types
  for select using (tenant_id = public.get_my_tenant_id());
create policy "sustain_metric_types_write" on public.sustainability_metric_types
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('sustainability', array['admin']));

create policy "sustain_initiatives_select" on public.sustainability_initiatives
  for select using (tenant_id = public.get_my_tenant_id());
create policy "sustain_initiatives_write" on public.sustainability_initiatives
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('sustainability', array['admin','manager']));

create policy "sustain_metrics_select" on public.sustainability_metrics
  for select using (tenant_id = public.get_my_tenant_id());
create policy "sustain_metrics_write" on public.sustainability_metrics
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('sustainability', array['admin','manager']));

create policy "sustain_audits_select" on public.sustainability_audits
  for select using (tenant_id = public.get_my_tenant_id());
create policy "sustain_audits_write" on public.sustainability_audits
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('sustainability', array['admin','manager']));

create policy "sustain_certs_select" on public.sustainability_certifications
  for select using (tenant_id = public.get_my_tenant_id());
create policy "sustain_certs_write" on public.sustainability_certifications
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('sustainability', array['admin','manager']));

create trigger trg_sustain_initiatives_upd before update on public.sustainability_initiatives
  for each row execute function public.handle_updated_at_generic();
