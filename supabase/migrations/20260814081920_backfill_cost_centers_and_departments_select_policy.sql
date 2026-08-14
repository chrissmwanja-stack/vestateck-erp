-- Captures two RLS SELECT policies that already exist live but were never
-- committed to a migration -- exactly the "dashboard-only SQL" pattern
-- MIGRATION_POLICY.md rule 3 exists to prevent. Confirmed via pg_policies
-- on the live project (2026-08-14) before writing this: both existed
-- there already, byte-for-byte identical to what's added below.
--
-- Surfaced during a local procurement smoke test: cost_centers and
-- departments each had INSERT/UPDATE(/DELETE) policies in the migration
-- history but no SELECT policy at all. Live worked anyway because these
-- two policies were applied directly via the dashboard SQL editor at some
-- point and never captured -- so a fresh local `db reset` silently
-- returned zero rows for both tables (RLS default-denies with no matching
-- policy) even after table-level grants were fixed.
--
-- Read access is tenant-wide, no role restriction, matching the existing
-- material_types_select / account_categories_select pattern -- these are
-- form-dropdown lookups (cost center picker, department picker), not
-- sensitive data; write access remains role-gated by the existing
-- INSERT/UPDATE(/DELETE) policies.
--
-- DROP POLICY IF EXISTS first so this is safe to apply on live, where the
-- policy already exists under this exact name.

drop policy if exists cost_centers_select_tenant on public.cost_centers;
create policy cost_centers_select_tenant on public.cost_centers
  for select using (tenant_id = get_my_tenant_id());

drop policy if exists departments_select_tenant on public.departments;
create policy departments_select_tenant on public.departments
  for select using (tenant_id = get_my_tenant_id());