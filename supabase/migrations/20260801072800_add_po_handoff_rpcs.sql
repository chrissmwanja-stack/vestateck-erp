-- Reconciles the "share with supplier" / "confirm delivered" actions
-- (flowchart steps 12-13) with the actual set of people who can see
-- them: get_my_procurement_orders() scopes visibility to the offer
-- submitter, but purchase_orders_update_handoff (the RLS policy the
-- ProcurementTrack.tsx client-side .update() calls relied on) only
-- grants access via has_po_access() (Finance/terminal-stage). That
-- mismatch meant a real procurement user could see the PO but not
-- act on it. These RPCs replicate the share-po edge function's
-- three-way authorization (offer submitter, any approval-trail
-- participant, or Finance) as SECURITY DEFINER functions, matching
-- the pattern the rest of this workflow already uses
-- (record_approval_decision, edit_purchase_order, etc).

CREATE OR REPLACE FUNCTION public.can_manage_po_handoff(p_purchase_order_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_request_id uuid;
  v_latest_offer_submitter uuid;
BEGIN
  SELECT request_id INTO v_request_id
  FROM purchase_orders
  WHERE id = p_purchase_order_id;

  IF v_request_id IS NULL THEN
    RETURN false;
  END IF;

  -- 1. Offer submitter (procurement) -- only the *latest* offer counts,
  --    same as share-po's original logic.
  SELECT submitted_by INTO v_latest_offer_submitter
  FROM request_offers
  WHERE request_id = v_request_id
  ORDER BY submitted_at DESC
  LIMIT 1;

  IF v_latest_offer_submitter = auth.uid() THEN
    RETURN true;
  END IF;

  -- 2. Anyone in the approval trail for this request.
  IF EXISTS (
    SELECT 1 FROM approval_actions
    WHERE request_id = v_request_id AND approver_id = auth.uid()
  ) THEN
    RETURN true;
  END IF;

  -- 3. Finance / terminal-stage access.
  RETURN has_po_access();
END;
$function$;

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
  WHERE request_id = v_po.request_id
  ORDER BY submitted_at DESC
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

CREATE OR REPLACE FUNCTION public.confirm_po_delivered(p_purchase_order_id uuid)
RETURNS purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_po purchase_orders%ROWTYPE;
  v_request requests%ROWTYPE;
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
    RAISE EXCEPTION 'not authorized to confirm delivery for this purchase order';
  END IF;

  IF NOT v_po.shared_with_supplier THEN
    RAISE EXCEPTION 'cannot confirm delivery before the PO has been shared with the supplier';
  END IF;

  IF v_po.delivered_at IS NOT NULL THEN
    RETURN v_po;
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_po.request_id;

  UPDATE purchase_orders
  SET delivered_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_po;

  INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
  VALUES (
    v_request.tenant_id,
    v_request.requester_id,
    'po_delivered',
    'Order delivered',
    format('PO %s (%s) has been marked as delivered.', v_po.po_number, v_po.vendor_name),
    v_request.id,
    v_po.id
  );

  RETURN v_po;
END;
$function$;
