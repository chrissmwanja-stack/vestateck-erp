-- Collapse invitations' platform-admin/tenant-admin policy pairs
-- (both INSERT and SELECT) into single OR'd policies. Same access,
-- one policy evaluated per query per command instead of two.
--
-- Note the INSERT case is not a plain OR of two equal conditions: a
-- platform admin may insert any role_bundle, while a tenant admin may
-- only insert role_bundle = 'member' for their own tenant. That
-- asymmetry is preserved by keeping the tenant-admin branch's extra
-- role_bundle check inside its half of the OR.

DROP POLICY IF EXISTS invitations_insert_platform_admin ON public.invitations;
DROP POLICY IF EXISTS invitations_insert_tenant_admin ON public.invitations;
DROP POLICY IF EXISTS invitations_select_platform_admin ON public.invitations;
DROP POLICY IF EXISTS invitations_select_tenant_admin ON public.invitations;

CREATE POLICY invitations_insert ON public.invitations
FOR INSERT WITH CHECK (
  is_platform_admin()
  OR (
    role_bundle = 'member'
    AND tenant_id = get_my_tenant_id()
    AND EXISTS (
      SELECT 1 FROM staff_roles
      WHERE staff_roles.user_id = (SELECT auth.uid())
        AND staff_roles.tenant_id = invitations.tenant_id
        AND staff_roles.role = 'admin'
    )
  )
);

CREATE POLICY invitations_select ON public.invitations
FOR SELECT USING (
  is_platform_admin()
  OR (
    tenant_id = get_my_tenant_id()
    AND EXISTS (
      SELECT 1 FROM staff_roles
      WHERE staff_roles.user_id = (SELECT auth.uid())
        AND staff_roles.tenant_id = invitations.tenant_id
        AND staff_roles.role = 'admin'
    )
  )
);