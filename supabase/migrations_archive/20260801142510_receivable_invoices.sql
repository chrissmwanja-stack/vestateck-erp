-- Receivable Invoice â AR mirror of Supplier Invoice. Money owed TO the
-- company by clients, not tied to a PO. Attributable to a cost center
-- (project/revenue line) for reporting, same role cost_center_id plays
-- for non-PO supplier invoices.

CREATE TABLE public.receivable_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  cost_center_id uuid REFERENCES public.cost_centers(id),
  client_name text NOT NULL,
  invoice_number text NOT NULL,
  invoice_date date NOT NULL,
  amount_incl_vat numeric NOT NULL CHECK (amount_incl_vat > 0),
  vat_amount numeric NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  currency text NOT NULL DEFAULT 'UGX',
  description text,
  status text NOT NULL DEFAULT 'open' CHECK (status = ANY (ARRAY['open'::text, 'paid'::text])),
  recorded_by uuid NOT NULL DEFAULT auth.uid() REFERENCES public.app_users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.receivable_invoices ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.set_receivable_invoice_defaults()
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

CREATE TRIGGER set_receivable_invoice_defaults_trigger
  BEFORE INSERT ON public.receivable_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.set_receivable_invoice_defaults();

CREATE OR REPLACE FUNCTION public.touch_receivable_invoice_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER touch_receivable_invoice_updated_at_trigger
  BEFORE UPDATE ON public.receivable_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_receivable_invoice_updated_at();

CREATE POLICY receivable_invoices_select ON public.receivable_invoices
  FOR SELECT
  USING (is_finance_team_member(NULL) AND tenant_id = get_my_tenant_id());

CREATE POLICY receivable_invoices_insert ON public.receivable_invoices
  FOR INSERT
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY receivable_invoices_update ON public.receivable_invoices
  FOR UPDATE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id())
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY receivable_invoices_delete ON public.receivable_invoices
  FOR DELETE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());
