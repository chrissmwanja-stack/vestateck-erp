-- Migration: write_path_policies_and_functions
-- Depends on: 20260801120000_add_workflow_stage_active_flag
--
-- Adds the missing write paths for the ERP approval flow:
--   1. Request creation (RLS + trigger)
--   2. Offer submission (RLS + trigger: auto-advances the stage to the
--      Budget Controller and notifies its approvers/delegates)
--   3. Approval decisions (single RPC: records the decision, applies
--      the threshold branch, generates the PO at the right point,
--      closes the request at Finance sign-off, and notifies the
--      requester and/or the next stage's approvers/delegates)
--   4. PO handoff to supplier (RLS, restricted to non-financial fields)
--
-- Underlying tables keep NO general-purpose INSERT/UPDATE policy for
-- requests / request_offers / approval_actions / purchase_orders --
-- everything mutating those goes through the policies/functions below,
-- so there is exactly one path for each state transition.

-- ---------------------------------------------------------------------
-- 0. Supporting sequence for PO numbers
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS public.po_number_seq;

-- ---------------------------------------------------------------------
-- 1. Create request
-- ---------------------------------------------------------------------

-- Forces tenant_id / requester_id / status / starting stage server-side.
-- A client can send whatever it wants in these columns; this trigger
-- overwrites them before the row is checked against RLS.
CREATE OR REPLACE FUNCTION public.set_request_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_initial_stage_id uuid;
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  SELECT id INTO v_initial_stage_id
  FROM workflow_stages
  WHERE tenant_id = NEW.tenant_id AND is_active
  ORDER BY sequence_order ASC
  LIMIT 1;

  IF v_initial_stage_id IS NULL THEN
    RAISE EXCEPTION 'no active workflow stages configured for this tenant';
  END IF;

  NEW.current_stage_id := v_initial_stage_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_request_defaults ON public.requests;
CREATE TRIGGER trg_set_request_defaults
BEFORE INSERT ON public.requests
FOR EACH ROW
EXECUTE FUNCTION public.set_request_defaults();

CREATE POLICY requests_insert_own
ON public.requests
FOR INSERT
WITH CHECK (
  requester_id = auth.uid()
  AND tenant_id = get_my_tenant_id()
);

-- ---------------------------------------------------------------------
-- 2. Submit offer
-- ---------------------------------------------------------------------

-- Only whoever is assigned (directly or via active delegation) to the
-- request's current stage, and only while that stage requires an offer,
-- can submit one.
CREATE POLICY request_offers_insert_authorized
ON public.request_offers
FOR INSERT
WITH CHECK (
  submitted_by = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM requests r
    JOIN workflow_stages ws ON ws.id = r.current_stage_id
    WHERE r.id = request_offers.request_id
      AND r.tenant_id = get_my_tenant_id()
      AND r.status = 'open'
      AND ws.requires_offer_entry
      AND can_act_on_stage(r.current_stage_id)
  )
);

-- Once the offer lands, auto-advance the request past the offer-entry
-- stage (to the Budget Controller), and notify that stage's approvers
-- and any active delegates covering them. This is a data-entry step,
-- not an approval decision, so it doesn't go through
-- record_approval_decision below.
CREATE OR REPLACE FUNCTION public.advance_after_offer_entry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_request    requests%ROWTYPE;
  v_stage      workflow_stages%ROWTYPE;
  v_next_stage workflow_stages%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM requests WHERE id = NEW.request_id;
  SELECT * INTO v_stage FROM workflow_stages WHERE id = v_request.current_stage_id;

  IF v_stage.requires_offer_entry THEN
    UPDATE requests
    SET current_stage_id = v_stage.next_stage_low_id, updated_at = now()
    WHERE id = NEW.request_id;

    SELECT * INTO v_next_stage FROM workflow_stages WHERE id = v_stage.next_stage_low_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    SELECT DISTINCT
      v_request.tenant_id,
      recipient_id,
      'approval_needed',
      'Offer submitted -- approval needed',
      format('An offer of %s has been entered for request "%s" and is awaiting your approval.',
             NEW.quotation_amount, v_request.item_description),
      NEW.request_id
    FROM (
      SELECT aa.user_id AS recipient_id
      FROM approval_assignments aa
      WHERE aa.workflow_stage_id = v_stage.next_stage_low_id

      UNION

      SELECT d.delegate_user_id AS recipient_id
      FROM approval_delegations d
      JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
      WHERE d.status = 'active'
        AND now() BETWEEN d.starts_at AND d.ends_at
        AND aa.workflow_stage_id = v_stage.next_stage_low_id
        AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = v_stage.next_stage_low_id)
    ) recipients;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_advance_after_offer_entry ON public.request_offers;
