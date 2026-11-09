-- Company admins (and platform admins) can configure their own tenant's
-- approval process. workflow_stages previously only had a SELECT policy
-- (tenant-scoped) -- no write path existed at all, which is why the
-- initial process had to be seeded directly rather than through the app.
-- is_tenant_admin() already covers "company admin OR platform admin",
-- matching the same gate set_member_access() uses for Team Members.

create policy workflow_stages_admin_insert
  on public.workflow_stages
  for insert
  to authenticated
  with check (tenant_id = get_my_tenant_id() and is_tenant_admin());

create policy workflow_stages_admin_update
  on public.workflow_stages
  for update
  to authenticated
  using (tenant_id = get_my_tenant_id() and is_tenant_admin())
  with check (tenant_id = get_my_tenant_id() and is_tenant_admin());

create policy workflow_stages_admin_delete
  on public.workflow_stages
  for delete
  to authenticated
  using (tenant_id = get_my_tenant_id() and is_tenant_admin());

-- approval_assignments previously only let a user see their own row
-- (user_id = auth.uid()), so an admin couldn't view the company's full
-- assignment roster, let alone edit it. Add an admin-wide SELECT
-- alongside the existing "see your own" policy (both PERMISSIVE, so
-- either satisfies it), plus the same admin-only write trio as above.

create policy approval_assignments_admin_select
  on public.approval_assignments
  for select
  to authenticated
  using (tenant_id = get_my_tenant_id() and is_tenant_admin());

create policy approval_assignments_admin_insert
  on public.approval_assignments
  for insert
  to authenticated
  with check (tenant_id = get_my_tenant_id() and is_tenant_admin());

create policy approval_assignments_admin_update
  on public.approval_assignments
  for update
  to authenticated
  using (tenant_id = get_my_tenant_id() and is_tenant_admin())
  with check (tenant_id = get_my_tenant_id() and is_tenant_admin());

create policy approval_assignments_admin_delete
  on public.approval_assignments
  for delete
  to authenticated
  using (tenant_id = get_my_tenant_id() and is_tenant_admin());