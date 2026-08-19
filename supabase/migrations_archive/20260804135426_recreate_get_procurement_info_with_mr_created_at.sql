CREATE FUNCTION public.get_procurement_info(p_organization_id uuid DEFAULT NULL::uuid, p_initial_po_number text DEFAULT NULL::text, p_company text DEFAULT NULL::text, p_purchaser text DEFAULT NULL::text, p_mr_number text DEFAULT NULL::text, p_po_number text DEFAULT NULL::text, p_po_status text DEFAULT NULL::text)
 RETURNS TABLE(request_id uuid, purchase_order_id uuid, initial_po_number text, po_number text, po_total numeric, currency text, company text, requester_name text, mr_originator_name text, mr_title text, mr_number text, mr_created_at timestamp with time zone, po_date date, delivery_date date, shared_with_supplier boolean, delivered_at timestamp with time zone, completed_at timestamp with time zone, po_status text, pdf_storage_path text, pdf_generated_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    r.created_at as mr_created_at,
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
    end as po_status,
    po.pdf_storage_path,
    po.pdf_generated_at
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
$function$;
