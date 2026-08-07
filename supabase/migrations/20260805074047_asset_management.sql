-- Assets: one table, discriminated by type (hardware/software) --
-- mirrors the supplier_invoices single-table-with-type-column pattern
create table assets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  asset_tag text unique,
  type text not null check (type in ('hardware','software')),
  name text not null,
  category text,
  serial_number text,
  vendor text,
  purchase_date date,
  purchase_cost numeric,
  status text not null default 'in_stock' check (status in ('in_stock','assigned','maintenance','retired')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table asset_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  asset_id uuid not null references assets(id),
  assigned_to uuid not null references app_users(id),
  assigned_by uuid references app_users(id),
  assigned_at timestamptz not null default now(),
  returned_at timestamptz,
  notes text
);

create table licenses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  asset_id uuid not null references assets(id),
  license_key text,
  seats_total int not null default 1,
  vendor text,
  expiry_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table assets enable row level security;
alter table asset_assignments enable row level security;
alter table licenses enable row level security;

-- Staff-only viewing, consistent with problems/it_tickets(all) pattern.
-- All writes go through RPCs below, no direct grants.
create policy assets_select on assets
  for select using (tenant_id = get_my_tenant_id() and is_it_support());
create policy asset_assignments_select on asset_assignments
  for select using (tenant_id = get_my_tenant_id() and is_it_support());
create policy licenses_select on licenses
  for select using (tenant_id = get_my_tenant_id() and is_it_support());

-- Numbering, same pattern as tickets/problems
create or replace function public.next_asset_tag(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(asset_tag, '^AST-', ''), asset_tag)::int), 0) + 1
  into v_next_num
  from assets
  where tenant_id = p_tenant_id and asset_tag like 'AST-%';

  return 'AST-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

create or replace function public.set_asset_tag()
returns trigger
language plpgsql
as $function$
begin
  if NEW.asset_tag is null then
    NEW.asset_tag := next_asset_tag(NEW.tenant_id);
  end if;
  return NEW;
end;
$function$;

create trigger trg_set_asset_tag
before insert on assets
for each row execute function set_asset_tag();

-- Asset CRUD
create or replace function public.create_asset(
  p_type text,
  p_name text,
  p_category text default null,
  p_serial_number text default null,
  p_vendor text default null,
  p_purchase_date date default null,
  p_purchase_cost numeric default null,
  p_notes text default null
)
returns assets
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create assets';
  end if;
  if p_type not in ('hardware','software') then
    raise exception 'invalid type: %', p_type;
  end if;

  insert into assets (tenant_id, type, name, category, serial_number, vendor, purchase_date, purchase_cost, notes)
  values (get_my_tenant_id(), p_type, p_name, p_category, p_serial_number, p_vendor, p_purchase_date, p_purchase_cost, p_notes)
  returning * into v_asset;

  return v_asset;
end;
$function$;

create or replace function public.update_asset(
  p_asset_id uuid,
  p_name text default null,
  p_category text default null,
  p_serial_number text default null,
  p_vendor text default null,
  p_purchase_cost numeric default null,
  p_status text default null,
  p_notes text default null
)
returns assets
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update assets';
  end if;
  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  -- 'assigned' status is only set via assign_asset/return_asset, not here
  if p_status is not null and p_status not in ('in_stock','maintenance','retired') then
    raise exception 'invalid status for direct update: %', p_status;
  end if;
  if p_status is not null and v_asset.status = 'assigned' then
    raise exception 'asset is currently assigned; return it before changing status';
  end if;

  update assets
  set name = coalesce(p_name, name),
      category = coalesce(p_category, category),
      serial_number = coalesce(p_serial_number, serial_number),
      vendor = coalesce(p_vendor, vendor),
      purchase_cost = coalesce(p_purchase_cost, purchase_cost),
      status = coalesce(p_status, status),
      notes = coalesce(p_notes, notes),
      updated_at = now()
  where id = p_asset_id
  returning * into v_asset;

  return v_asset;
end;
$function$;

create or replace function public.get_assets(p_type text default null)
returns setof assets
language sql
stable security definer
set search_path to 'public'
as $function$
  select * from assets
  where tenant_id = get_my_tenant_id() and is_it_support()
    and (p_type is null or type = p_type)
  order by created_at desc;
$function$;

