-- Cash and Bank Operations â payment/receipt ledger. Settles against a
-- supplier invoice, an expenditure slip, or a receivable invoice.
-- reference_type + reference_id is a polymorphic reference (validated in
-- the app layer, not by a DB FK, since it can point at three different
-- tables) rather than three separate near-identical settlement tables.

CREATE TABLE public.cash_bank_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  transaction_type text NOT NULL CHECK (transaction_type = ANY (ARRAY['payment'::text, 'receipt'::text])),
  payment_method text NOT NULL CHECK (payment_method = ANY (ARRAY['cash'::text, 'bank'::text])),
  reference_type text NOT NULL CHECK (reference_type = ANY (ARRAY['supplier_invoice'::text, 'expenditure_slip'::text, 'receivable_invoice'::text])),
  reference_id uuid NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'UGX',
  transaction_date date NOT NULL,
  bank_account text,
  description text,
  recorded_by uuid NOT NULL DEFAULT auth.uid() REFERENCES public.app_users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.cash_bank_transactions ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.set_cash_bank_transaction_defaults()
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

CREATE TRIGGER set_cash_bank_transaction_defaults_trigger
  BEFORE INSERT ON public.cash_bank_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_cash_bank_transaction_defaults();

CREATE POLICY cash_bank_transactions_select ON public.cash_bank_transactions
  FOR SELECT
  USING (is_finance_team_member(NULL) AND tenant_id = get_my_tenant_id());

CREATE POLICY cash_bank_transactions_insert ON public.cash_bank_transactions
  FOR INSERT
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY cash_bank_transactions_update ON public.cash_bank_transactions
  FOR UPDATE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id())
  WITH CHECK (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE POLICY cash_bank_transactions_delete ON public.cash_bank_transactions
  FOR DELETE
  USING (is_finance_team_member('finance') AND tenant_id = get_my_tenant_id());

CREATE INDEX cash_bank_transactions_reference_idx
  ON public.cash_bank_transactions (reference_type, reference_id);
