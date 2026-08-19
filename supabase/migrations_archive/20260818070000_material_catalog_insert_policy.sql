-- material_catalog had SELECT and UPDATE policies (20260803081641) but no
-- INSERT policy at all -- rows could previously only be created via
-- approve_material_request_item(), so there was no direct-entry path for
-- routine catalog items (toner, paper, tools, etc.) that don't need to go
-- through the full material-request-and-approval workflow. This blocked a
-- standalone admin CRUD screen entirely: even with the RLS-satisfying
-- has_po_access() check, there was no policy for insert to satisfy at all.
--
-- Same authority as the existing update policy (has_po_access() and
-- tenant scoping), matching material_types/material_groups/
-- external_material_groups' insert policies in the same original
-- migration. No delete policy is added deliberately -- material_catalog_id
-- is FK'd from goods_issue_items, material_request_items, stock_balances,
-- and stock_movements, so a hard delete would either fail on FK violation
-- or (with an incautious ON DELETE) silently corrupt historical stock/
-- transaction records. The existing is_active column (added in the same
-- 20260803081641 migration) plus the update policy already gate/enable a
-- deactivate-instead-of-delete flow, matching every other master table in
-- this schema (warehouses, accounts, organizations, etc.).

create policy material_catalog_insert on public.material_catalog
  for insert with check (has_po_access() and tenant_id = get_my_tenant_id());

-- material_catalog never had a BEFORE INSERT trigger to set tenant_id
-- (only material_types/material_groups/external_material_groups did, via
-- set_material_lookup_defaults() in 20260803081641). Reuse that same
-- generic function rather than duplicating it -- it only reads
-- get_my_tenant_id(), nothing table-specific.
drop trigger if exists trg_set_material_catalog_defaults on public.material_catalog;
create trigger trg_set_material_catalog_defaults
  before insert on public.material_catalog
  for each row execute function public.set_material_lookup_defaults();