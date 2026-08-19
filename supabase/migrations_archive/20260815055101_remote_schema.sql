drop view if exists "public"."v_request_tracking";

create or replace view "public"."v_request_tracking" as  SELECT r.id AS request_id,
    r.mr_number,
    r.created_at AS mr_date,
    r.item_description AS mr_title,
    r.subcontractor,
    r.status,
    r.delivery_date,
    r.organization_id,
    org.company_code,
    org.site_name,
    r.requester_id,
    ru.name AS mr_originator,
    li.cost_code,
    li.place_of_use,
    ws.name AS pending_authority,
    po.id AS purchase_order_id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name AS company,
    po.amount AS po_total,
    po.currency,
    po.generated_by AS po_requester_id,
    gu.name AS po_requester_name,
    po.generated_at AS po_date,
    po.delivered_at,
    po.completed_at AS closing_date
   FROM ((((((public.requests r
     LEFT JOIN public.organizations org ON ((org.id = r.organization_id)))
     LEFT JOIN public.app_users ru ON ((ru.id = r.requester_id)))
     LEFT JOIN LATERAL ( SELECT request_line_items.cost_code,
            request_line_items.place_of_use
           FROM public.request_line_items
          WHERE (request_line_items.request_id = r.id)
          ORDER BY request_line_items.created_at
         LIMIT 1) li ON (true))
     LEFT JOIN public.workflow_stages ws ON ((ws.id = r.current_stage_id)))
     LEFT JOIN public.purchase_orders po ON ((po.request_id = r.id)))
     LEFT JOIN public.app_users gu ON ((gu.id = po.generated_by)));



