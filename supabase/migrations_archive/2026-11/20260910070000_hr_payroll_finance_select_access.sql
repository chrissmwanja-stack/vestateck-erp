-- Surfaced by e2e/payroll-disbursement.spec.ts, the first thing to ever
-- exercise the Finance side of the payroll money-flow end-to-end
-- (everything else mocks supabase-js, so this RLS gap never showed up
-- before): PayrollDisbursement.tsx is gated on is_finance_team_member('finance')
-- and queries hr_payroll_runs/hr_payroll_items directly, same shape as
-- PayrollApprovals.tsx (20260819141503_hr_payroll_approver_select_access.sql).
-- That migration added is_payroll_approver() as an allowed path on both
-- SELECT policies, but never anticipated a third constituency needing
-- access for a different reason: HR prepares and approves, an approver
-- signs off, and *Finance* -- who is neither -- has to see the approved
-- run to release payment. finance@test.local could open the Payroll
-- Disbursement screen (the frontend's own gate passed) but every query
-- against hr_payroll_runs/hr_payroll_items returned zero rows, so no
-- approved run ever appeared to disburse.
--
-- Scoped to the 'finance' role specifically (not NULL/any finance team
-- role) to match exactly what PayrollDisbursement.tsx's own gate checks --
-- a cost_control finance_team_members row shouldn't gain payroll
-- visibility as a side effect of this fix.

DROP POLICY IF EXISTS "hr_payroll_runs_select" ON "public"."hr_payroll_runs";
CREATE POLICY "hr_payroll_runs_select" ON "public"."hr_payroll_runs"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND (
      "public"."is_hr_team_member"()
      OR "public"."is_payroll_approver"()
      OR "public"."is_finance_team_member"('finance')
    )
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
      OR "public"."is_finance_team_member"('finance')
      OR (EXISTS (
        SELECT 1 FROM "public"."hr_employees" "e"
        WHERE "e"."id" = "hr_payroll_items"."employee_id"
          AND "e"."user_id" = (select "auth"."uid"())
      ))
    )
  );
