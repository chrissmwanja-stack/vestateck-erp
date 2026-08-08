-- Migration: stock_ledger_and_goods_movements
--
-- Three things:
--   1. Extends line_item_receipts (inbound, already exists) with the
--      warehouse/voucher/approval fields the paper receipt process needs.
--   2. Adds goods_issues / goods_issue_items (outbound) -- this is the
--      digitized version of YMI.GNL.AMB.FRM.002 (Ambar Çıkış Formu /
--      Goods Issue Form): project, warehouse, voucher no, line items with
--      SAP material no / cost center / description / unit / request
--      /delivery/remaining quantities, and the three-signature block
--      (Warehouse Officer / Received By / Approved).
--   3. A single stock_movements ledger fed by both sides (receipts = in,
--      issues = out), rolling up into a maintained stock_balances table
--      per the "running total, not computed live" decision -- kept
--      current by a trigger on every movement insert rather than
--      recomputed on read.
--
-- Access to record either side of the ledger reuses has_receipt_access()
-- (material_receipt_assignments), rather than inventing a second
-- "warehouse role" concept -- the same person who confirms inbound
-- receipts is the warehouse manager who issues stock out.

-- ---------------------------------------------------------------------
-- 1. Extend inbound receipts
-- ---------------------------------------------------------------------
ALTER TABLE public.line_item_receipts
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES public.warehouses(id),
  ADD COLUMN IF NOT EXISTS voucher_no text,
  ADD COLUMN IF NOT EXISTS approved_by uuid REFERENCES public.app_users(id),
  ADD COLUMN IF NOT EXISTS approved_at timestamptz;

CREATE OR REPLACE FUNCTION public.approve_line_item_receipt(p_receipt_id uuid)
RETURNS public.line_item_receipts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_row line_item_receipts%ROWTYPE;
BEGIN
  IF NOT is_finance_team_member(NULL) THEN
    RAISE EXCEPTION 'not authorized to approve a goods receipt';
  END IF;

  UPDATE line_item_receipts
  SET approved_by = auth.uid(), approved_at = now()
  WHERE id = p_receipt_id
    AND EXISTS (
      SELECT 1 FROM request_line_items rli JOIN requests r ON r.id = rli.request_id
      WHERE rli.id = line_item_receipts.line_item_id AND r.tenant_id = get_my_tenant_id()
    )
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'receipt not found';
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_line_item_receipt(uuid) TO authenticated;

-- record_line_item_receipt() (0017 / 20260802161802) takes 3 args and
-- doesn't accept warehouse_id/voucher_no. Rather than break its existing
-- call sites, add an overload that does, and have it do the same work.
CREATE OR REPLACE FUNCTION public.record_line_item_receipt(
  p_line_item_id uuid,
  p_received_qty numeric,
  p_warehouse_id uuid,
  p_voucher_no text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS public.line_item_receipts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_row public.line_item_receipts;
BEGIN
  v_row := public.record_line_item_receipt(p_line_item_id, p_received_qty, p_note);

  UPDATE line_item_receipts
  SET warehouse_id = p_warehouse_id, voucher_no = p_voucher_no
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_line_item_receipt(uuid, numeric, uuid, text, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 2. Outbound goods issue (digitized Ambar Çıkış Formu)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.goods_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id),
  project_label text, -- "PROJECT NAME & CODE" on the form
  voucher_no text,    -- "Voucher No / Belge No"
  issue_date date NOT NULL DEFAULT CURRENT_DATE,
  warehouse_officer_id uuid NOT NULL REFERENCES public.app_users(id), -- "AMBAR YETKİLİSİ" -- the system actor recording the issue
  received_by_name text,  -- "TESLİM ALAN" -- often site personnel, not necessarily a system user, so free text
  approved_by_name text,  -- "ONAYLAYAN"
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.goods_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY goods_issues_select ON public.goods_issues
  FOR SELECT
  USING (tenant_id = get_my_tenant_id());
-- No direct insert policy -- only record_goods_issue() writes.

CREATE TABLE IF NOT EXISTS public.goods_issue_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  goods_issue_id uuid NOT NULL REFERENCES public.goods_issues(id) ON DELETE CASCADE,
  item_no int NOT NULL,
  material_catalog_id uuid REFERENCES public.material_catalog(id),
  material_description text NOT NULL, -- "MALZEME TANIMI" -- kept even when material_catalog_id is set, so the issued description is preserved as recorded
  cost_center_id uuid REFERENCES public.cost_centers(id), -- "MASRAF MERKEZİ"
  unit text NOT NULL,
  requested_qty numeric CHECK (requested_qty IS NULL OR requested_qty >= 0), -- "Talep"
  delivered_qty numeric NOT NULL CHECK (delivered_qty > 0),                  -- "Teslim" -- what actually leaves the warehouse
  remarks text
);

