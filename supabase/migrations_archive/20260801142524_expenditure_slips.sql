-- Expenditure Slips â petty-cash / minor disbursement vouchers against a
-- cost center. Distinct from Supplier Invoice (vendor billing): no vendor
-- invoice number, just a payee and purpose for a direct cash/bank outlay.

CREATE TABLE public.expenditure_slips (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  cost_center_id uuid NOT NULL REFERENCES public.cost_centers(id),
  slip_number text NOT NULL,
  slip_date date NOT NULL,
  payee_name text NOT NULL,
  purpose text NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'UGX',
  recorded_by uuid NOT NULL DEFAULT auth.uid() REFERENCES public.app_users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.expenditure_slips ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.set_expenditure_slip_defaults()
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

CREATE TRIGGER set_expenditure_slip_defaults_trigger
  BEFORE INSERT ON public.expenditure_slips
  FOR EACH ROW
  EXECUTE FUNCTION public.set_expenditure_slip_defaults();

CREATE TRIGGER touch_expenditure_slip_updated_at_trigger
  BEFORE UPDATE ON public.expenditure_slips
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_receivable_invoice_updated_at();

CREATE POLICY expenditure_slips_select ON public.expenditure_slips
  FOR SELECT
  USING (is_finance_team_member(NULL) AND tenant_id = get_my_tenant_id());

CREATE POLICY expenditure_slips_insert ON public.expenditure_slips
  FOR INSERT
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY expenditure_slips_update ON public.expenditure_slips
  FOR UPDATE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id())
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY expenditure_slips_delete ON public.expenditure_slips
  FOR DELETE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());
