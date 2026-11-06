-- set_sap_payment_defaults() read purchase_orders.tenant_id, which does not exist
-- (purchase_orders has no tenant_id column; tenancy lives on requests via
-- purchase_orders.request_id — the purchase_orders RLS policies join through
-- requests the same way). Every INSERT into sap_payments therefore failed with
-- 42703 "column tenant_id does not exist" before RLS WITH CHECK was evaluated.
-- Derive the tenant through requests.
--
-- CREATE OR REPLACE preserves existing grants. sap_payments has 0 rows and nothing
-- can currently insert into it, so applying to live is low-risk.
-- Also fixes the truncated header comment of 20261106150000 (documented here
-- rather than edited in place to avoid a checksum mismatch on an applied file).

create or replace function public.set_sap_payment_defaults()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  select r.tenant_id into new.tenant_id
  from purchase_orders po
  join requests r on r.id = po.request_id
  where po.id = new.purchase_order_id;

  if new.tenant_id is null then
    raise exception 'purchase_order_id % not found or has no tenant', new.purchase_order_id;
  end if;

  new.recorded_by := auth.uid();
  return new;
end;
$$;
