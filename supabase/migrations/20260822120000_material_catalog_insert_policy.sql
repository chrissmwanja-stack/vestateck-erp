-- Restores the material_catalog INSERT policy dropped by the squash.
--
-- 20260818070000_material_catalog_insert_policy.sql (now in
-- migrations_archive/) added both an INSERT policy and a
-- trg_set_material_catalog_defaults BEFORE INSERT trigger (to fill
-- tenant_id server-side) for MaterialCatalogAdmin.tsx, added the same
-- day. Neither survived 20260819122921_squashed_baseline.sql the next
-- day -- the squash kept material_catalog's SELECT and UPDATE policies
-- but silently dropped the INSERT one, and dropped the trigger too.
-- Net effect: "New material" has been unreachable since 2026-08-19 --
-- RLS has no policy to allow the insert regardless of what tenant_id
-- the client sends.
--
-- This migration only restores the RLS policy, not the trigger. The
-- client fix (this commit) now resolves and sends a real tenant_id
-- itself, the same way AccountsAdmin.tsx and EmployeesList.tsx already
-- do for their own no-default, no-trigger tenant_id columns --
-- deliberately not reintroducing a second, independent mechanism
-- (client-side resolution AND a trigger) for the same value, since
-- that's exactly the kind of split source-of-truth a future squash can
-- silently drop one half of again without anything failing loudly
-- until someone clicks "New material".
--
-- Same authority as material_catalog_update: has_po_access(), scoped
-- to the caller's own tenant.

CREATE POLICY "material_catalog_insert" ON "public"."material_catalog"
  FOR INSERT
  WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));