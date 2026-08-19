CREATE OR REPLACE FUNCTION public.get_request_tracking(
  p_organization_id uuid DEFAULT NULL::uuid,
  p_mr_number text DEFAULT NULL::text,
  p_po_number text DEFAULT NULL::text,
  p_company text DEFAULT NULL::text,
  p_description text DEFAULT NULL::text,
  p_subcontractor text DEFAULT NULL::text,
  p_mr_originator text DEFAULT NULL::text,
  p_pending_authority text DEFAULT NULL::text,
  p_status text DEFAULT NULL::text,
  p_cost_code text DEFAULT NULL::text,
  p_place_of_use text DEFAULT NULL::text,
  p_mr_date_from date DEFAULT NULL::date,
  p_mr_date_to date DEFAULT NULL::date,
  p_po_date_from date DEFAULT NULL::date,
  p_po_date_to date DEFAULT NULL::date,
  p_delivery_date_from date DEFAULT NULL::date,
  p_delivery_date_to date DEFAULT NULL::date,
  p_market_offer_date_from date DEFAULT NULL::date,
  p_market_offer_date_to date DEFAULT NULL::date,
  p_closing_date_from date DEFAULT NULL::date,
  p_closing_date_to date DEFAULT NULL::date
)
 RETURNS TABLE(request_id uuid, purchase_order_id uuid, mr_number text, mr_date date, mr_title text, subcontractor text, requester_name text, order_placer_name text, initial_po_number text, po_number text, po_date date, delivery_date date, market_offer_date date, company text, po_total numeric, currency text, closing_date date, status text, lifecycle_status text, pending_authority text, cost_code text, place_of_use text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
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
      case
        when r.status = 'rejected' then 'rejected'
        when r.status = 'cancelled' then 'cancelled'
        when po.completed_at is not null then 'closed_order'
        when po.id is not null then 'open_order'
        when ro.id is not null then 'pending_po'
        when ws.requires_offer_entry then 'pending_bid_entry'
        else 'pending_mr'
      end as lifecycle_status,
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
  )
  select *
  from base
  where (p_mr_number is null or mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po_number ilike '%' || p_po_number || '%')
    and (p_company is null or company ilike '%' || p_company || '%')
    and (p_description is null or mr_title ilike '%' || p_description || '%')
    and (p_subcontractor is null or subcontractor ilike '%' || p_subcontractor || '%')
    and (p_mr_originator is null or requester_name ilike '%' || p_mr_originator || '%')
    and (p_pending_authority is null or pending_authority ilike '%' || p_pending_authority || '%')
    and (p_cost_code is null or cost_code ilike '%' || p_cost_code || '%')
    and (p_place_of_use is null or place_of_use ilike '%' || p_place_of_use || '%')
    and (p_mr_date_from is null or mr_date >= p_mr_date_from)
    and (p_mr_date_to is null or mr_date <= p_mr_date_to)
    and (p_po_date_from is null or po_date >= p_po_date_from)
    and (p_po_date_to is null or po_date <= p_po_date_to)
    and (p_delivery_date_from is null or delivery_date >= p_delivery_date_from)
    and (p_delivery_date_to is null or delivery_date <= p_delivery_date_to)
    and (p_market_offer_date_from is null or market_offer_date >= p_market_offer_date_from)
    and (p_market_offer_date_to is null or market_offer_date <= p_market_offer_date_to)
    and (p_closing_date_from is null or closing_date >= p_closing_date_from)
    and (p_closing_date_to is null or closing_date <= p_closing_date_to)
    and (
      p_status is null or p_status = 'All' or
      (p_status = 'pending_all' and lifecycle_status in ('pending_mr', 'pending_bid_entry', 'pending_po')) or
      (p_status <> 'pending_all' and lifecycle_status = p_status)
    )
  order by mr_date desc;
$function$
;