-- Assignments
create or replace function public.assign_asset(p_asset_id uuid, p_assigned_to uuid, p_notes text default null)
returns asset_assignments
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_asset public.assets%rowtype;
  v_assignment public.asset_assignments%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to assign assets';
  end if;
  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.status != 'in_stock' then
    raise exception 'asset is not available (status: %)', v_asset.status;
  end if;

  insert into asset_assignments (tenant_id, asset_id, assigned_to, assigned_by, notes)
  values (v_asset.tenant_id, p_asset_id, p_assigned_to, auth.uid(), p_notes)
  returning * into v_assignment;

  update assets set status = 'assigned', updated_at = now() where id = p_asset_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_asset.tenant_id,
    p_assigned_to,
    'asset_assigned',
    'Asset assigned: ' || v_asset.asset_tag,
    format('"%s" (%s) has been assigned to you.', v_asset.name, v_asset.asset_tag)
  );

  return v_assignment;
end;
$function$;

create or replace function public.return_asset(p_assignment_id uuid, p_notes text default null)
returns asset_assignments
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_assignment public.asset_assignments%rowtype;
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to return assets';
  end if;
  select * into v_assignment from asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'assignment not found';
  end if;
  if v_assignment.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this assignment';
  end if;
  if v_assignment.returned_at is not null then
    raise exception 'assignment already returned';
  end if;

  update asset_assignments
  set returned_at = now(),
      notes = coalesce(p_notes, notes)
  where id = p_assignment_id
  returning * into v_assignment;

  update assets set status = 'in_stock', updated_at = now()
  where id = v_assignment.asset_id
  returning * into v_asset;

  return v_assignment;
end;
$function$;

create or replace function public.get_asset_assignments(p_active_only boolean default true)
returns table (
  id uuid,
  asset_id uuid,
  asset_tag text,
  asset_name text,
  asset_type text,
  assigned_to uuid,
  assigned_to_name text,
  assigned_by uuid,
  assigned_at timestamptz,
  returned_at timestamptz,
  notes text
)
language sql
stable security definer
set search_path to 'public'
as $function$
  select
    aa.id, aa.asset_id, a.asset_tag, a.name as asset_name, a.type as asset_type,
    aa.assigned_to, u.name as assigned_to_name, aa.assigned_by, aa.assigned_at, aa.returned_at, aa.notes
  from asset_assignments aa
  join assets a on a.id = aa.asset_id
  join app_users u on u.id = aa.assigned_to
  where aa.tenant_id = get_my_tenant_id() and is_it_support()
    and (not p_active_only or aa.returned_at is null)
  order by aa.assigned_at desc;
$function$;

-- Licenses
create or replace function public.create_license(
  p_asset_id uuid,
  p_seats_total int default 1,
  p_license_key text default null,
  p_vendor text default null,
  p_expiry_date date default null,
  p_notes text default null
)
returns licenses
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_asset public.assets%rowtype;
  v_license public.licenses%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create licenses';
  end if;
  select * into v_asset from assets where id = p_asset_id;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.type != 'software' then
    raise exception 'licenses can only be linked to software assets';
  end if;

  insert into licenses (tenant_id, asset_id, license_key, seats_total, vendor, expiry_date, notes)
  values (v_asset.tenant_id, p_asset_id, p_license_key, p_seats_total, p_vendor, p_expiry_date, p_notes)
  returning * into v_license;

  return v_license;
end;
$function$;

create or replace function public.update_license(
  p_license_id uuid,
  p_license_key text default null,
  p_seats_total int default null,
  p_vendor text default null,
  p_expiry_date date default null,
  p_notes text default null
)
returns licenses
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_license public.licenses%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update licenses';
  end if;
  select * into v_license from licenses where id = p_license_id for update;
  if not found then
    raise exception 'license not found';
  end if;
  if v_license.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this license';
  end if;

  update licenses
  set license_key = coalesce(p_license_key, license_key),
      seats_total = coalesce(p_seats_total, seats_total),
      vendor = coalesce(p_vendor, vendor),
      expiry_date = coalesce(p_expiry_date, expiry_date),
      notes = coalesce(p_notes, notes),
      updated_at = now()
  where id = p_license_id
  returning * into v_license;

  return v_license;
end;
$function$;

-- seats_used is computed from active assignments on the linked asset
-- rather than stored, so it can't drift out of sync
create or replace function public.get_licenses()
returns table (
  id uuid,
  asset_id uuid,
  asset_tag text,
  asset_name text,
  license_key text,
  seats_total int,
  seats_used bigint,
  vendor text,
  expiry_date date,
  notes text
)
language sql
stable security definer
set search_path to 'public'
as $function$
  select
    l.id, l.asset_id, a.asset_tag, a.name as asset_name, l.license_key, l.seats_total,
    (select count(*) from asset_assignments aa where aa.asset_id = l.asset_id and aa.returned_at is null) as seats_used,
    l.vendor, l.expiry_date, l.notes
  from licenses l
  join assets a on a.id = l.asset_id
  where l.tenant_id = get_my_tenant_id() and is_it_support()
  order by l.expiry_date nulls last, l.created_at desc;
$function$;
