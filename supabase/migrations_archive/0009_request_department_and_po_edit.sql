-- Migration: request_department_and_po_edit
-- Depends on: 20260801120200_write_path_policies_and_functions
--
-- Fixes two frontend-blocking issues found during the frontend review:
--   2. requests.department_id is NOT NULL but nothing ever set it --
--      every request insert would fail. Fixed by deriving it from the
--      requester's own app_users.department_id, same pattern already
--      used for tenant_id.
--   4. The Finance "Edit purchase order" screen tries to change
--      vendor_name/amount directly, which protect_po_immutable_fields
--      (added in the previous migration) correctly blocks. Adds a
--      proper edit_purchase_order() RPC that logs the diff to
--      po_edits and then performs the update through a narrow,
--      explicitly-flagged escape hatch in the trigger -- so direct
--      client updates to those fields are still blocked, but this one
--      legitimate path works.

-- ---------------------------------------------------------------------
-- 2. Derive department_id on request creation
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_request_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_initial_stage_id uuid;
  v_department_id     uuid;
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  SELECT department_id INTO v_department_id
  FROM app_users
  WHERE id = auth.uid();

  IF v_department_id IS NULL THEN
    RAISE EXCEPTION 'your account has no department assigned -- ask an admin to set one before submitting a request';
  END IF;

  NEW.department_id := v_department_id;

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
-- (trigger trg_set_request_defaults already points at this function --
--  no need to recreate it, CREATE OR REPLACE above is enough)

-- ---------------------------------------------------------------------
-- 4. Proper PO edit path
-- ---------------------------------------------------------------------

-- Tighten the immutability trigger to allow a narrow, explicitly-flagged
-- escape hatch for edit_purchase_order() below, while still blocking
-- any direct client-side update to these fields.
CREATE OR REPLACE FUNCTION public.protect_po_immutable_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('vestateck.allow_po_financial_edit', true) = 'on' THEN
    RETURN NEW;
  END IF;

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

CREATE OR REPLACE FUNCTION public.edit_purchase_order(
  p_purchase_order_id uuid,
  p_vendor_name text,
  p_amount numeric,
  p_reason text
)
RETURNS public.po_edits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_po      purchase_orders%ROWTYPE;
  v_changes jsonb := '{}'::jsonb;
  v_edit    po_edits%ROWTYPE;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a reason is required for every PO edit';
  END IF;
  IF p_vendor_name IS NULL OR btrim(p_vendor_name) = '' THEN
    RAISE EXCEPTION 'vendor name cannot be empty';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than zero';
  END IF;

  SELECT po.* INTO v_po
  FROM purchase_orders po
  JOIN requests r ON r.id = po.request_id
  WHERE po.id = p_purchase_order_id
    AND r.tenant_id = get_my_tenant_id()
  FOR UPDATE OF po;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'purchase order not found';
  END IF;
  IF NOT has_po_access() THEN
    RAISE EXCEPTION 'not authorized to edit purchase orders';
  END IF;

  IF p_vendor_name IS DISTINCT FROM v_po.vendor_name THEN
    v_changes := v_changes || jsonb_build_object(
      'vendor_name', jsonb_build_object('old', v_po.vendor_name, 'new', p_vendor_name)
    );
  END IF;
  IF p_amount IS DISTINCT FROM v_po.amount THEN
    v_changes := v_changes || jsonb_build_object(
      'amount', jsonb_build_object('old', v_po.amount, 'new', p_amount)
    );
  END IF;

  IF v_changes = '{}'::jsonb THEN
    RAISE EXCEPTION 'nothing has changed -- update the vendor name or amount, or cancel';
  END IF;

  INSERT INTO po_edits (purchase_order_id, edited_by, reason, changes)
  VALUES (p_purchase_order_id, auth.uid(), p_reason, v_changes)
  RETURNING * INTO v_edit;

  -- Open the narrow escape hatch just for this statement, then update.
  PERFORM set_config('vestateck.allow_po_financial_edit', 'on', true);
  UPDATE purchase_orders
  SET vendor_name = p_vendor_name, amount = p_amount
  WHERE id = p_purchase_order_id;
  PERFORM set_config('vestateck.allow_po_financial_edit', 'off', true);

  RETURN v_edit;
END;
$$;

REVOKE ALL ON FUNCTION public.edit_purchase_order(uuid, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edit_purchase_order(uuid, text, numeric, text) TO authenticated;