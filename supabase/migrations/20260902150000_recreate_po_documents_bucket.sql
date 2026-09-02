-- Fixes P0.3 from the 2026-09-02 deep analysis: the 'po-documents'
-- bucket is what every storage RLS policy (see
-- 20260901135345_remote_schema.sql and its predecessors) and both
-- frontend read/write sites (ProcurementInfo.tsx, RequestTracking.tsx)
-- already target, but the original `insert into storage.buckets`
-- statement lived in a pre-squash migration
-- (20260803100601_add_po_pdf_generation.sql, now archived) and did not
-- survive the 2026-08-19 schema-only squash. Confirmed live: as of
-- 2026-09-02, storage.buckets has 0 rows on this project -- PO PDF
-- upload/download is fully broken, not just a naming mismatch.
--
-- Standardizing on 'po-documents' (not 'purchase-order-documents',
-- the other name that briefly existed): it already has 16 live
-- references (RLS policies + frontend) vs. 2 (the generate-po edge
-- function's PO_BUCKET constant, fixed separately in this commit to
-- match).
insert into storage.buckets (id, name, public)
values ('po-documents', 'po-documents', false)
on conflict (id) do nothing;