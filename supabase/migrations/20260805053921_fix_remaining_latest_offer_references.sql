-- share_purchase_order notifies the offer submitter once the PO is
-- shared with the supplier -- should be the winning bidder, not
-- whichever quote happened to be entered last.
CREATE OR REPLACE FUNCTION public.share_purchase_order(p_purchase_order_id uuid)
 RETURNS purchase_orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_po purchase_orders%ROWTYPE;
  v_request requests%ROWTYPE;
  v_offer_submitter uuid;
BEGIN
  SELECT po.* INTO v_po
  FROM purchase_orders po
  JOIN requests r ON r.id = po.request_id
  WHERE po.id = p_purchase_order_id
    AND r.tenant_id = get_my_tenant_id()
  FOR UPDATE OF po;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'purchase order not found';
  END IF;

  IF NOT can_manage_po_handoff(p_purchase_order_id) THEN
    RAISE EXCEPTION 'not authorized to share this purchase order';
  END IF;

  IF v_po.shared_with_supplier THEN
    RETURN v_po;
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_po.request_id;

  UPDATE purchase_orders
  SET shared_with_supplier = true
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_po;

  SELECT submitted_by INTO v_offer_submitter
  FROM request_offers
  WHERE request_id = v_po.request_id AND is_selected
  LIMIT 1;

  IF v_offer_submitter IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    VALUES (
      v_request.tenant_id,
      v_offer_submitter,
      'po_shared',
      'PO shared with supplier',
      format('PO %s shared with %s. You can proceed.', v_po.po_number, v_po.vendor_name),
      v_request.id,
      v_po.id
    );
  END IF;

  RETURN v_po;
END;
$function$;

-- get_offer_detail similarly surfaced "the latest offer" as if it were
-- the only one; now surfaces the full list plus whichever is selected,
-- consistent with get_my_approval_queue().
CREATE OR REPLACE FUNCTION public.get_offer_detail(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'offers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ro.id,
        'vendor_name', ro.vendor_name,
        'quotation_amount', ro.quotation_amount,
        'quantity', ro.quantity,
        'submitted_at', ro.submitted_at,
        'submitted_by_name', su.name,
        'is_selected', ro.is_selected
      ) order by ro.submitted_at asc), '[]'::jsonb)
      from request_offers ro
      join requests r on r.id = ro.request_id
      left join app_users su on su.id = ro.submitted_by
      where ro.request_id = p_request_id
        and r.tenant_id = get_my_tenant_id()
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
$function$;
