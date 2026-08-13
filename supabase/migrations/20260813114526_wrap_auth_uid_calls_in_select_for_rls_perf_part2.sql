-- Performance fix: wrap bare auth.uid() calls in (select auth.uid()) across
-- the 5 advisor-flagged policies added after the Aug 8 batch fix
-- (wrap_auth_uid_calls_in_select_for_rls_perf). Same rationale -- Postgres
-- caches a scalar subquery's result once per statement instead of
-- re-evaluating auth.uid() per row. Pure syntactic change; logic identical.

ALTER POLICY pmo_tasks_write ON public.pmo_tasks
USING (
  ((tenant_id = get_my_tenant_id()) AND (has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = (select auth.uid()))))
);

ALTER POLICY hr_appraisals_select ON public.hr_appraisals
USING (
  ((tenant_id = get_my_tenant_id()) AND (has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM hr_employees e
  WHERE ((e.id = hr_appraisals.employee_id) AND (e.user_id = (select auth.uid())))))))
);

ALTER POLICY invitations_select_tenant_admin ON public.invitations
USING (
  ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM staff_roles
  WHERE ((staff_roles.user_id = (select auth.uid())) AND (staff_roles.tenant_id = invitations.tenant_id) AND (staff_roles.role = 'admin'::text)))))
);

ALTER POLICY invitations_insert_tenant_admin ON public.invitations
WITH CHECK (
  ((role_bundle = 'member'::text) AND (tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM staff_roles
  WHERE ((staff_roles.user_id = (select auth.uid())) AND (staff_roles.tenant_id = invitations.tenant_id) AND (staff_roles.role = 'admin'::text)))))
);

ALTER POLICY impersonation_sessions_select_own ON public.impersonation_sessions
USING (
  (platform_admin_id = (select auth.uid()))
);