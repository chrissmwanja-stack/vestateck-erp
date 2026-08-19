CREATE OR REPLACE FUNCTION public.can_manage_po_handoff(p_purchase_order_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request_id uuid;
  v_selected_offer_submitter uuid;
BEGIN
  SELECT request_id INTO v_request_id
  FROM purchase_orders
  WHERE id = p_purchase_order_id;

  IF v_request_id IS NULL THEN
    RETURN false;
  END IF;

  -- 1. Offer submitter (procurement) -- the winning offer now, not
  --    whichever was entered last (there can be several competing
  --    quotes on a request).
  SELECT submitted_by INTO v_selected_offer_submitter
  FROM request_offers
  WHERE request_id = v_request_id AND is_selected
  LIMIT 1;

  IF v_selected_offer_submitter = auth.uid() THEN
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
