-- Add updated_at to supplier_invoices so Edit Invoice can track edits
-- consistently with receivable_invoices / expenditure_slips.

ALTER TABLE public.supplier_invoices
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

CREATE TRIGGER touch_supplier_invoice_updated_at_trigger
  BEFORE UPDATE ON public.supplier_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_updated_at();
