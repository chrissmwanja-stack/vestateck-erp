-- Private bucket for generated Purchase Order PDFs.
-- Access is only ever via service-role (inside the generate-po Edge
-- Function) + short-lived signed URLs â no client-facing storage
-- policies are needed since nothing reads/writes this bucket directly.
insert into storage.buckets (id, name, public)
values ('purchase-order-documents', 'purchase-order-documents', false)
on conflict (id) do nothing;
