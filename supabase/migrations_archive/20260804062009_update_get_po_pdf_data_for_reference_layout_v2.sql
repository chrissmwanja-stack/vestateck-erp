drop function public.get_po_pdf_data(uuid);

create function public.get_po_pdf_data(p_purchase_order_id uuid)
returns table(
  purchase_order_id uuid,
  po_number text,
  initial_po_number text,
  company text,
  po_total numeric,
  currency text,
  po_date date,
  mr_number text,
  mr_title text,
  requester_name text,
  purchaser_name text,
  delivery_date date,
  organization_name text,
  project_sap_no text,
  payment_conditions text,
  terms_of_delivery text,
  primary_cost_code text,
  line_items jsonb,
  approvals jsonb
)
language sql
security definer
set search_path to 'public'
as $$
  select
    po.id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name,
    po.amount,
    po.currency,
    po.generated_at::date,
    r.mr_number,
    r.item_description,
    requester.name,
    purchaser.name,
    r.delivery_date,
    o.site_name,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    (
      select rli.cost_code
      from request_line_items rli
      where rli.request_id = r.id
      order by rli.created_at
      limit 1
    ),
    coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'material_service', rli.material_service,
          'cost_code', rli.cost_code,
          'place_of_use', rli.place_of_use,
          'quantity', rli.quantity,
          'unit_price', rli.unit_price,
          'total', rli.total,
          'currency', rli.currency
        ) order by rli.created_at)
        from request_line_items rli
        where rli.request_id = r.id
      ),
      '[]'::jsonb
    ),
    coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'stage_name', ws.name,
          'approver_role', ws.approver_role,
          'approver_name', au.name,
          'sequence_order', ws.sequence_order,
          'acted_at', aa.acted_at
        ) order by ws.sequence_order, aa.acted_at)
        from approval_actions aa
        join workflow_stages ws on ws.id = aa.workflow_stage_id
        join app_users au on au.id = aa.approver_id
        where aa.request_id = r.id
          and aa.decision = 'approved'
          and aa.acted_at = (
            select max(aa2.acted_at)
            from approval_actions aa2
            where aa2.request_id = aa.request_id
              and aa2.workflow_stage_id = aa.workflow_stage_id
              and aa2.decision = 'approved'
          )
      ),
      '[]'::jsonb
    )
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join organizations o on o.id = r.organization_id
  left join request_offers ro on ro.request_id = r.id
  left join app_users purchaser on purchaser.id = ro.submitted_by
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id();
$$;

grant execute on function public.get_po_pdf_data(uuid) to authenticated;
