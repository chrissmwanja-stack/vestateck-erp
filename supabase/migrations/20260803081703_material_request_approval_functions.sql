
-- Malzeme No auto-numbering, same style as VEN-#### for vendor accounts
create or replace function public.next_material_catalog_code(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(code, '^MAT-', ''), code)::int), 0) + 1
  into v_next_num
  from material_catalog
  where tenant_id = p_tenant_id and code like 'MAT-%';

  return 'MAT-' || lpad(v_next_num::text, 5, '0');
end;
$$;

create or replace function public.approve_material_request_item(p_item_id uuid)
returns material_catalog
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_item material_request_items%rowtype;
  v_batch material_request_batches%rowtype;
  v_catalog material_catalog%rowtype;
begin
  if not has_po_access() then
    raise exception 'not authorized to approve material requests';
  end if;

  select * into v_item from material_request_items
  where id = p_item_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'material request item not found';
  end if;

  if v_item.status <> 'pending' then
    raise exception 'this item has already been decided';
  end if;

  insert into material_catalog (
    tenant_id, name, code, unit, material_type_id, material_group_id,
    external_material_group_id, description_tr, description_en, description_fr,
    old_material_code, is_active
  )
  values (
    v_item.tenant_id, v_item.name, next_material_catalog_code(v_item.tenant_id), v_item.unit,
    v_item.material_type_id, v_item.material_group_id, v_item.external_material_group_id,
    v_item.description_tr, v_item.description_en, v_item.description_fr,
    v_item.old_material_code, true
  )
  returning * into v_catalog;

  update material_request_items
  set status = 'approved', material_catalog_id = v_catalog.id, decided_by = auth.uid(), decided_at = now()
  where id = p_item_id;

  select * into v_batch from material_request_batches where id = v_item.batch_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_item.tenant_id, v_batch.requester_id, 'material_request_approved',
    'Material request approved',
    format('"%s" was approved and added to the material catalog as %s.', v_item.name, v_catalog.code)
  );

  return v_catalog;
end;
$$;

create or replace function public.reject_material_request_item(p_item_id uuid, p_message text)
returns material_request_items
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_item material_request_items%rowtype;
  v_batch material_request_batches%rowtype;
begin
  if not has_po_access() then
    raise exception 'not authorized to reject material requests';
  end if;

  if p_message is null or trim(p_message) = '' then
    raise exception 'a message is required to reject a material request item';
  end if;

  select * into v_item from material_request_items
  where id = p_item_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'material request item not found';
  end if;

  if v_item.status <> 'pending' then
    raise exception 'this item has already been decided';
  end if;

  update material_request_items
  set status = 'rejected', rejection_message = trim(p_message), decided_by = auth.uid(), decided_at = now()
  where id = p_item_id
  returning * into v_item;

  select * into v_batch from material_request_batches where id = v_item.batch_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_item.tenant_id, v_batch.requester_id, 'material_request_rejected',
    'Material request rejected',
    format('"%s" was rejected: %s', v_item.name, trim(p_message))
  );

  return v_item;
end;
$$;

-- Bulk wrappers for "Tumunu Onayla" / "Tumunu Reddet" -- apply to every
-- still-pending item in the batch, skipping ones already decided rather
-- than erroring on the whole batch.
create or replace function public.approve_all_material_request_items(p_batch_id uuid)
returns setof material_catalog
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_item_id uuid;
begin
  for v_item_id in
    select id from material_request_items
    where batch_id = p_batch_id and tenant_id = get_my_tenant_id() and status = 'pending'
  loop
    return next approve_material_request_item(v_item_id);
  end loop;
end;
$$;

create or replace function public.reject_all_material_request_items(p_batch_id uuid, p_message text)
returns setof material_request_items
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_item_id uuid;
begin
  for v_item_id in
    select id from material_request_items
    where batch_id = p_batch_id and tenant_id = get_my_tenant_id() and status = 'pending'
  loop
    return next reject_material_request_item(v_item_id, p_message);
  end loop;
end;
$$;

-- Read helper for the approval queue screen: one row per pending batch
-- with requester info, matching "Malzeme Talep Listesi" (Talep Eden /
-- Talep Tarihi).
create or replace function public.get_pending_material_request_batches()
returns table (
  batch_id uuid,
  requester_id uuid,
  requester_name text,
  requested_at timestamptz,
  pending_item_count bigint
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select b.id, b.requester_id, u.name, b.created_at, count(i.id)
  from material_request_batches b
  join app_users u on u.id = b.requester_id
  join material_request_items i on i.batch_id = b.id and i.status = 'pending'
  where b.tenant_id = get_my_tenant_id() and has_po_access()
  group by b.id, b.requester_id, u.name, b.created_at
  order by b.created_at;
$$;

grant execute on function public.approve_material_request_item(uuid) to authenticated;
grant execute on function public.reject_material_request_item(uuid, text) to authenticated;
grant execute on function public.approve_all_material_request_items(uuid) to authenticated;
grant execute on function public.reject_all_material_request_items(uuid, text) to authenticated;
grant execute on function public.get_pending_material_request_batches() to authenticated;
