-- Migration: invoice_payment_receipt_gate
--
-- Enforces the two-step verification: Finance can record a payment
-- against a supplier invoice only up to the value of what the warehouse
-- has actually confirmed received (per the "allow paying only for what's
-- received" decision, not an all-or-nothing block).
--
-- cash_bank_transactions has no RPC in front of it (0016 /
-- 20260801142554) -- it's a direct insert gated by RLS -- so this is a
-- BEFORE INSERT trigger, the same shape as the existing AFTER INSERT
-- triggers on this table (trg_check_po_completion_on_cash_bank).
--
-- Cap is value-based, not just quantity-based: it sums, across the PO's
-- line items, min(received_qty, ordered_qty) * unit_price, then scales
-- that by (invoice total / ordered total) so VAT and any invoice-vs-PO
-- rounding differences are spread proportionally rather than ignored.
-- Falls back to a plain quantity ratio if line items have no unit_price
-- (total ordered value is 0/null) -- some requests are logged without
-- pricing.

CREATE OR REPLACE FUNCTION public.supplier_invoice_receipt_cap(p_invoice_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_invoice supplier_invoices%ROWTYPE;
  v_ordered_value numeric;
  v_received_value numeric;
  v_ordered_qty numeric;
  v_received_qty numeric;
BEGIN
  SELECT * INTO v_invoice FROM supplier_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  SELECT
    COALESCE(SUM(rli.quantity * rli.unit_price), 0),
    COALESCE(SUM(LEAST(rec.received_qty, rli.quantity) * rli.unit_price), 0),
    COALESCE(SUM(rli.quantity), 0),
    COALESCE(SUM(LEAST(rec.received_qty, rli.quantity)), 0)
  INTO v_ordered_value, v_received_value, v_ordered_qty, v_received_qty
  FROM request_line_items rli
  JOIN requests r ON r.id = rli.request_id
  LEFT JOIN (
    SELECT line_item_id, SUM(received_qty) AS received_qty
    FROM line_item_receipts GROUP BY line_item_id
  ) rec ON rec.line_item_id = rli.id
  JOIN purchase_orders po ON po.request_id = r.id
  WHERE po.id = v_invoice.purchase_order_id;

  IF v_ordered_value > 0 THEN
    RETURN LEAST(v_invoice.amount_incl_vat, v_invoice.amount_incl_vat * (v_received_value / v_ordered_value));
  ELSIF v_ordered_qty > 0 THEN
    RETURN LEAST(v_invoice.amount_incl_vat, v_invoice.amount_incl_vat * (v_received_qty / v_ordered_qty));
  ELSE
    RETURN 0; -- no line items / nothing ordered -- nothing payable yet
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_payment_against_receipt()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $$
DECLARE
  v_cap numeric;
  v_already_paid numeric;
  v_invoice supplier_invoices%ROWTYPE;
BEGIN
  IF NEW.reference_type != 'supplier_invoice' OR NEW.transaction_type != 'payment' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_invoice FROM supplier_invoices WHERE id = NEW.reference_id;
  IF NOT FOUND THEN
    RETURN NEW; -- unrelated reference_id / bad data -- not this trigger's job to police
  END IF;

  v_cap := supplier_invoice_receipt_cap(v_invoice.id);
  v_already_paid := v_invoice.amount_incl_vat - supplier_invoice_outstanding(v_invoice.id);

  IF v_already_paid + NEW.amount > v_cap + 0.01 THEN -- small epsilon for rounding
    RAISE EXCEPTION
      'payment blocked: only % of % has been confirmed received for this invoice (already paid %, this payment %)',
      round(v_cap, 2), v_invoice.amount_incl_vat, round(v_already_paid, 2), NEW.amount;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_payment_against_receipt
  BEFORE INSERT ON public.cash_bank_transactions
  FOR EACH ROW EXECUTE FUNCTION public.check_payment_against_receipt();

-- Read-side helper so the UI can show "you can pay up to X" before the
-- user hits submit, rather than only finding out from a rejected insert.
CREATE OR REPLACE FUNCTION public.supplier_invoice_payable_now(p_invoice_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = 'public'
AS $$
  SELECT GREATEST(0,
    LEAST(
      supplier_invoice_receipt_cap(p_invoice_id) - (si.amount_incl_vat - supplier_invoice_outstanding(p_invoice_id)),
      supplier_invoice_outstanding(p_invoice_id)
    )
  )
  FROM supplier_invoices si WHERE si.id = p_invoice_id;
$$;

GRANT EXECUTE ON FUNCTION public.supplier_invoice_receipt_cap(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.supplier_invoice_payable_now(uuid) TO authenticated;