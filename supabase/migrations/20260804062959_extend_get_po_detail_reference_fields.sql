drop function public.get_po_detail(uuid);

create function public.get_po_detail(p_purchase_order_id uuid)
returns table(
  purchase_order_id uuid, request_id uuid, po_number text, initial_po_number text, vendor_name text,
  po_amount numeric, currency text, generated_at timestamp with time zone, generated_by_name text,
  shared_with_supplier boolean, delivered_at timestamp with time zone, completed_at timestamp with time zone,
  mr_number text, mr_title text, mr_date date, requester_name text, delivery_date date,
  project_sap_no text, payment_conditions text, terms_of_delivery text,
  offer_quotation_amount numeric, offer_quantity integer, offer_submitted_by_name text,
  offer_submitted_at timestamp with time zone
)
language sql
security definer
set search_path to 'public'
as $$
  select
    po.id as purchase_order_id,
    po.request_id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name,
    po.amount as po_amount,
    po.currency,
    po.generated_at,
    generator.name as generated_by_name,
    po.shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    r.mr_number,
    r.item_description as mr_title,
    r.created_at::date as mr_date,
    requester.name as requester_name,
    r.delivery_date,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    ro.quotation_amount as offer_quotation_amount,
    ro.quantity as offer_quantity,
    submitter.name as offer_submitted_by_name,
    ro.submitted_at as offer_submitted_at
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  join app_users generator on generator.id = po.generated_by
  left join request_offers ro
    on ro.request_id = po.request_id
    and ro.vendor_name = po.vendor_name
  left join app_users submitter on submitter.id = ro.submitted_by
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id()
  order by ro.submitted_at desc
  limit 1;
$$;

grant execute on function public.get_po_detail(uuid) to authenticated;
