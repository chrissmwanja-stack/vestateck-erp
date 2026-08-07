
-- Asset Request: employees request a hardware/software asset from IT.
-- IT support reviews (approve/reject) then fulfills by linking an
-- in-stock asset, which creates a real asset_assignments row via the
-- same path as assign_asset() so status/history stay consistent.

create table public.asset_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  requested_by uuid not null references public.app_users(id),
  asset_type text not null check (asset_type in ('hardware','software')),
  item_description text not null,
  justification text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','fulfilled')),
  decided_by uuid references public.app_users(id),
  decided_at timestamptz,
  decision_notes text,
  fulfilled_asset_id uuid references public.assets(id),
  fulfilled_assignment_id uuid references public.asset_assignments(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.asset_requests enable row level security;

-- Requester can see their own; IT support can see all in their tenant.
-- No direct insert/update policies -- writes go through the RPCs below,
-- matching the assets/licenses/asset_assignments pattern already in use.
create policy asset_requests_select on public.asset_requests
  for select
  using (
    tenant_id = get_my_tenant_id()
    and (requested_by = auth.uid() or is_it_support())
  );

create or replace function public.create_asset_request(
  p_asset_type text,
  p_item_description text,
  p_justification text default null
) returns public.asset_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.asset_requests%rowtype;
begin
  if p_asset_type not in ('hardware','software') then
    raise exception 'invalid asset type: %', p_asset_type;
  end if;
  if p_item_description is null or trim(p_item_description) = '' then
    raise exception 'item description is required';
  end if;

  insert into asset_requests (tenant_id, requested_by, asset_type, item_description, justification)
  values (get_my_tenant_id(), auth.uid(), p_asset_type, p_item_description, p_justification)
  returning * into v_request;

  return v_request;
end;
$$;

create or replace function public.get_my_asset_requests()
returns table (
  id uuid,
  asset_type text,
  item_description text,
  justification text,
  status text,
  decision_notes text,
  decided_at timestamptz,
  fulfilled_asset_id uuid,
  fulfilled_asset_tag text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    r.id, r.asset_type, r.item_description, r.justification, r.status,
    r.decision_notes, r.decided_at, r.fulfilled_asset_id, a.asset_tag, r.created_at
  from asset_requests r
  left join assets a on a.id = r.fulfilled_asset_id
  where r.requested_by = auth.uid()
  order by r.created_at desc;
$$;

create or replace function public.get_asset_requests(p_status text default null)
returns table (
  id uuid,
  requested_by uuid,
  requester_name text,
  asset_type text,
  item_description text,
  justification text,
  status text,
  decided_by uuid,
  decided_at timestamptz,
  decision_notes text,
  fulfilled_asset_id uuid,
  fulfilled_asset_tag text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view asset requests';
  end if;

  return query
  select
    r.id, r.requested_by, u.name, r.asset_type, r.item_description, r.justification,
    r.status, r.decided_by, r.decided_at, r.decision_notes,
    r.fulfilled_asset_id, a.asset_tag, r.created_at
  from asset_requests r
  join app_users u on u.id = r.requested_by
  left join assets a on a.id = r.fulfilled_asset_id
  where r.tenant_id = get_my_tenant_id()
    and (p_status is null or r.status = p_status)
  order by r.created_at desc;
end;
$$;

create or replace function public.decide_asset_request(
  p_request_id uuid,
  p_decision text,
  p_notes text default null
) returns public.asset_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.asset_requests%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to decide asset requests';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from asset_requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'pending' then
    raise exception 'request is not pending (status: %)', v_request.status;
  end if;

  update asset_requests
  set status = p_decision,
      decided_by = auth.uid(),
      decided_at = now(),
      decision_notes = p_notes,
      updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_request.tenant_id,
    v_request.requested_by,
    'asset_request_' || p_decision,
    'Asset request ' || p_decision || ': ' || v_request.item_description,
    coalesce(p_notes, 'Your asset request has been ' || p_decision || '.')
  );

  return v_request;
end;
$$;

create or replace function public.fulfill_asset_request(
  p_request_id uuid,
  p_asset_id uuid,
  p_notes text default null
) returns public.asset_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.asset_requests%rowtype;
  v_asset public.assets%rowtype;
  v_assignment public.asset_assignments%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to fulfill asset requests';
  end if;

  select * into v_request from asset_requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'approved' then
    raise exception 'request must be approved before fulfillment (status: %)', v_request.status;
  end if;

  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.type != v_request.asset_type then
    raise exception 'asset type (%) does not match requested type (%)', v_asset.type, v_request.asset_type;
  end if;
  if v_asset.status != 'in_stock' then
    raise exception 'asset is not available (status: %)', v_asset.status;
  end if;

  insert into asset_assignments (tenant_id, asset_id, assigned_to, assigned_by, notes)
  values (v_asset.tenant_id, p_asset_id, v_request.requested_by, auth.uid(), p_notes)
  returning * into v_assignment;

  update assets set status = 'assigned', updated_at = now() where id = p_asset_id;

  update asset_requests
  set status = 'fulfilled',
      fulfilled_asset_id = p_asset_id,
      fulfilled_assignment_id = v_assignment.id,
      updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_asset.tenant_id,
    v_request.requested_by,
    'asset_request_fulfilled',
    'Asset request fulfilled: ' || v_asset.asset_tag,
    format('"%s" (%s) has been assigned to you.', v_asset.name, v_asset.asset_tag)
  );

  return v_request;
end;
$$;
