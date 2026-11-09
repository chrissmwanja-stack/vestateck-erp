-- Part A of the Team Members Admin feature: lets a company admin (or
-- platform admin) edit an *existing* member's module access and finance
-- role after they've accepted their invite. InviteMember.tsx only covers
-- creation; there was previously no way to change access afterward
-- short of hand-editing staff_roles / finance_team_members directly.
--
-- Auth boundary mirrors invite-user / useTenantAdminAccess: company admin
-- (is_company_admin) or platform admin (is_platform_admin) only, scoped
-- to the caller's *effective* tenant via get_my_tenant_id() so this
-- behaves correctly under impersonation. Every function also re-checks
-- that the target user belongs to that same tenant -- these are
-- SECURITY DEFINER and bypass RLS, so nothing else enforces the tenant
-- boundary between the caller and p_user_id.

CREATE OR REPLACE FUNCTION "public"."is_tenant_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM app_users
      WHERE id = auth.uid()
        AND is_company_admin
    );
$$;

ALTER FUNCTION "public"."is_tenant_admin"() OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."is_tenant_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_tenant_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_tenant_admin"() TO "service_role";

COMMENT ON FUNCTION "public"."is_tenant_admin"() IS
  'Company admin or platform admin. Shared auth boundary for the Team Members Admin RPCs -- kept as one function so the check can''t drift between them the way useTenantAdminAccess drifted across its three separate frontend copies.';

-- Module access --------------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."set_staff_module_role"("p_user_id" "uuid", "p_module" "text", "p_role" "text") RETURNS "public"."staff_roles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.staff_roles%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage team access';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into staff_roles (tenant_id, user_id, module, role)
  values (get_my_tenant_id(), p_user_id, p_module, p_role)
  on conflict (tenant_id, user_id, module) do update set role = excluded.role
  returning * into v_row;

  return v_row;
end;
$$;

ALTER FUNCTION "public"."set_staff_module_role"("uuid", "text", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_staff_module_role"("uuid", "text", "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_staff_module_role"("uuid", "text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_staff_module_role"("uuid", "text", "text") TO "service_role";

COMMENT ON FUNCTION "public"."set_staff_module_role"("uuid", "text", "text") IS
  'Grants (or changes the role on) one module for an existing team member. Company/platform-admin-only. Upserts on the (tenant_id, user_id, module) unique key.';

CREATE OR REPLACE FUNCTION "public"."remove_staff_module"("p_user_id" "uuid", "p_module" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage team access';
  end if;

  delete from staff_roles
  where user_id = p_user_id
    and tenant_id = get_my_tenant_id()
    and module = p_module;
end;
$$;

ALTER FUNCTION "public"."remove_staff_module"("uuid", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."remove_staff_module"("uuid", "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remove_staff_module"("uuid", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_staff_module"("uuid", "text") TO "service_role";

COMMENT ON FUNCTION "public"."remove_staff_module"("uuid", "text") IS
  'Revokes one module''s access for an existing team member. Company/platform-admin-only. Silently no-ops if the grant didn''t exist.';

-- Finance role -----------------------------------------------------------
-- finance_team_members is uniquely keyed on (tenant_id, user_id, role),
-- NOT (tenant_id, user_id) -- the schema alone does not stop a user
-- holding both a 'finance' and a 'cost_control' row at once. Since
-- is_finance_team_member() is an EXISTS check, a leftover row from a
-- prior role keeps granting that old role's access silently. So
-- set_finance_role explicitly deletes any other role row for this user
-- before inserting the new one, in the same transaction, rather than
-- relying on an ON CONFLICT upsert (which only matches on an identical
-- role and would never touch a *different* leftover role row).

CREATE OR REPLACE FUNCTION "public"."set_finance_role"("p_user_id" "uuid", "p_role" "text") RETURNS "public"."finance_team_members"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.finance_team_members%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage finance access';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  delete from finance_team_members
  where user_id = p_user_id
    and tenant_id = get_my_tenant_id()
    and role != p_role;

  insert into finance_team_members (tenant_id, user_id, role)
  values (get_my_tenant_id(), p_user_id, p_role)
  on conflict (tenant_id, user_id, role) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from finance_team_members
    where user_id = p_user_id and tenant_id = get_my_tenant_id() and role = p_role;
  end if;

  return v_row;
end;
$$;

ALTER FUNCTION "public"."set_finance_role"("uuid", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_finance_role"("uuid", "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_finance_role"("uuid", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_finance_role"("uuid", "text") TO "service_role";

COMMENT ON FUNCTION "public"."set_finance_role"("uuid", "text") IS
  'Sets a user''s finance role, replacing any other finance role they held (the table is uniquely keyed per-role, not per-user, so a naive upsert would leave a stale second row silently granting the old role). Company/platform-admin-only.';

CREATE OR REPLACE FUNCTION "public"."remove_finance_role"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage finance access';
  end if;

  delete from finance_team_members
  where user_id = p_user_id
    and tenant_id = get_my_tenant_id();
end;
$$;

ALTER FUNCTION "public"."remove_finance_role"("uuid") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."remove_finance_role"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remove_finance_role"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_finance_role"("uuid") TO "service_role";

COMMENT ON FUNCTION "public"."remove_finance_role"("uuid") IS
  'Removes all finance_team_members rows for a user in the caller''s tenant (covers the edge case of a pre-existing dual-role row from before this migration). Company/platform-admin-only.';

-- Read: list for the Team Members Admin table ---------------------------

CREATE OR REPLACE FUNCTION "public"."get_tenant_team_members"() RETURNS TABLE(
    "user_id" "uuid",
    "name" "text",
    "email" "text",
    "role_title" "text",
    "is_company_admin" boolean,
    "modules" "jsonb",
    "finance_role" "text"
)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    u.id,
    u.name,
    u.email,
    u.role_title,
    u.is_company_admin,
    coalesce(
      (select jsonb_agg(jsonb_build_object('module', sr.module, 'role', sr.role))
       from staff_roles sr
       where sr.user_id = u.id and sr.tenant_id = u.tenant_id),
      '[]'::jsonb
    ) as modules,
    (select ftm.role from finance_team_members ftm
     where ftm.user_id = u.id and ftm.tenant_id = u.tenant_id
     order by case ftm.role when 'finance' then 0 else 1 end
     limit 1) as finance_role
  FROM app_users u
  WHERE u.tenant_id = get_my_tenant_id()
    AND is_tenant_admin()
  ORDER BY u.email;
$$;

ALTER FUNCTION "public"."get_tenant_team_members"() OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."get_tenant_team_members"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_tenant_team_members"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tenant_team_members"() TO "service_role";

COMMENT ON FUNCTION "public"."get_tenant_team_members"() IS
  'Lists accepted members of the caller''s effective tenant with their module grants and finance role, for the Team Members Admin screen. Company/platform-admin-only -- returns zero rows for anyone else rather than erroring, since is_tenant_admin() is ANDed into the WHERE clause.';