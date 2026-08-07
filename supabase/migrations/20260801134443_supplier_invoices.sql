-- Supplier Invoice (PO Related) â Financial Management module
-- 1:1 with purchase_orders, data-entry only (no approval workflow, per reference screen)

CREATE TABLE public.supplier_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  purchase_order_id uuid NOT NULL UNIQUE REFERENCES public.purchase_orders(id),
  invoice_number text NOT NULL,
  invoice_date date NOT NULL,
  vendor_name text NOT NULL,
  amount_incl_vat numeric NOT NULL CHECK (amount_incl_vat > 0),
  vat_amount numeric NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  currency text NOT NULL DEFAULT 'UGX',
  description text,
  recorded_by uuid NOT NULL DEFAULT auth.uid() REFERENCES public.app_users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.supplier_invoices ENABLE ROW LEVEL SECURITY;

-- tenant_id defaulting, same pattern as set_cost_center_defaults() / set_sap_payment_defaults()
CREATE OR REPLACE FUNCTION public.set_supplier_invoice_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$$;

CREATE TRIGGER set_supplier_invoice_defaults_trigger
  BEFORE INSERT ON public.supplier_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.set_supplier_invoice_defaults();

-- RLS: view = any finance-team member (finance or cost_control); write = finance role only
CREATE POLICY supplier_invoices_select ON public.supplier_invoices
  FOR SELECT
  USING (is_finance_team_member(NULL) AND tenant_id = get_my_tenant_id());

CREATE POLICY supplier_invoices_insert ON public.supplier_invoices
  FOR INSERT
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY supplier_invoices_update ON public.supplier_invoices
  FOR UPDATE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id())
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY supplier_invoices_delete ON public.supplier_invoices
  FOR DELETE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());
