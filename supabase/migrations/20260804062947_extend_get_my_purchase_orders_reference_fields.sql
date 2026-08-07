drop function public.get_my_purchase_orders();

create function public.get_my_purchase_orders()
returns table(
  id uuid, request_id uuid, po_number text, initial_po_number text, vendor_name text,
  amount numeric, currency text, generated_by jsonb, generated_at timestamp with time zone,
  delivery_date date, shared_with_supplier boolean, delivered_at timestamp with time zone,
  completed_at timestamp with time zone, request jsonb, requester jsonb, department jsonb,
  cost_center jsonb, organization jsonb, mr_number text,
  project_sap_no text, payment_conditions text, terms_of_delivery text,
  edit_count integer, last_edited_at timestamp with time zone, last_edited_by jsonb
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
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
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
