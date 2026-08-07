
-- The existing material_requests table (0 rows, no RLS policies, no FK to
-- material_catalog) was scaffolding for a different shape than what the
-- reference screenshots show. Repurposing it as the batch header rather
-- than leaving a dead orphan table + creating a parallel one: its
-- id/tenant_id/requester_id/created_at already fit; the rest doesn't
-- (item_description/quantity/status/current_stage_id assumed a
-- consumption-style request, not a catalog-governance one).
alter table public.material_requests rename to material_request_batches;

alter table public.material_request_batches
  drop column if exists item_description,
  drop column if exists quantity,
  drop column if exists status,
  drop column if exists current_stage_id,
  drop column if exists department_id,
  drop column if exists cost_center_id;

-- Lookup tables backing the three dropdowns in the request form/report
-- (Malzeme Turu / Mal Grubu / Harici Mal Grubu). Same shape as
-- account_categories: tenant-scoped, code+name, is_active.
create table public.material_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

create table public.material_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

create table public.external_material_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

-- Line items within a batch -- the "MR Item List" grid. One row per
-- proposed material, decided individually (approve/reject), even though
-- the UI also offers bulk "approve all / reject all" on the batch.
create table public.material_request_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  batch_id uuid not null references public.material_request_batches(id) on delete cascade,
  material_type_id uuid references public.material_types(id),
  material_group_id uuid references public.material_groups(id),
  external_material_group_id uuid references public.external_material_groups(id),
  unit text,
  name text not null,                     -- Malzeme Tanim
  description_tr text,
  description_en text,
  description_fr text,
  old_material_code text,                 -- Eski Malzeme No
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  rejection_message text,                 -- Mesaj (report screen)
  material_catalog_id uuid references public.material_catalog(id),
  decided_by uuid references public.app_users(id),
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

-- Extend material_catalog into the real target of approval: multi-language
-- descriptions, classification, legacy code, and an active flag to match
-- every other master table in this schema (accounts, organizations, etc.)
alter table public.material_catalog
  add column if not exists material_type_id uuid references public.material_types(id),
  add column if not exists material_group_id uuid references public.material_groups(id),
  add column if not exists external_material_group_id uuid references public.external_material_groups(id),
  add column if not exists description_tr text,
  add column if not exists description_en text,
  add column if not exists description_fr text,
  add column if not exists old_material_code text,
  add column if not exists is_active boolean not null default true;

-- tenant_id defaults, same pattern used across every other table this session
create or replace function public.set_material_lookup_defaults()
returns trigger
language plpgsql
as $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_material_types_defaults on public.material_types;
create trigger trg_set_material_types_defaults
  before insert on public.material_types
  for each row execute function public.set_material_lookup_defaults();

drop trigger if exists trg_set_material_groups_defaults on public.material_groups;
create trigger trg_set_material_groups_defaults
  before insert on public.material_groups
  for each row execute function public.set_material_lookup_defaults();

drop trigger if exists trg_set_external_material_groups_defaults on public.external_material_groups;
create trigger trg_set_external_material_groups_defaults
  before insert on public.external_material_groups
  for each row execute function public.set_material_lookup_defaults();

create or replace function public.set_material_request_batch_defaults()
returns trigger
language plpgsql
as $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  if NEW.requester_id is null then
    NEW.requester_id := auth.uid();
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_material_request_batch_defaults on public.material_request_batches;
create trigger trg_set_material_request_batch_defaults
  before insert on public.material_request_batches
  for each row execute function public.set_material_request_batch_defaults();

-- Items inherit tenant_id from their batch rather than trusting the client
create or replace function public.set_material_request_item_defaults()
returns trigger
language plpgsql
as $$
begin
  select tenant_id into NEW.tenant_id from material_request_batches where id = NEW.batch_id;
  if NEW.tenant_id is null then
    raise exception 'batch not found or has no tenant';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_material_request_item_defaults on public.material_request_items;
create trigger trg_set_material_request_item_defaults
  before insert on public.material_request_items
  for each row execute function public.set_material_request_item_defaults();

-- RLS
alter table public.material_types enable row level security;
alter table public.material_groups enable row level security;
alter table public.external_material_groups enable row level security;
alter table public.material_request_items enable row level security;
-- material_request_batches and material_catalog already had RLS enabled

create policy material_types_select on public.material_types
  for select using (tenant_id = get_my_tenant_id());
create policy material_types_insert on public.material_types
  for insert with check (has_po_access() and tenant_id = get_my_tenant_id());
create policy material_types_update on public.material_types
  for update using (has_po_access() and tenant_id = get_my_tenant_id())
  with check (has_po_access() and tenant_id = get_my_tenant_id());

create policy material_groups_select on public.material_groups
  for select using (tenant_id = get_my_tenant_id());
create policy material_groups_insert on public.material_groups
  for insert with check (has_po_access() and tenant_id = get_my_tenant_id());
create policy material_groups_update on public.material_groups
  for update using (has_po_access() and tenant_id = get_my_tenant_id())
  with check (has_po_access() and tenant_id = get_my_tenant_id());

create policy external_material_groups_select on public.external_material_groups
  for select using (tenant_id = get_my_tenant_id());
create policy external_material_groups_insert on public.external_material_groups
  for insert with check (has_po_access() and tenant_id = get_my_tenant_id());
create policy external_material_groups_update on public.external_material_groups
  for update using (has_po_access() and tenant_id = get_my_tenant_id())
  with check (has_po_access() and tenant_id = get_my_tenant_id());

create policy material_request_batches_select on public.material_request_batches
  for select using (
    tenant_id = get_my_tenant_id() and (requester_id = auth.uid() or has_po_access())
  );
create policy material_request_batches_insert on public.material_request_batches
  for insert with check (tenant_id = get_my_tenant_id() and requester_id = auth.uid());

create policy material_request_items_select on public.material_request_items
  for select using (
    tenant_id = get_my_tenant_id() and (
      has_po_access()
      or exists (select 1 from material_request_batches b where b.id = batch_id and b.requester_id = auth.uid())
    )
  );
create policy material_request_items_insert on public.material_request_items
  for insert with check (
    tenant_id = get_my_tenant_id()
    and exists (select 1 from material_request_batches b where b.id = batch_id and b.requester_id = auth.uid())
  );
-- No client-side update/delete policy on items: approval/rejection only
-- happens through the SECURITY DEFINER functions below, same pattern as
-- record_approval_decision / complete_purchase_order_manually.

create policy material_catalog_select on public.material_catalog
  for select using (tenant_id = get_my_tenant_id());
create policy material_catalog_update on public.material_catalog
  for update using (has_po_access() and tenant_id = get_my_tenant_id())
  with check (has_po_access() and tenant_id = get_my_tenant_id());
-- No insert policy for material_catalog: rows are only ever created via
-- approve_material_request_item() below.
