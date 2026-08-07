-- PRF/OIF No: a distinct reference field seen in the MAKS reference tool's
-- search bar, separate from Invoice No and PO No. Nullable/optional, same
-- pattern as organization_id -- doesn't force a new required field onto an
-- already-working entry flow.
alter table public.supplier_invoices
  add column prf_oif_number text;

alter table public.receivable_invoices
  add column prf_oif_number text;

-- Supports the search bar lookups (EditInvoice.tsx) and general filtering.
create index supplier_invoices_prf_oif_number_idx
  on public.supplier_invoices (prf_oif_number)
  where prf_oif_number is not null;

create index receivable_invoices_prf_oif_number_idx
  on public.receivable_invoices (prf_oif_number)
  where prf_oif_number is not null;
