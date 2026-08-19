
-- Once an invoice is created against an organization, it cannot be moved to
-- a different organization -- that would silently orphan its already-issued
-- PRF/OIF number (locked to the original org's company_code) from its new
-- parent. Reassigning to a different org means the invoice must be voided
-- and re-entered under the correct org instead.
create or replace function public.prevent_invoice_organization_change()
returns trigger
language plpgsql
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization cannot be changed on an existing invoice (was %, attempted %) -- void and re-enter under the correct organization instead', old.organization_id, new.organization_id;
  end if;
  return new;
end;
$$;

create trigger lock_supplier_invoice_organization
  before update on public.supplier_invoices
  for each row execute function public.prevent_invoice_organization_change();

create trigger lock_receivable_invoice_organization
  before update on public.receivable_invoices
  for each row execute function public.prevent_invoice_organization_change();
