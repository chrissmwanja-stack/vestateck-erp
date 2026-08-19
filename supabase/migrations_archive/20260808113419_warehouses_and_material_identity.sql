-- Migration: warehouses_and_material_identity
--
-- Foundation for stock management. Two things:
--   1. Warehouses -- you run one per project/site, not one per tenant, so
--      this is a real table (not a single implicit warehouse) referenced
--      by both inbound receipts and outbound issues below.
--   2. material_catalog.code already exists (added in 0011) but was never
--      constrained -- nothing stopped two rows sharing a code. Stock
--      balances need a stable identity per material per warehouse, so we
--      enforce uniqueness now. material_catalog.code is the SAP material
--      number field from the goods forms (MATERIAL SAP NO / MALZEME SAP
--      NO); material_catalog.unit already covers pack/pcs/m.

CREATE TABLE IF NOT EXISTS public.warehouses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  name text NOT NULL,
  code text,
  project_label text, -- free text: "PROJECT NAME & CODE" on the paper form; no projects table exists yet to reference
  department_id uuid REFERENCES public.departments(id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.app_users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_warehouses_tenant_code
  ON public.warehouses (tenant_id, code) WHERE code IS NOT NULL;

ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;

CREATE POLICY warehouses_select ON public.warehouses
  FOR SELECT
  USING (tenant_id = get_my_tenant_id());

-- Administered the same way cost centers and accounts are (finance-team
-- authority), matching the existing convention rather than inventing a
-- new admin concept -- see 20260802161802_material_receipt_tracking.sql.
CREATE POLICY warehouses_insert ON public.warehouses
  FOR INSERT
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY warehouses_update ON public.warehouses
  FOR UPDATE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id())
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE OR REPLACE FUNCTION public.set_warehouse_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  NEW.created_by := COALESCE(NEW.created_by, auth.uid());
  RETURN NEW;
END;
$$;

CREATE TRIGGER set_warehouse_defaults_trigger
  BEFORE INSERT ON public.warehouses
  FOR EACH ROW
  EXECUTE FUNCTION public.set_warehouse_defaults();

-- Materials: enforce that a SAP code, where given, is unique per tenant.
-- Existing rows with duplicate/blank codes are left alone (partial index),
-- so this doesn't fail on data that predates the constraint.
CREATE UNIQUE INDEX IF NOT EXISTS idx_material_catalog_tenant_code
  ON public.material_catalog (tenant_id, code) WHERE code IS NOT NULL AND code <> '';