CREATE TRIGGER trg_advance_after_offer_entry
AFTER INSERT ON public.request_offers
FOR EACH ROW
EXECUTE FUNCTION public.advance_after_offer_entry();

-- ---------------------------------------------------------------------
-- 3. Approval decision (approve/reject) -- the core workflow engine
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_approval_decision(
  p_request_id uuid,
  p_decision text,
  p_comment text DEFAULT NULL,
  p_acting_on_behalf_of uuid DEFAULT NULL
)
RETURNS TABLE (
  out_request_id uuid,
  out_status text,
  out_stage_id uuid,
  out_purchase_order_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_request       requests%ROWTYPE;
  v_stage         workflow_stages%ROWTYPE;
  v_next_stage    workflow_stages%ROWTYPE;
  v_next_stage_id uuid;
  v_offer         request_offers%ROWTYPE;
  v_po_id         uuid;
  v_po_number     text;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid decision: %', p_decision;
  END IF;

  -- Lock the request so two approvers can't act on it concurrently.
  SELECT * INTO v_request FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'request not found';
  END IF;
  IF v_request.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this request';
  END IF;
  IF v_request.status != 'open' THEN
    RAISE EXCEPTION 'request is not open (status: %)', v_request.status;
  END IF;
  IF v_request.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'request has no current stage';
  END IF;
  IF NOT can_act_on_stage(v_request.current_stage_id) THEN
    RAISE EXCEPTION 'not authorized to act on this stage';
  END IF;

  SELECT * INTO v_stage FROM workflow_stages WHERE id = v_request.current_stage_id;

  -- Always record the decision, regardless of outcome (audit trail).
  INSERT INTO approval_actions
    (request_id, workflow_stage_id, approver_id, acted_on_behalf_of, decision, comment)
  VALUES
    (p_request_id, v_stage.id, auth.uid(), p_acting_on_behalf_of, p_decision, p_comment);

  -- Rejection stops the workflow immediately, at any stage.
  IF p_decision = 'rejected' THEN
    UPDATE requests SET status = 'rejected', updated_at = now() WHERE id = p_request_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    VALUES (
      v_request.tenant_id,
      v_request.requester_id,
      'request_rejected',
      'Request rejected',
      format('Your request "%s" was rejected at the %s stage.', v_request.item_description, v_stage.name),
      p_request_id
    );

    RETURN QUERY SELECT p_request_id, 'rejected'::text, v_stage.id, NULL::uuid;
    RETURN;
  END IF;

  -- Finance's own sign-off closes the request. The PO already exists
  -- from an earlier stage (steps 9/10 in the flow) -- nothing new is
  -- created here.
  IF v_stage.is_finance_terminal_stage THEN
    UPDATE requests
    SET status = 'closed', current_stage_id = NULL, updated_at = now()
    WHERE id = p_request_id;

    SELECT id INTO v_po_id FROM purchase_orders WHERE request_id = p_request_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    VALUES (
      v_request.tenant_id,
      v_request.requester_id,
      'request_closed',
      'Request closed',
      format('Your request "%s" has been closed. The purchase order is ready for procurement.', v_request.item_description),
      p_request_id,
      v_po_id
    );

    RETURN QUERY SELECT p_request_id, 'closed'::text, NULL::uuid, v_po_id;
    RETURN;
  END IF;

  SELECT * INTO v_offer FROM request_offers
  WHERE request_id = p_request_id
  ORDER BY submitted_at DESC LIMIT 1;

  -- Only the Budget Controller stage has a threshold; everywhere else
  -- is a single path (next_stage_low_id).
  IF v_stage.threshold_amount IS NOT NULL THEN
    IF NOT FOUND THEN
      RAISE EXCEPTION 'no offer on file to evaluate threshold';
    END IF;
    IF v_offer.quotation_amount <= v_stage.threshold_amount THEN
      v_next_stage_id := v_stage.next_stage_low_id;   -- <= 5M -> Finance
    ELSE
      v_next_stage_id := v_stage.next_stage_high_id;  -- > 5M -> Project Manager
    END IF;
  ELSE
    v_next_stage_id := v_stage.next_stage_low_id;
  END IF;

  IF v_next_stage_id IS NULL THEN
    RAISE EXCEPTION 'stage % has no next stage configured', v_stage.name;
  END IF;

  SELECT * INTO v_next_stage FROM workflow_stages WHERE id = v_next_stage_id;

  -- Generate the PO the moment either branch is about to enter Finance
  -- (matches steps 8a/8b: PO generated immediately).
  IF v_next_stage.is_finance_terminal_stage THEN
    IF v_offer.id IS NULL THEN
      RAISE EXCEPTION 'no offer on file to generate a purchase order';
    END IF;
    IF EXISTS (SELECT 1 FROM purchase_orders WHERE request_id = p_request_id) THEN
      RAISE EXCEPTION 'a purchase order already exists for this request';
    END IF;

    v_po_number := 'PO-' || to_char(now(), 'YYYY') || '-'
                   || lpad(nextval('public.po_number_seq')::text, 5, '0');

    INSERT INTO purchase_orders (request_id, po_number, vendor_name, amount, generated_by)
    VALUES (p_request_id, v_po_number, v_offer.vendor_name, v_offer.quotation_amount, auth.uid())
    RETURNING id INTO v_po_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    VALUES (
      v_request.tenant_id,
      v_request.requester_id,
      'purchase_order_generated',
      'Purchase order generated',
      format('A purchase order (%s) has been generated for your request "%s".', v_po_number, v_request.item_description),
      p_request_id,
      v_po_id
    );
  END IF;

  UPDATE requests
  SET current_stage_id = v_next_stage_id, updated_at = now()
  WHERE id = p_request_id;

  -- Notify whoever is now responsible for this request: direct
  -- assignees on the new stage, plus anyone actively delegated to
  -- cover them.
  INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
  SELECT DISTINCT
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('Request "%s" is awaiting your approval at the %s stage.', v_request.item_description, v_next_stage.name),
    p_request_id
  FROM (
    SELECT aa.user_id AS recipient_id
    FROM approval_assignments aa
    WHERE aa.workflow_stage_id = v_next_stage_id

    UNION

    SELECT d.delegate_user_id AS recipient_id
    FROM approval_delegations d
    JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
    WHERE d.status = 'active'
      AND now() BETWEEN d.starts_at AND d.ends_at
      AND aa.workflow_stage_id = v_next_stage_id
      AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  RETURN QUERY SELECT p_request_id, 'open'::text, v_next_stage_id, v_po_id;
END;
$$;

-- Lock this down to logged-in users only (matches the security advisor
-- warning from the earlier audit -- don't leave it callable by anon).
REVOKE ALL ON FUNCTION public.record_approval_decision(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_approval_decision(uuid, text, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. Share PO with supplier (steps 11-13)
-- ---------------------------------------------------------------------

-- Protects the financial fields of a PO from being altered through this
-- path. Real edits to amount/vendor belong in po_edits, not here.
CREATE OR REPLACE FUNCTION public.protect_po_immutable_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.po_number   IS DISTINCT FROM OLD.po_number
     OR NEW.vendor_name IS DISTINCT FROM OLD.vendor_name
     OR NEW.amount      IS DISTINCT FROM OLD.amount
     OR NEW.request_id  IS DISTINCT FROM OLD.request_id
     OR NEW.generated_by IS DISTINCT FROM OLD.generated_by
  THEN
    RAISE EXCEPTION 'these fields can only be changed via a logged PO edit, not a direct update';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_po_immutable_fields ON public.purchase_orders;
CREATE TRIGGER trg_protect_po_immutable_fields
BEFORE UPDATE ON public.purchase_orders
FOR EACH ROW
EXECUTE FUNCTION public.protect_po_immutable_fields();

CREATE POLICY purchase_orders_update_handoff
ON public.purchase_orders
FOR UPDATE
USING (
  has_po_access()
  AND EXISTS (
    SELECT 1 FROM requests r
    WHERE r.id = purchase_orders.request_id AND r.tenant_id = get_my_tenant_id()
  )
)
WITH CHECK (
  has_po_access()
  AND EXISTS (
    SELECT 1 FROM requests r
    WHERE r.id = purchase_orders.request_id AND r.tenant_id = get_my_tenant_id()
  )
);