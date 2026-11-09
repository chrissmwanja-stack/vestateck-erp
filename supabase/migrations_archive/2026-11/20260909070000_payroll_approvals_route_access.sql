-- /hr/payroll/approvals is routed behind <RequireModule module="hr" />,
-- which calls has_module_role('hr', ...) -- i.e. it requires a
-- staff_roles row for the HR module. But payroll_approvers (added in
-- 20260821090000_hr_team_and_payroll_approver_admin_rpcs.sql) and the
-- is_payroll_approver()-aware RLS policies on hr_payroll_runs/
-- hr_payroll_items (20260819141503_hr_payroll_approver_select_access.sql)
-- were both built specifically so an approver does NOT have to be an HR
-- team member (separation of duties: the preparer shouldn't necessarily
-- be the approver). The route guard was never updated to match, so a
-- payroll approver who isn't also HR staff gets bounced to "Not available
-- to you" before the page -- whose own data access already works fine --
-- ever mounts. Surfaced by e2e/payroll-disbursement.spec.ts, the first
-- thing to ever click through this flow as a non-HR approver.
--
-- This function is the route-guard equivalent of the RLS fix: anyone who
-- can already see pending runs (HR team member OR payroll approver)
-- should also be able to reach the page that lists them.
CREATE OR REPLACE FUNCTION "public"."can_view_payroll_approvals"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT public.is_hr_team_member() OR public.is_payroll_approver();
$$;

ALTER FUNCTION "public"."can_view_payroll_approvals"() OWNER TO "postgres";

-- Match the REVOKE-PUBLIC-first pattern from 20260901134849_revoke_public_
-- anon_execute_admin_check_fns.sql: Postgres grants EXECUTE to PUBLIC by
-- default on CREATE FUNCTION, which anon inherits through PUBLIC unless
-- explicitly revoked.
REVOKE ALL ON FUNCTION "public"."can_view_payroll_approvals"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_view_payroll_approvals"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_view_payroll_approvals"() TO "service_role";
