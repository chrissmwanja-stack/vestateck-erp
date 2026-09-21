-- Close the two remaining broad-read gaps on HR tables, and fix the one
-- live functional bug found by a full RLS/screen cross-audit
-- (2026-09-21, done against every frontend .from('<table>').<verb>() call
-- vs. every effective post-replay policy):
--
-- 1. hr_job_applications_select was baseline tenant-scoped only
--    (USING (tenant_id = get_my_tenant_id())). Candidate name/email/phone --
--    recruitment PII on people who are *not even employees* -- was readable
--    by every authenticated user in a tenant, including modules with no
--    business near hiring (machine operators, sustainability, IT members,
--    ...). The only screen that touches this table is HR's own
--    ApplicationsList.tsx, which routes behind RequireModule module="hr".
--    Tighten to HR module membership (the same admin/manager/member tier
--    RequireModule enforces client-side) so DB access matches route access.
--    Writes were already admin/manager-gated; unchanged.
--
-- 2. hr_trainings_select was also baseline tenant-scoped only, readable
--    tenant-wide. Tighten to HR module membership. (Note for later:
--    hr_trainings is a course catalog -- title/provider/dates with no
--    employee_id anywhere in the schema, so unlike appraisals/attendance/
--    leave there is no per-employee row to self-gate on. If/when the schema
--    grows per-employee training records, those rows should follow the
--    self-view pattern those three tables already use.)
--
-- 3. hr_attendance had SELECT/INSERT/UPDATE policies but never a DELETE
--    policy. AttendanceList.tsx issues a direct .delete() from the edit
--    dialog, so the Delete button has been an RLS-denied no-op in
--    production since the screen shipped (confirmed the only such
--    write-without-policy mismatch across all 219 screens). Add the missing
--    verb, gated identically to hr_attendance_update (admin/manager only).
--
-- Not addressed here, deliberately:
--   * hr_employees / hr_job_postings / hr_positions / hr_leave_types keep
--    tenant-scoped SELECT: hr_employees carries no bank/TIN-style columns
--    (verified column list 2026-09-21) and is consumed cross-module as the
--    people directory (org chart, approver/assignee pickers, PMO resource
--    screens); postings/positions/leave-types are internal lookup/lists.
--    Compensation, appraisal, attendance and leave *records* are the
--    sensitive per-employee data, and all four are role- or self-gated.
--   * hr_team_members / payroll_approvers keep tenant-scoped SELECT
--    (membership lists are needed to render admin screens; the *write*
--    path is the sensitive part and is SECURITY DEFINER RPC-only since
--    20260821090000_hr_team_and_payroll_approver_admin_rpcs.sql).

-- 1. hr_job_applications: HR members only
DROP POLICY IF EXISTS "hr_job_applications_select" ON "public"."hr_job_applications";
CREATE POLICY "hr_job_applications_select" ON "public"."hr_job_applications"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- 2. hr_trainings: HR module members only (no self-view clause -- the
--    table has no employee_id column to correlate a user to a row)
DROP POLICY IF EXISTS "hr_trainings_select" ON "public"."hr_trainings";
CREATE POLICY "hr_trainings_select" ON "public"."hr_trainings"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- 3. hr_attendance: add the missing DELETE verb, same gate as UPDATE
CREATE POLICY "hr_attendance_delete" ON "public"."hr_attendance"
  FOR DELETE USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])
  );
