-- Allow Supplier Invoice entries not tied to a PO (direct/non-PO expenses),
-- alongside the existing PO-related flow. One invoice per PO is still
-- enforced (partial unique index), but purchase_order_id is no longer
-- required -- a non-PO invoice must instead carry a cost_center_id so it's
-- always attributable to something for accounting/reporting purposes.

ALTER TABLE public.supplier_invoices
  ALTER COLUMN purchase_order_id DROP NOT NULL;

ALTER TABLE public.supplier_invoices
  DROP CONSTRAINT supplier_invoices_purchase_order_id_key;

CREATE UNIQUE INDEX supplier_invoices_purchase_order_id_unique_idx
  ON public.supplier_invoices (purchase_order_id)
  WHERE purchase_order_id IS NOT NULL;

ALTER TABLE public.supplier_invoices
  ADD COLUMN cost_center_id uuid REFERENCES public.cost_centers(id);

ALTER TABLE public.supplier_invoices
  ADD CONSTRAINT supplier_invoices_po_or_cost_center_check
  CHECK (purchase_order_id IS NOT NULL OR cost_center_id IS NOT NULL);

ALTER TABLE public.supplier_invoices
  ADD COLUMN invoice_type text GENERATED ALWAYS AS (
    CASE WHEN purchase_order_id IS NOT NULL THEN 'po_related' ELSE 'non_po' END
  ) STORED;
