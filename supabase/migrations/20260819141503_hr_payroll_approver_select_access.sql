-- Payroll approvers (payroll_approvers table) are a distinct role from HR team
-- members, by design, to support separation of duties (the person who prepares
-- payroll should not necessarily be the same person who approves it). The
-- PayrollApprovals.tsx screen queries hr_payroll_runs and hr_payroll_items
-- directly and gates on is_payroll_approver(), but the SELECT policies on
-- those two tables only granted access to is_hr_team_member(). A payroll
-- approver who is not also an HR team member would therefore see zero rows
-- and be unable to review runs pending their approval. This migration adds
-- is_payroll_approver() as an additional allowed path on both tables.
-- (hr_employee_compensation is left untouched: no screen requires approvers
-- to see compensation history, only HR team members and the employee
-- themselves.)

DROP POLICY IF EXISTS "hr_payroll_runs_select" ON "public"."hr_payroll_runs";
CREATE POLICY "hr_payroll_runs_select" ON "public"."hr_payroll_runs"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND ("public"."is_hr_team_member"() OR "public"."is_payroll_approver"())
  );

DROP POLICY IF EXISTS "hr_payroll_items_select" ON "public"."hr_payroll_items";
CREATE POLICY "hr_payroll_items_select" ON "public"."hr_payroll_items"
  FOR SELECT USING (
    (EXISTS (
      SELECT 1 FROM "public"."hr_payroll_runs" "pr"
      WHERE "pr"."id" = "hr_payroll_items"."payroll_run_id"
        AND "pr"."tenant_id" = "public"."get_my_tenant_id"()
    ))
    AND (
      "public"."is_hr_team_member"()
      OR "public"."is_payroll_approver"()
      OR (EXISTS (
        SELECT 1 FROM "public"."hr_employees" "e"
        WHERE "e"."id" = "hr_payroll_items"."employee_id"
          AND "e"."user_id" = (select "auth"."uid"())
      ))
    )
  );