-- Read-only offer/MR detail lookup for the Request Tracking screen's
-- "Initial PO #" popup. Mirrors get_request_tracking(): tenant-scoped via
-- SECURITY DEFINER + get_my_tenant_id(), NOT gated through
-- request_offers_select_via_request's requester/can_act_on_stage check --
-- that policy is meant for the live approval workflow, not a report
-- viewer paging through historical requests they never actioned, which
-- is exactly the gap that broke the direct .update() calls in
-- ProcurementTrack.tsx before those moved to SECURITY DEFINER RPCs.
create or replace function public.get_offer_detail(p_request_id uuid)
returns jsonb
language sql
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'request', (
      select jsonb_build_object(
        'mr_number', r.mr_number,
        'item_description', r.item_description,
        'requester_name', ru.name,
        'created_at', r.created_at
      )
      from requests r
      join app_users ru on ru.id = r.requester_id
      where r.id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    ),
    'offer', (
      select jsonb_build_object(
        'id', ro.id,
        'vendor_name', ro.vendor_name,
        'quotation_amount', ro.quotation_amount,
        'quantity', ro.quantity,
        'submitted_at', ro.submitted_at,
        'submitted_by_name', su.name
      )
      from request_offers ro
      join requests r on r.id = ro.request_id
      left join app_users su on su.id = ro.submitted_by
      where ro.request_id = p_request_id
        and r.tenant_id = get_my_tenant_id()
      order by ro.submitted_at desc
      limit 1
    ),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', rli.id,
        'material_service', rli.material_service,
        'cost_code', rli.cost_code,
        'group_code', rli.group_code,
        'place_of_use', rli.place_of_use,
        'quantity', rli.quantity,
        'unit_price', rli.unit_price,
        'total', rli.total,
        'currency', rli.currency
      ) order by rli.created_at), '[]'::jsonb)
      from request_line_items rli
      join requests r on r.id = rli.request_id
      where rli.request_id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    )
  );
$$;

grant execute on function public.get_offer_detail(uuid) to authenticated;
