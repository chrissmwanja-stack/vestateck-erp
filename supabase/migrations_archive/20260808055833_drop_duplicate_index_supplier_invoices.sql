-- supplier_invoices had two identical unique indexes on purchase_order_id
-- (advisor-flagged duplicate_index). Neither backs a formal constraint,
-- so dropping one is a pure no-op for correctness -- keeps the same
-- uniqueness guarantee while halving the write-time index maintenance
-- cost on this column.
DROP INDEX IF EXISTS public.supplier_invoices_purchase_order_id_unique_idx;
