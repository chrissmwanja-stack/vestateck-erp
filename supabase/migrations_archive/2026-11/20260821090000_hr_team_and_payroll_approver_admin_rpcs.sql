-- hr_team_members and payroll_approvers have had SELECT-only RLS since
-- the squashed baseline: reads are tenant-scoped, but there was never a
-- write path -- no policy, and no RPC touched either table (confirmed:
-- no frontend reference to either table name). In practice that meant
-- granting or revoking HR-team / payroll-approver status could only be
-- done by hand-editing production via the SQL editor, with no audit
-- trail and no tenant-scoping safety net.
--
-- These two tables are deliberately a *separate* authorization tier from
-- staff_roles/has_module_role('hr', ...): hr_team_members and
-- payroll_approvers gate the payroll RPCs specifically (see
-- create_payroll_run, approve_payroll_run, record_employee_compensation,
-- etc. via is_hr_team_member() / is_payroll_approver()), while
-- has_module_role('hr', [...]) gates the general HR CRUD tables
-- (employees, appraisals, leave_types, ...). So the natural admin for
-- *this* tier is the HR module admin (has_module_role('hr','admin')),
-- with the usual is_platform_admin() bootstrap already baked into
-- has_module_role() itself.
--
-- Writes go through SECURITY DEFINER RPCs only (same convention as
-- support_team_members in 20260820120000_it_support_admin_tier_write_rpcs.sql)
-- -- no INSERT/UPDATE/DELETE policy is added to either table, since the
-- RPC's internal has_module_role() check is the actual security
-- boundary and SECURITY DEFINER already bypasses RLS for these tables
-- (relforcerowsecurity is false on both, consistent with every other
-- SECURITY DEFINER write path in this schema).

CREATE OR REPLACE FUNCTION "public"."grant_hr_team_member"("p_user_id" "uuid", "p_role" "text" DEFAULT 'member') RETURNS "public"."hr_team_members"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.hr_team_members%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage the HR team';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into hr_team_members (tenant_id, user_id, role)
  values (get_my_tenant_id(), p_user_id, p_role)
  on conflict (tenant_id, user_id) do update set role = excluded.role
  returning * into v_row;

  return v_row;
end;
$$;

ALTER FUNCTION "public"."grant_hr_team_member"("uuid", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."grant_hr_team_member"("uuid", "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."grant_hr_team_member"("uuid", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."grant_hr_team_member"("uuid", "text") TO "service_role";

COMMENT ON FUNCTION "public"."grant_hr_team_member"("uuid", "text") IS
  'Adds (or updates the role of) an HR team member. HR-admin-only (has_module_role(''hr'',[''admin''])). Upserts on (tenant_id, user_id) so re-granting just changes the role rather than erroring.';

CREATE OR REPLACE FUNCTION "public"."revoke_hr_team_member"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage the HR team';
  end if;

  delete from hr_team_members
  where user_id = p_user_id and tenant_id = get_my_tenant_id();
end;
$$;

ALTER FUNCTION "public"."revoke_hr_team_member"("uuid") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."revoke_hr_team_member"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revoke_hr_team_member"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_hr_team_member"("uuid") TO "service_role";

COMMENT ON FUNCTION "public"."revoke_hr_team_member"("uuid") IS
  'Removes a user from hr_team_members. HR-admin-only. Silently no-ops if the user was not a member.';

-- Payroll approvers ----------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."grant_payroll_approver"("p_user_id" "uuid") RETURNS "public"."payroll_approvers"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into payroll_approvers (tenant_id, user_id, role, is_active)
  values (get_my_tenant_id(), p_user_id, 'approver', true)
  on conflict (tenant_id, user_id) do update set is_active = true
  returning * into v_row;

  return v_row;
end;
$$;

ALTER FUNCTION "public"."grant_payroll_approver"("uuid") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."grant_payroll_approver"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."grant_payroll_approver"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."grant_payroll_approver"("uuid") TO "service_role";

COMMENT ON FUNCTION "public"."grant_payroll_approver"("uuid") IS
  'Adds a user as an active payroll approver (or reactivates an existing, deactivated row). HR-admin-only.';

CREATE OR REPLACE FUNCTION "public"."set_payroll_approver_active"("p_user_id" "uuid", "p_is_active" boolean) RETURNS "public"."payroll_approvers"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;

  update payroll_approvers
  set is_active = p_is_active
  where user_id = p_user_id and tenant_id = get_my_tenant_id()
  returning * into v_row;

  if not found then
    raise exception 'payroll approver not found';
  end if;

  return v_row;
end;
$$;

ALTER FUNCTION "public"."set_payroll_approver_active"("uuid", boolean) OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_payroll_approver_active"("uuid", boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_payroll_approver_active"("uuid", boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_payroll_approver_active"("uuid", boolean) TO "service_role";

COMMENT ON FUNCTION "public"."set_payroll_approver_active"("uuid", boolean) IS
  'Deactivates/reactivates an existing payroll_approvers row without deleting it, preserving the audit trail (is_active is what is_payroll_approver() actually checks). HR-admin-only.';