CREATE INDEX IF NOT EXISTS idx_goods_issue_items_issue ON public.goods_issue_items(goods_issue_id);

ALTER TABLE public.goods_issue_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY goods_issue_items_select ON public.goods_issue_items
  FOR SELECT
  USING (EXISTS (SELECT 1 FROM goods_issues gi WHERE gi.id = goods_issue_items.goods_issue_id AND gi.tenant_id = get_my_tenant_id()));
-- No direct insert policy -- only record_goods_issue() writes.

-- Single call writes the header + every line item together, so a form
-- submission can't be left half-saved the way request_line_items warns
-- its own two-step insert can be (see 0015_request_line_items.sql).
CREATE OR REPLACE FUNCTION public.record_goods_issue(
  p_warehouse_id uuid,
  p_project_label text,
  p_voucher_no text,
  p_received_by_name text,
  p_approved_by_name text,
  p_items jsonb -- [{material_catalog_id, material_description, cost_center_id, unit, requested_qty, delivered_qty, remarks}, ...]
)
RETURNS public.goods_issues
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_issue goods_issues%ROWTYPE;
  v_item jsonb;
  v_item_no int := 1;
BEGIN
  IF NOT has_receipt_access() THEN
    RAISE EXCEPTION 'not authorized to record goods issues';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM warehouses WHERE id = p_warehouse_id AND tenant_id = get_my_tenant_id()) THEN
    RAISE EXCEPTION 'warehouse not found';
  END IF;

  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'a goods issue needs at least one line item';
  END IF;

  INSERT INTO goods_issues (tenant_id, warehouse_id, project_label, voucher_no, warehouse_officer_id, received_by_name, approved_by_name)
  VALUES (get_my_tenant_id(), p_warehouse_id, p_project_label, p_voucher_no, auth.uid(), p_received_by_name, p_approved_by_name)
  RETURNING * INTO v_issue;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO goods_issue_items (
      goods_issue_id, item_no, material_catalog_id, material_description,
      cost_center_id, unit, requested_qty, delivered_qty, remarks
    )
    VALUES (
      v_issue.id, v_item_no,
      NULLIF(v_item->>'material_catalog_id', '')::uuid,
      v_item->>'material_description',
      NULLIF(v_item->>'cost_center_id', '')::uuid,
      v_item->>'unit',
      NULLIF(v_item->>'requested_qty', '')::numeric,
      (v_item->>'delivered_qty')::numeric,
      v_item->>'remarks'
    );
    v_item_no := v_item_no + 1;
  END LOOP;

  RETURN v_issue;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_goods_issue(uuid, text, text, text, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. Stock ledger + maintained running balance
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id),
  material_catalog_id uuid REFERENCES public.material_catalog(id),
  material_name text NOT NULL, -- denormalized so the ledger works even for materials not (yet) in the catalog
  unit text,
  movement_type text NOT NULL CHECK (movement_type IN ('in', 'out')),
  quantity numeric NOT NULL CHECK (quantity > 0),
  reference_type text NOT NULL CHECK (reference_type IN ('goods_receipt', 'goods_issue')),
  reference_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  recorded_by uuid NOT NULL REFERENCES public.app_users(id)
);

