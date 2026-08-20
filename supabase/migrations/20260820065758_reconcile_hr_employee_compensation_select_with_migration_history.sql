-- NOTE (Claude, 2026-08-20): this migration is a functional duplicate of
-- 20260820065115_fix_hr_employee_compensation_select_auth_uid_initplan.sql,
-- applied moments earlier in the same session by someone else (or another
-- assistant instance) working the same audit finding in parallel. Both
-- create the identical policy -- last-write-wins, no behavioral difference,
-- no data risk. Left in history rather than silently dropped, since
-- migrations here are meant to be append-only; flagged to Chris for
-- awareness. Safe to squash away in a future cleanup pass if desired.

DROP POLICY IF EXISTS "hr_employee_compensation_select" ON "public"."hr_employee_compensation";

CREATE POLICY "hr_employee_compensation_select" ON "public"."hr_employee_compensation"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND (
      "public"."is_hr_team_member"()
      OR (EXISTS (
        SELECT 1 FROM "public"."hr_employees" "e"
        WHERE "e"."id" = "hr_employee_compensation"."employee_id"
          AND "e"."user_id" = (select "auth"."uid"())
      ))
    )
  );