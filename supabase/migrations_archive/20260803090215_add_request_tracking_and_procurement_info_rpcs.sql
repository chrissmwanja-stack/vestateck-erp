-- Two read-only reporting RPCs backing the "Request Tracking" and
-- "Procurement Info Edit" screens (per the YM Portal reference).
--
-- Both are SECURITY DEFINER and tenant-scoped via get_my_tenant_id().
-- Visibility: broad (any authenticated user in the tenant), matching how
-- these two leaves sit in ModuleTree today -- unlike /procurement/track
-- (get_my_procurement_orders, scoped to the calling user's own offers)
-- or /finance/purchase-orders (Finance-gated), neither of these two tree
-- nodes is currently role-restricted client-side. If that's wrong,
-- tighten with has_po_access()/is_finance_team_member() the same way the
-- other two RPCs do.

create or replace function get_request_tracking(
  p_organization_id uuid default null,
  p_mr_number text default null,
  p_po_number text default null,
  p_company text default null,          -- vendor_name (PO or offer)
  p_description text default null,
  p_subcontractor text default null,
  p_mr_originator text default null,
  p_pending_authority text default null,
  p_status text default null,
  p_cost_code text default null,
  p_place_of_use text default null,
  p_mr_date_from date default null,
  p_mr_date_to date default null,
  p_po_date_from date default null,
  p_po_date_to date default null,
  p_delivery_date_from date default null,
  p_delivery_date_to date default null,
  p_closing_date_from date default null,
  p_closing_date_to date default null
)
returns table (
  request_id uuid,
  purchase_order_id uuid,
  mr_number text,
  mr_date date,
  mr_title text,
  subcontractor text,
  requester_name text,
  order_placer_name text,
  initial_po_number text,
  po_number text,
  po_date date,
  delivery_date date,
  market_offer_date date,
  company text,
  po_total numeric,
  currency text,
  closing_date date,
  status text,
  pending_authority text,
  cost_code text,
  place_of_use text
)
language sql
security definer
set search_path = public
as $$
  select
    r.id as request_id,
    po.id as purchase_order_id,
    r.mr_number,
    r.created_at::date as mr_date,
    r.item_description as mr_title,
    r.subcontractor,
    requester.name as requester_name,
    submitter.name as order_placer_name,
    po.initial_po_number,
    po.po_number,
    po.generated_at::date as po_date,
    r.delivery_date,
    ro.submitted_at::date as market_offer_date,
    coalesce(po.vendor_name, ro.vendor_name) as company,
    po.amount as po_total,
    po.currency,
    po.completed_at::date as closing_date,
    r.status,
    ws.name as pending_authority,
    rli.cost_code,
    rli.place_of_use
  from requests r
  join app_users requester on requester.id = r.requester_id
  left join organizations o on o.id = r.organization_id
  left join purchase_orders po on po.request_id = r.id
  left join request_offers ro on ro.request_id = r.id
  left join app_users submitter on submitter.id = ro.submitted_by
  left join workflow_stages ws on ws.id = r.current_stage_id
  left join lateral (
    select cost_code, place_of_use
    from request_line_items rli
    where rli.request_id = r.id
    order by rli.created_at
    limit 1
  ) rli on true
  where r.tenant_id = get_my_tenant_id()
    and (p_organization_id is null or r.organization_id = p_organization_id)
    and (p_mr_number is null or r.mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po.po_number ilike '%' || p_po_number || '%')
    and (p_company is null or coalesce(po.vendor_name, ro.vendor_name) ilike '%' || p_company || '%')
    and (p_description is null or r.item_description ilike '%' || p_description || '%')
    and (p_subcontractor is null or r.subcontractor ilike '%' || p_subcontractor || '%')
    and (p_mr_originator is null or requester.name ilike '%' || p_mr_originator || '%')
    and (p_pending_authority is null or ws.name ilike '%' || p_pending_authority || '%')
    and (p_status is null or p_status = 'All' or r.status = p_status)
    and (p_cost_code is null or rli.cost_code ilike '%' || p_cost_code || '%')
    and (p_place_of_use is null or rli.place_of_use ilike '%' || p_place_of_use || '%')
    and (p_mr_date_from is null or r.created_at::date >= p_mr_date_from)
    and (p_mr_date_to is null or r.created_at::date <= p_mr_date_to)
    and (p_po_date_from is null or po.generated_at::date >= p_po_date_from)
    and (p_po_date_to is null or po.generated_at::date <= p_po_date_to)
    and (p_delivery_date_from is null or r.delivery_date >= p_delivery_date_from)
    and (p_delivery_date_to is null or r.delivery_date <= p_delivery_date_to)
    and (p_closing_date_from is null or po.completed_at::date >= p_closing_date_from)
    and (p_closing_date_to is null or po.completed_at::date <= p_closing_date_to)
  order by r.created_at desc;
$$;

comment on function get_request_tracking is
  'Backs the Request Tracking screen (steps: MR -> Procurement -> PO -> Delivery -> Close). Read-only report, tenant-scoped, not role-restricted.';

create or replace function get_procurement_info(
  p_organization_id uuid default null,
  p_initial_po_number text default null,
  p_company text default null,
  p_purchaser text default null,        -- offer submitter / "SatÄ±n AlmacÄ±"
  p_mr_number text default null,
  p_po_number text default null,
  p_po_status text default null         -- 'pending' | 'shared' | 'delivered' | 'completed'
)
returns table (
  request_id uuid,
  purchase_order_id uuid,
  initial_po_number text,
  po_number text,
  po_total numeric,
  currency text,
  company text,
  requester_name text,
  mr_originator_name text,
  mr_title text,
  mr_number text,
  po_date date,
  delivery_date date,
  shared_with_supplier boolean,
  delivered_at timestamptz,
  completed_at timestamptz,
  po_status text
)
language sql
security definer
set search_path = public
as $$
  select
    r.id as request_id,
    po.id as purchase_order_id,
    po.initial_po_number,
    po.po_number,
    po.amount as po_total,
    po.currency,
    po.vendor_name as company,
    requester.name as requester_name,
    purchaser.name as mr_originator_name,
    r.item_description as mr_title,
    r.mr_number,
    po.generated_at::date as po_date,
    r.delivery_date,
    po.shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    case
      when po.completed_at is not null then 'completed'
      when po.delivered_at is not null then 'delivered'
      when po.shared_with_supplier then 'shared'
      else 'pending'
    end as po_status
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join request_offers ro on ro.request_id = r.id
  left join app_users purchaser on purchaser.id = ro.submitted_by
  where r.tenant_id = get_my_tenant_id()
    and (p_organization_id is null or r.organization_id = p_organization_id)
    and (p_initial_po_number is null or po.initial_po_number ilike '%' || p_initial_po_number || '%')
    and (p_company is null or po.vendor_name ilike '%' || p_company || '%')
    and (p_purchaser is null or purchaser.name ilike '%' || p_purchaser || '%')
    and (p_mr_number is null or r.mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po.po_number ilike '%' || p_po_number || '%')
    and (
      p_po_status is null or p_po_status = 'All' or
      (case
        when po.completed_at is not null then 'completed'
        when po.delivered_at is not null then 'delivered'
        when po.shared_with_supplier then 'shared'
        else 'pending'
      end) = p_po_status
    )
  order by po.generated_at desc;
$$;

comment on function get_procurement_info is
  'Backs the Procurement Info Edit screen (PO-centric search). Surfaces existing lifecycle actions (share/deliver/settle) per row; no raw field editing. Tenant-scoped, not role-restricted.';

grant execute on function get_request_tracking to authenticated;
grant execute on function get_procurement_info to authenticated;