CREATE INDEX IF NOT EXISTS idx_stock_movements_warehouse_material ON public.stock_movements(warehouse_id, material_catalog_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_reference ON public.stock_movements(reference_type, reference_id);

ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY stock_movements_select ON public.stock_movements
  FOR SELECT
  USING (tenant_id = get_my_tenant_id());
-- No insert/update/delete policy -- only the two triggers below write here.

CREATE TABLE IF NOT EXISTS public.stock_balances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id),
  material_catalog_id uuid REFERENCES public.material_catalog(id),
  material_name text NOT NULL,
  unit text,
  -- Materials without a catalog entry are matched by name (case/space
  -- insensitive); catalog materials are matched by id regardless of how
  -- the description text varies between a receipt and an issue.
  stock_key text GENERATED ALWAYS AS (COALESCE(material_catalog_id::text, lower(trim(material_name)))) STORED,
  quantity_on_hand numeric NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (warehouse_id, stock_key)
);

ALTER TABLE public.stock_balances ENABLE ROW LEVEL SECURITY;

CREATE POLICY stock_balances_select ON public.stock_balances
  FOR SELECT
  USING (tenant_id = get_my_tenant_id());
-- No insert/update/delete policy -- only apply_stock_movement() writes.

CREATE OR REPLACE FUNCTION public.apply_stock_movement()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_delta numeric := CASE WHEN NEW.movement_type = 'in' THEN NEW.quantity ELSE -NEW.quantity END;
BEGIN
  INSERT INTO stock_balances (tenant_id, warehouse_id, material_catalog_id, material_name, unit, quantity_on_hand, updated_at)
  VALUES (NEW.tenant_id, NEW.warehouse_id, NEW.material_catalog_id, NEW.material_name, NEW.unit, v_delta, now())
  ON CONFLICT (warehouse_id, stock_key) DO UPDATE
    SET quantity_on_hand = stock_balances.quantity_on_hand + v_delta,
        updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_apply_stock_movement
  AFTER INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.apply_stock_movement();

-- Feed the ledger from inbound receipts. Needs a warehouse_id to post
-- (older receipts recorded before this migration won't have one) --
-- those are skipped rather than failed, since backfilling them is a data
-- decision, not something a trigger should guess at.
CREATE OR REPLACE FUNCTION public.post_receipt_to_stock()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_line request_line_items%ROWTYPE;
  v_tenant_id uuid;
BEGIN
  IF NEW.warehouse_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_line FROM request_line_items WHERE id = NEW.line_item_id;
  SELECT r.tenant_id INTO v_tenant_id FROM requests r WHERE r.id = v_line.request_id;

  INSERT INTO stock_movements (tenant_id, warehouse_id, material_name, unit, movement_type, quantity, reference_type, reference_id, recorded_by)
  VALUES (v_tenant_id, NEW.warehouse_id, v_line.material_service, NULL, 'in', NEW.received_qty, 'goods_receipt', NEW.id, NEW.received_by);

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_post_receipt_to_stock
  AFTER INSERT ON public.line_item_receipts
  FOR EACH ROW EXECUTE FUNCTION public.post_receipt_to_stock();

-- Feed the ledger from outbound issues.
CREATE OR REPLACE FUNCTION public.post_issue_items_to_stock()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_issue goods_issues%ROWTYPE;
BEGIN
  SELECT * INTO v_issue FROM goods_issues WHERE id = NEW.goods_issue_id;

  INSERT INTO stock_movements (tenant_id, warehouse_id, material_catalog_id, material_name, unit, movement_type, quantity, reference_type, reference_id, recorded_by)
  VALUES (v_issue.tenant_id, v_issue.warehouse_id, NEW.material_catalog_id, NEW.material_description, NEW.unit, 'out', NEW.delivered_qty, 'goods_issue', NEW.id, v_issue.warehouse_officer_id);

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_post_issue_items_to_stock
  AFTER INSERT ON public.goods_issue_items
  FOR EACH ROW EXECUTE FUNCTION public.post_issue_items_to_stock();