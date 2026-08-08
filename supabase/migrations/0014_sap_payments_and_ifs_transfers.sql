-- 20260801_sap_payments_and_ifs_transfers.sql
--
-- ASSUMPTIONS (verify before applying):
--   1. `departments` table exists with at least (id uuid PK, tenant_id uuid, name text).
--   2. `app_users` has a `tenant_id` column keyed by `id = auth.uid()`
--      (matches the pattern referenced in set_request_defaults()).
--   3. `has_po_access()` already exists (used by cost_centers_insert_finance /
--      cost_centers_update_finance in the earlier migration).

-- ============================================================
-- 1. sap_payments — partial/staged payments against a purchase_order
-- ============================================================

CREATE TABLE IF NOT EXISTS sap_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  purchase_order_id uuid NOT NULL REFERENCES purchase_orders(id),
  amount numeric NOT NULL CHECK (amount > 0),
  status text NOT NULL DEFAULT 'pending_sap'
    CHECK (status IN ('pending_sap', 'sent_to_sap', 'paid', 'rejected')),
  sap_reference text,
  recorded_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sap_payments_po ON sap_payments(purchase_order_id);
CREATE INDEX IF NOT EXISTS idx_sap_payments_tenant ON sap_payments(tenant_id);

ALTER TABLE sap_payments ENABLE ROW LEVEL SECURITY;

-- Force tenant_id from the parent PO server-side, never trust a client
-- value — same rationale as set_request_defaults()/
-- set_invoice_request_defaults().
CREATE OR REPLACE FUNCTION set_sap_payment_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  SELECT tenant_id INTO NEW.tenant_id
  FROM purchase_orders
  WHERE id = NEW.purchase_order_id;

  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'purchase_order_id % not found or has no tenant_id', NEW.purchase_order_id;
  END IF;

  NEW.recorded_by := auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_sap_payment_defaults ON sap_payments;
CREATE TRIGGER trg_set_sap_payment_defaults
  BEFORE INSERT ON sap_payments
  FOR EACH ROW
  EXECUTE FUNCTION set_sap_payment_defaults();

CREATE POLICY sap_payments_select_tenant ON sap_payments
  FOR SELECT
  USING (tenant_id = (SELECT tenant_id FROM app_users WHERE id = auth.uid()));

-- Stopgap, matching cost_centers_insert_finance / cost_centers_update_finance:
-- gated on has_po_access() until a real roles table exists (same flag as
-- the original audit raised for cost_centers).
CREATE POLICY sap_payments_insert_finance ON sap_payments
  FOR INSERT
  WITH CHECK (has_po_access());

-- No UPDATE/DELETE policy: payment records are append-only, matching the
-- requests/invoice_requests pattern (no client UPDATE policy). A correction
-- (e.g. a rejected/reversed payment) is a new row, not an edit of history.

-- ============================================================
-- 2. ifs_transfers — status-only for now, no approval chain
--    (per decision: add an approval chain later if needed, mirroring
--    record_invoice_approval_decision()/get_my_invoice_approval_queue()
--    if/when that becomes a requirement)
-- ============================================================

CREATE TABLE IF NOT EXISTS ifs_transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  transfer_ref text NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0),
  from_department_id uuid NOT NULL REFERENCES departments(id),
  to_department_id uuid NOT NULL REFERENCES departments(id),
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'completed', 'cancelled')),
  requester_id uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ifs_transfers_distinct_departments CHECK (to_department_id <> from_department_id)
);

CREATE INDEX IF NOT EXISTS idx_ifs_transfers_tenant ON ifs_transfers(tenant_id);

ALTER TABLE ifs_transfers ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION set_ifs_transfer_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  SELECT tenant_id INTO NEW.tenant_id
  FROM app_users
  WHERE id = auth.uid();

  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'Could not resolve tenant_id for current user';
  END IF;

  NEW.requester_id := auth.uid();
  NEW.status := 'submitted';
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_ifs_transfer_defaults ON ifs_transfers;
CREATE TRIGGER trg_set_ifs_transfer_defaults
  BEFORE INSERT ON ifs_transfers
  FOR EACH ROW
  EXECUTE FUNCTION set_ifs_transfer_defaults();

CREATE POLICY ifs_transfers_select_own_tenant ON ifs_transfers
  FOR SELECT
  USING (tenant_id = (SELECT tenant_id FROM app_users WHERE id = auth.uid()));

CREATE POLICY ifs_transfers_insert_own ON ifs_transfers
  FOR INSERT
  WITH CHECK (true); -- tenant_id/requester_id/status forced by trigger above

-- No UPDATE policy yet — status only ever moves via a future RPC once/if
-- an approval or completion workflow is added. Direct client updates to
-- status would bypass any audit trail the same way the original flat
-- .update({status}) on invoice_requests did.