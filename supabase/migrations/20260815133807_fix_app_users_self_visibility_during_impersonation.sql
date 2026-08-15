-- Platform admins impersonating a tenant have get_my_tenant_id() resolve to the
-- impersonated tenant, but their own app_users row keeps their real (home) tenant_id.
-- The tenant-scoped SELECT policy alone hides their own row from them during
-- impersonation, which breaks InviteMember.tsx's admin check and any staff_roles
-- policy that does EXISTS(SELECT ... FROM app_users WHERE id = auth.uid() ...).
-- A user should always be able to see their own row regardless of tenant scoping.
drop policy if exists app_users_select_tenant on app_users;

create policy app_users_select_tenant on app_users
  for select
  using (
    tenant_id = get_my_tenant_id()
    or id = (select auth.uid())
  );