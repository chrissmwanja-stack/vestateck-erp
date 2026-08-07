-- Generic updated_at toucher, used by both receivable_invoices and
-- expenditure_slips (and supplier_invoices, wired up in the next migration).
-- Renamed from touch_receivable_invoice_updated_at() which was misleadingly
-- table-specific in name despite being generic in body.

ALTER FUNCTION public.touch_receivable_invoice_updated_at() RENAME TO touch_updated_at;
