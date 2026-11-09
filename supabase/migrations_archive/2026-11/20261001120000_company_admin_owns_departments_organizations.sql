-- Company admin owns departments and organizations.
--
-- Administration model (three layers): platform console -> Company Admin ->
-- module administration. Departments (org structure) and organizations
-- (company codes / sites) are company-level configuration, so they belong to
-- the Company Admin layer -- not to the finance team and not to whichever
-- module admin happens to exist.
--
-- Before this migration:
--   departments  insert/update/delete: is_finance_team_member('finance') OR
--                                      is_any_module_admin()
--   organizations insert/update/delete: is_finance_team_member('finance')
--   organizations select:               finance team (any role) OR has_po_access()
-- A company admin with no finance row and no module role could therefore do
-- neither, while any single-module admin could rewrite the whole org
-- structure. A company admin is NOT a super user (no implicit finance or
-- module rights), but they do own this configuration.
--
-- After:
--   departments  insert/update/delete: is_tenant_admin()
--   organizations insert/update/delete: is_tenant_admin()
--   organizations select:               finance team OR has_po_access() OR
--                                       is_tenant_admin()  (finance and
--                                       procurement still read the list to
--                                       pick a company code)
-- departments_select_tenant is unchanged (every tenant member reads the list).
--
-- is_tenant_admin() is impersonation-aware (platform_admin_bypass() or the
-- effective user's is_company_admin flag), so a platform admin viewing as a
-- specific user gets exactly that user's rights. Every policy keeps the
-- tenant_id = get_my_tenant_id() scope.
--
-- Writers outside the company admin that this removes (intentional):
--   * finance team members and module admins writing departments
--     (the HR Org Chart now shows department create/edit/delete to the
--     company admin only; employee assignment is unaffected)
--   * finance team members writing organizations
-- SECURITY DEFINER seeding (seed_tenant_defaults, template apply) bypasses
-- RLS and is unaffected.

-- ---------------------------------------------------------------------
-- departments
-- ---------------------------------------------------------------------
drop policy if exists "departments_insert" on "public"."departments";
drop policy if exists "departments_update" on "public"."departments";
drop policy if exists "departments_delete" on "public"."departments";

create policy "departments_insert"
  on "public"."departments"
  as permissive
  for insert
  to public
  with check (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id());

create policy "departments_update"
  on "public"."departments"
  as permissive
  for update
  to public
  using (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id())
  with check (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id());

create policy "departments_delete"
  on "public"."departments"
  as permissive
  for delete
  to public
  using (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id());

-- ---------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------
drop policy if exists "organizations_insert" on "public"."organizations";
drop policy if exists "organizations_update" on "public"."organizations";
drop policy if exists "organizations_delete" on "public"."organizations";
drop policy if exists "organizations_select" on "public"."organizations";

create policy "organizations_insert"
  on "public"."organizations"
  as permissive
  for insert
  to public
  with check (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id());

create policy "organizations_update"
  on "public"."organizations"
  as permissive
  for update
  to public
  using (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id())
  with check (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id());

create policy "organizations_delete"
  on "public"."organizations"
  as permissive
  for delete
  to public
  using (public.is_tenant_admin() and tenant_id = public.get_my_tenant_id());

create policy "organizations_select"
  on "public"."organizations"
  as permissive
  for select
  to public
  using (
    tenant_id = public.get_my_tenant_id()
    and (
      public.is_finance_team_member(null::text)
      or public.has_po_access()
      or public.is_tenant_admin()
    )
  );
