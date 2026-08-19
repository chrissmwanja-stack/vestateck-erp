-- 1. requests: organization_id + real MR numbering
alter table requests add column if not exists organization_id uuid references organizations(id);
alter table requests add column if not exists mr_number text;

create unique index if not exists requests_mr_number_key on requests (mr_number) where mr_number is not null;

create or replace function next_mr_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(mr_number, '^MR-', ''), mr_number)::int), 0) + 1
  into v_next_num
  from requests
  where tenant_id = p_tenant_id and mr_number like 'MR-%';

  return 'MR-' || lpad(v_next_num::text, 5, '0');
end;
$$;

create or replace function set_request_mr_number()
returns trigger
language plpgsql
as $$
begin
  if NEW.mr_number is null then
    NEW.mr_number := next_mr_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_request_mr_number on requests;
create trigger trg_set_request_mr_number
before insert on requests
for each row execute function set_request_mr_number();

-- backfill existing rows in creation order so numbering reflects history
do $$
declare
  r record;
begin
  for r in select id, tenant_id from requests where mr_number is null order by created_at
  loop
    update requests set mr_number = next_mr_number(tenant_id) where id = r.id;
  end loop;
end $$;

alter table requests alter column mr_number set not null;

-- 2. purchase_orders: legacy/initial PO number + currency (POs can be non-UGX, per reference data)
alter table purchase_orders add column if not exists initial_po_number text;
alter table purchase_orders add column if not exists currency text not null default 'UGX';

-- 3. RLS: has_po_access() users need read access across all tenant requests/orgs
--    for reporting -- requests_select_own_or_actionable only covers "mine or
--    currently actionable", which is too narrow for Request Tracking /
--    Procurement Info Edit. Additive policies (OR'd with existing ones).
create policy requests_select_po_access on requests
  for select
  using (has_po_access() and tenant_id = get_my_tenant_id());

create policy organizations_select_po_access on organizations
  for select
  using (has_po_access() and tenant_id = get_my_tenant_id());

create policy po_edits_insert_finance on po_edits
  for insert
  with check (
    has_po_access()
    and exists (
      select 1 from purchase_orders po
      join requests r on r.id = po.request_id
      where po.id = po_edits.purchase_order_id and r.tenant_id = get_my_tenant_id()
    )
  );

-- 4. RPC: edit_purchase_order -- the write path for "Procurement Info Edit",
--    audit-logged to po_edits (jsonb diff + required reason).
create or replace function edit_purchase_order(
  p_purchase_order_id uuid,
  p_initial_po_number text default null,
  p_vendor_name text default null,
  p_currency text default null,
  p_delivery_date date default null,
  p_reason text default null
)
returns purchase_orders
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_po purchase_orders%rowtype;
  v_request requests%rowtype;
  v_changes jsonb := '{}'::jsonb;
begin
  if not has_po_access() then
    raise exception 'not authorized to edit purchase order info';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'a reason is required to edit purchase order info';
  end if;

  select po.* into v_po
  from purchase_orders po
  join requests r on r.id = po.request_id
  where po.id = p_purchase_order_id and r.tenant_id = get_my_tenant_id()
  for update of po;

  if not found then
    raise exception 'purchase order not found';
  end if;

  select * into v_request from requests where id = v_po.request_id;

  if p_initial_po_number is not null and p_initial_po_number is distinct from v_po.initial_po_number then
    v_changes := v_changes || jsonb_build_object('initial_po_number', jsonb_build_object('from', v_po.initial_po_number, 'to', p_initial_po_number));
  end if;
  if p_vendor_name is not null and trim(p_vendor_name) <> '' and p_vendor_name is distinct from v_po.vendor_name then
    v_changes := v_changes || jsonb_build_object('vendor_name', jsonb_build_object('from', v_po.vendor_name, 'to', p_vendor_name));
  end if;
  if p_currency is not null and p_currency is distinct from v_po.currency then
    v_changes := v_changes || jsonb_build_object('currency', jsonb_build_object('from', v_po.currency, 'to', p_currency));
  end if;
  if p_delivery_date is not null and p_delivery_date is distinct from v_request.delivery_date then
    v_changes := v_changes || jsonb_build_object('delivery_date', jsonb_build_object('from', v_request.delivery_date, 'to', p_delivery_date));
  end if;

  if v_changes = '{}'::jsonb then
    raise exception 'no changes to save';
  end if;

  update purchase_orders
  set
    initial_po_number = coalesce(p_initial_po_number, initial_po_number),
    vendor_name = case when p_vendor_name is not null and trim(p_vendor_name) <> '' then p_vendor_name else vendor_name end,
    currency = coalesce(p_currency, currency)
  where id = p_purchase_order_id
  returning * into v_po;

  if p_delivery_date is not null then
    update requests set delivery_date = p_delivery_date, updated_at = now() where id = v_po.request_id;
  end if;

  insert into po_edits (purchase_order_id, edited_by, reason, changes)
  values (p_purchase_order_id, auth.uid(), trim(p_reason), v_changes);

  return v_po;
end;
$$;

-- 5. Reporting view for Request Tracking. security_invoker so RLS is
--    evaluated for the querying user, not the view owner.
create or replace view request_tracking_view
with (security_invoker = true)
as
select
  r.id as request_id,
  r.mr_number,
  r.created_at as mr_date,
  r.item_description as mr_title,
  r.subcontractor,
  r.status,
  r.delivery_date,
  r.organization_id,
  org.company_code,
  org.site_name,
  r.requester_id,
  ru.name as mr_originator,
  li.cost_code,
  li.place_of_use,
  ws.name as pending_authority,
  po.id as purchase_order_id,
  po.po_number,
  po.initial_po_number,
  po.vendor_name as company,
  po.amount as po_total,
  po.currency,
  po.generated_by as po_requester_id,
  gu.name as po_requester_name,
  po.generated_at as po_date,
  po.delivered_at,
  po.completed_at as closing_date
from requests r
left join organizations org on org.id = r.organization_id
left join app_users ru on ru.id = r.requester_id
left join lateral (
  select cost_code, place_of_use
  from request_line_items
  where request_id = r.id
  order by created_at
  limit 1
) li on true
left join workflow_stages ws on ws.id = r.current_stage_id
left join purchase_orders po on po.request_id = r.id
left join app_users gu on gu.id = po.generated_by;

grant select on request_tracking_view to authenticated;
