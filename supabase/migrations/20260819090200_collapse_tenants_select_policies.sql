-- Collapse tenants' two SELECT policies (own tenant OR platform admin)
-- into a single OR'd policy. Same access, one policy evaluated per
-- query instead of two.

DROP POLICY IF EXISTS tenants_select_own ON public.tenants;
DROP POLICY IF EXISTS tenants_select_platform_admin ON public.tenants;

CREATE POLICY tenants_select ON public.tenants
FOR SELECT USING (
  (id = get_my_tenant_id())
  OR is_platform_admin()
);