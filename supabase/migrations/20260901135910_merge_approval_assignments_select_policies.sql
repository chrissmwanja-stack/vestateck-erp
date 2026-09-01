-- Merge the two permissive SELECT policies on approval_assignments into one.
-- Previously: approval_assignments_admin_select (authenticated) + approval_assignments_select_own
-- (public, but functionally authenticated-only since auth.uid() is NULL for anon and
-- NULL never equals user_id). Both were PERMISSIVE, so Postgres evaluated and OR'd them
-- on every authenticated query. No behavior change: anon still gets zero rows (no matching
-- policy at all now, same net effect as the NULL comparison before).
DROP POLICY IF EXISTS approval_assignments_admin_select ON public.approval_assignments;
DROP POLICY IF EXISTS approval_assignments_select_own ON public.approval_assignments;

CREATE POLICY approval_assignments_select ON public.approval_assignments
FOR SELECT
TO authenticated
USING (
  (tenant_id = get_my_tenant_id() AND is_tenant_admin())
  OR (user_id = (SELECT auth.uid()))
);