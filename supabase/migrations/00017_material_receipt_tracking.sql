-- Migration: material_receipt_tracking
-- Depends on: 20260801120200_request_department_and_po_edit
--
-- Adds goods-received tracking against closed requests (post-PO), plus
-- a Finance-administered assignment list controlling who may record
-- receipts. Follows existing conventions: append-only audit tables
-- (mirrors po_edits / request_line_items), no direct client writes,
-- everything mutating goes through a SECURITY DEFINER RPC. Gated by
-- is_finance_team_member('finance') -- same authority that already
-- administers Accounts and Cost Codes -- rather than introducing a new
-- tenant-admin concept that doesn't exist elsewhere in the schema.

-- ---------------------------------------------------------------------
-- 1. Who can record receipts
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS material_receipt_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES app_users(id),
  assigned_by uuid NOT NULL REFERENCES app_users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id)
);

ALTER TABLE material_receipt_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY material_receipt_assignments_select ON material_receipt_assignments
  FOR SELECT
  USING (tenant_id = get_my_tenant_id());
-- No insert/update/delete policy -- only the RPCs below write here.

CREATE OR REPLACE FUNCTION public.has_receipt_access()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM material_receipt_assignments
    WHERE user_id = auth.uid() AND tenant_id = get_my_tenant_id()
  );
$$;

CREATE OR REPLACE FUNCTION public.list_receipt_assignees()
RETURNS TABLE (id uuid, user_id uuid, user_name text, assigned_by_name text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = 'public'
AS $$
  SELECT mra.id, mra.user_id, u.name, ab.name, mra.created_at
  FROM material_receipt_assignments mra
  JOIN app_users u ON u.id = mra.user_id
  JOIN app_users ab ON ab.id = mra.assigned_by
  WHERE mra.tenant_id = get_my_tenant_id()
  ORDER BY mra.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.assign_receipt_access(p_user_id uuid)
RETURNS public.material_receipt_assignments
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_row material_receipt_assignments%ROWTYPE;
BEGIN
  IF NOT is_finance_team_member('finance') THEN
    RAISE EXCEPTION 'not authorized to assign material receipt access';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_user_id AND tenant_id = get_my_tenant_id()) THEN
    RAISE EXCEPTION 'user not found in this tenant';
  END IF;

  INSERT INTO material_receipt_assignments (tenant_id, user_id, assigned_by)
  VALUES (get_my_tenant_id(), p_user_id, auth.uid())
  ON CONFLICT (tenant_id, user_id) DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'this user already has material receipt access';
  END IF;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_receipt_access(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
BEGIN
  IF NOT is_finance_team_member('finance') THEN
    RAISE EXCEPTION 'not authorized to revoke material receipt access';
  END IF;

  DELETE FROM material_receipt_assignments
  WHERE tenant_id = get_my_tenant_id() AND user_id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_receipt_access(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_receipt_access(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assign_receipt_access(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_receipt_access(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_receipt_assignees() TO authenticated;

-- ---------------------------------------------------------------------
-- 2. Receipt log -- append-only, mirrors po_edits' audit pattern
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS line_item_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  line_item_id uuid NOT NULL REFERENCES request_line_items(id) ON DELETE CASCADE,
  received_qty numeric NOT NULL CHECK (received_qty > 0),
  received_by uuid NOT NULL REFERENCES app_users(id),
  received_at timestamptz NOT NULL DEFAULT now(),
  note text
);

CREATE INDEX IF NOT EXISTS idx_line_item_receipts_line_item ON line_item_receipts(line_item_id);

ALTER TABLE line_item_receipts ENABLE ROW LEVEL SECURITY;

CREATE POLICY line_item_receipts_select ON line_item_receipts
  FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM request_line_items rli
    JOIN requests r ON r.id = rli.request_id
    WHERE rli.id = line_item_receipts.line_item_id
      AND r.tenant_id = get_my_tenant_id()
  ));
-- No insert/update/delete policy -- only record_line_item_receipt() writes.

CREATE OR REPLACE FUNCTION public.record_line_item_receipt(
  p_line_item_id uuid,
  p_received_qty numeric,
  p_note text DEFAULT NULL
)
RETURNS public.line_item_receipts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_request requests%ROWTYPE;
  v_line    request_line_items%ROWTYPE;
  v_already numeric;
  v_row     line_item_receipts%ROWTYPE;
BEGIN
  IF p_received_qty IS NULL OR p_received_qty <= 0 THEN
    RAISE EXCEPTION 'received quantity must be greater than zero';
  END IF;

  SELECT * INTO v_line FROM request_line_items WHERE id = p_line_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'line item not found';
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_line.request_id;
  IF v_request.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this request';
  END IF;
  IF v_request.status != 'closed' THEN
    RAISE EXCEPTION 'goods can only be received against a closed request (PO already generated)';
  END IF;
  IF NOT has_receipt_access() THEN
    RAISE EXCEPTION 'not authorized to record receipts';
  END IF;

  SELECT COALESCE(SUM(received_qty), 0) INTO v_already
  FROM line_item_receipts WHERE line_item_id = p_line_item_id;

  IF v_already + p_received_qty > v_line.quantity * 2 THEN
    RAISE EXCEPTION 'received quantity (%) is more than double what was ordered (%) -- check for a data entry error',
      v_already + p_received_qty, v_line.quantity;
  END IF;

  INSERT INTO line_item_receipts (line_item_id, received_qty, received_by, note)
  VALUES (p_line_item_id, p_received_qty, auth.uid(), p_note)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.record_line_item_receipt(uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_line_item_receipt(uuid, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. Per-line rollup view for the screen to read from
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.line_item_receipt_status AS
SELECT
  rli.id AS line_item_id,
  rli.request_id,
  rli.material_service,
  rli.quantity AS ordered_qty,
  COALESCE(SUM(lir.received_qty), 0) AS received_qty,
  CASE
    WHEN COALESCE(SUM(lir.received_qty), 0) = 0 THEN 'none'
    WHEN COALESCE(SUM(lir.received_qty), 0) < rli.quantity THEN 'partial'
    WHEN COALESCE(SUM(lir.received_qty), 0) = rli.quantity THEN 'full'
    ELSE 'over'
  END AS receipt_status,
  MAX(lir.received_at) AS last_received_at
FROM request_line_items rli
LEFT JOIN line_item_receipts lir ON lir.line_item_id = rli.id
GROUP BY rli.id, rli.request_id, rli.material_service, rli.quantity;