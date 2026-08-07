-- Drop the duplicate edit_purchase_order overload I added in the previous
-- migration -- there was already an edit_purchase_order(vendor_name,
-- amount, reason) RPC with its own validation and an escape hatch around
-- trg_protect_po_immutable_fields. A second overload with a different
-- parameter list risked either PostgREST ambiguity or (since my version's
-- UPDATE never opened the escape hatch) a hard failure on any vendor_name
-- change. Consolidating onto the one canonical function instead.
drop function if exists public.edit_purchase_order(uuid, text, text, text, date, text);

create or replace function public.edit_purchase_order(
  p_purchase_order_id uuid,
  p_vendor_name text,
  p_amount numeric,
  p_reason text,
  p_initial_po_number text default null,
  p_currency text default null,
  p_delivery_date date default null
)
returns po_edits
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_po      purchase_orders%rowtype;
  v_request requests%rowtype;
  v_changes jsonb := '{}'::jsonb;
  v_edit    po_edits%rowtype;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required for every PO edit';
  end if;
  if p_vendor_name is null or btrim(p_vendor_name) = '' then
    raise exception 'vendor name cannot be empty';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be greater than zero';
  end if;

  select po.* into v_po
  from purchase_orders po
  join requests r on r.id = po.request_id
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id()
  for update of po;

  if not found then
    raise exception 'purchase order not found';
  end if;
  if not has_po_access() then
    raise exception 'not authorized to edit purchase orders';
  end if;

  select * into v_request from requests where id = v_po.request_id;

  if p_vendor_name is distinct from v_po.vendor_name then
    v_changes := v_changes || jsonb_build_object(
      'vendor_name', jsonb_build_object('old', v_po.vendor_name, 'new', p_vendor_name)
    );
  end if;
  if p_amount is distinct from v_po.amount then
    v_changes := v_changes || jsonb_build_object(
      'amount', jsonb_build_object('old', v_po.amount, 'new', p_amount)
    );
  end if;
  if p_initial_po_number is not null and p_initial_po_number is distinct from v_po.initial_po_number then
    v_changes := v_changes || jsonb_build_object(
      'initial_po_number', jsonb_build_object('old', v_po.initial_po_number, 'new', p_initial_po_number)
    );
  end if;
  if p_currency is not null and p_currency is distinct from v_po.currency then
    v_changes := v_changes || jsonb_build_object(
      'currency', jsonb_build_object('old', v_po.currency, 'new', p_currency)
    );
  end if;
  if p_delivery_date is not null and p_delivery_date is distinct from v_request.delivery_date then
    v_changes := v_changes || jsonb_build_object(
      'delivery_date', jsonb_build_object('old', v_request.delivery_date, 'new', p_delivery_date)
    );
  end if;

  if v_changes = '{}'::jsonb then
    raise exception 'nothing has changed -- update a field, or cancel';
  end if;

  insert into po_edits (purchase_order_id, edited_by, reason, changes)
  values (p_purchase_order_id, auth.uid(), p_reason, v_changes)
  returning * into v_edit;

  -- Open the narrow escape hatch just for this statement, then update.
  perform set_config('vestateck.allow_po_financial_edit', 'on', true);
  update purchase_orders
  set
    vendor_name = p_vendor_name,
    amount = p_amount,
    initial_po_number = coalesce(p_initial_po_number, initial_po_number),
    currency = coalesce(p_currency, currency)
  where id = p_purchase_order_id;
  perform set_config('vestateck.allow_po_financial_edit', 'off', true);

  if p_delivery_date is not null then
    update requests set delivery_date = p_delivery_date, updated_at = now() where id = v_po.request_id;
  end if;

  return v_edit;
end;
$$;

-- The po_edits insert policy I added is redundant (this function runs
-- SECURITY DEFINER and already bypasses RLS like every other PO/material
-- RPC in this schema) but harmless, so leaving it in place.

-- Extend the existing get_my_purchase_orders() search backing with the
-- fields Procurement Info Edit's search grid needs (organization, MR #,
-- initial PO #, currency, delivery date, handoff flags for status).
-- Return type is changing (new columns), so this must be a drop + recreate.
drop function if exists public.get_my_purchase_orders();

create or replace function public.get_my_purchase_orders()
returns table(
  id uuid,
  request_id uuid,
  po_number text,
  initial_po_number text,
  vendor_name text,
  amount numeric,
  currency text,
  generated_by jsonb,
  generated_at timestamptz,
  delivery_date date,
  shared_with_supplier boolean,
  delivered_at timestamptz,
  completed_at timestamptz,
  request jsonb,
  requester jsonb,
  department jsonb,
  cost_center jsonb,
  organization jsonb,
  mr_number text,
  edit_count int,
  last_edited_at timestamptz,
  last_edited_by jsonb
)
language sql
security definer
set search_path to 'public'
as $$
  with last_edit as (
    select
      pe.purchase_order_id,
      pe.edited_at,
      pe.edited_by,
      row_number() over (partition by pe.purchase_order_id order by pe.edited_at desc) as rn
    from po_edits pe
  ),
  edit_counts as (
    select purchase_order_id, count(*) as cnt
    from po_edits
    group by purchase_order_id
  )
  select
    po.id, po.request_id, po.po_number, po.initial_po_number, po.vendor_name, po.amount, po.currency,
    jsonb_build_object('id', gen.id, 'name', gen.name) as generated_by,
    po.generated_at,
    r.delivery_date,
    coalesce(po.shared_with_supplier, false) as shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    jsonb_build_object('id', r.id, 'item_description', r.item_description, 'quantity', r.quantity, 'status', r.status) as request,
    jsonb_build_object('id', req.id, 'name', req.name) as requester,
    jsonb_build_object('id', dept.id, 'name', dept.name) as department,
    jsonb_build_object('id', cc.id, 'name', cc.name, 'project_code', cc.project_code) as cost_center,
    case when org.id is not null
      then jsonb_build_object('id', org.id, 'company_code', org.company_code, 'site_name', org.site_name)
      else null
    end as organization,
    r.mr_number,
    coalesce(ec.cnt, 0)::int as edit_count,
    le.edited_at as last_edited_at,
    case when le.edited_by is not null
      then jsonb_build_object('id', editor.id, 'name', editor.name)
      else null
    end as last_edited_by
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users req on req.id = r.requester_id
  join departments dept on dept.id = r.department_id
  join cost_centers cc on cc.id = r.cost_center_id
  join app_users gen on gen.id = po.generated_by
  left join organizations org on org.id = r.organization_id
  left join last_edit le on le.purchase_order_id = po.id and le.rn = 1
  left join app_users editor on editor.id = le.edited_by
  left join edit_counts ec on ec.purchase_order_id = po.id
  where has_po_access()
    and r.tenant_id = get_my_tenant_id()
  order by po.generated_at desc;
$$;

grant execute on function public.get_my_purchase_orders() to authenticated;
grant execute on function public.edit_purchase_order(uuid, text, numeric, text, text, text, date) to authenticated;

-- Match this tenant's v_* reporting view naming convention
-- (v_vendor_evaluation, v_trial_balance, etc.)
alter view if exists request_tracking_view rename to v_request_tracking;
grant select on v_request_tracking to authenticated;
