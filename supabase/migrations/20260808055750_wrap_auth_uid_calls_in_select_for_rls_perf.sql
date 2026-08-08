-- Performance fix: wrap bare auth.uid() calls in (select auth.uid()) across
-- all 30 advisor-flagged policies. Postgres can cache a scalar subquery's
-- result once per statement instead of re-evaluating auth.uid() per row.
-- Pure syntactic change -- every condition's logic is identical, only the
-- evaluation strategy changes.

ALTER POLICY access_requests_select ON public.access_requests
USING (
  ((tenant_id = get_my_tenant_id()) AND ((requested_by = (select auth.uid())) OR is_it_support()))
);

ALTER POLICY approval_assignments_select_own ON public.approval_assignments
USING (
  (user_id = (select auth.uid()))
);

ALTER POLICY approval_delegations_insert_own ON public.approval_delegations
WITH CHECK (
  ((delegator_user_id = (select auth.uid())) AND (tenant_id = get_my_tenant_id()) AND (delegate_user_id IS DISTINCT FROM (select auth.uid())) AND (EXISTS ( SELECT 1
   FROM app_users au
  WHERE ((au.id = approval_delegations.delegate_user_id) AND (au.tenant_id = get_my_tenant_id())))) AND (((workflow_stage_id IS NULL) AND (EXISTS ( SELECT 1
   FROM approval_assignments aa
  WHERE (aa.user_id = (select auth.uid()))))) OR ((workflow_stage_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM approval_assignments aa
  WHERE ((aa.user_id = (select auth.uid())) AND (aa.workflow_stage_id = approval_delegations.workflow_stage_id)))))))
);

ALTER POLICY approval_delegations_revoke_own ON public.approval_delegations
USING (
  ((delegator_user_id = (select auth.uid())) AND (status = 'active'::text))
)
WITH CHECK (
  ((delegator_user_id = (select auth.uid())) AND (status = 'revoked'::text))
);

ALTER POLICY approval_delegations_select_involved ON public.approval_delegations
USING (
  ((delegator_user_id = (select auth.uid())) OR (delegate_user_id = (select auth.uid())))
);

ALTER POLICY asset_requests_select ON public.asset_requests
USING (
  ((tenant_id = get_my_tenant_id()) AND ((requested_by = (select auth.uid())) OR is_it_support()))
);

ALTER POLICY finance_team_members_select_own_or_admin ON public.finance_team_members
USING (
  ((user_id = (select auth.uid())) OR is_platform_admin())
);

ALTER POLICY hr_attendance_insert ON public.hr_attendance
WITH CHECK (
  ((tenant_id = get_my_tenant_id()) AND (has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM hr_employees e
  WHERE ((e.id = hr_attendance.employee_id) AND (e.user_id = (select auth.uid())))))))
);

ALTER POLICY hr_attendance_select ON public.hr_attendance
USING (
  ((tenant_id = get_my_tenant_id()) AND (has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM hr_employees e
  WHERE ((e.id = hr_attendance.employee_id) AND (e.user_id = (select auth.uid())))))))
);

ALTER POLICY hr_leave_requests_insert ON public.hr_leave_requests
WITH CHECK (
  ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM hr_employees e
  WHERE ((e.id = hr_leave_requests.employee_id) AND (e.user_id = (select auth.uid()))))))
);

ALTER POLICY hr_leave_requests_select ON public.hr_leave_requests
USING (
  ((tenant_id = get_my_tenant_id()) AND (has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM hr_employees e
  WHERE ((e.id = hr_leave_requests.employee_id) AND (e.user_id = (select auth.uid())))))))
);

ALTER POLICY hr_leave_requests_update ON public.hr_leave_requests
USING (
  ((tenant_id = get_my_tenant_id()) AND (has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR ((status = 'pending'::text) AND (EXISTS ( SELECT 1
   FROM hr_employees e
  WHERE ((e.id = hr_leave_requests.employee_id) AND (e.user_id = (select auth.uid()))))))))
);

ALTER POLICY invoice_requests_insert_own ON public.invoice_requests
WITH CHECK (
  ((requester_id = (select auth.uid())) AND (tenant_id = get_my_tenant_id()))
);

ALTER POLICY invoice_requests_select_own_or_actionable ON public.invoice_requests
USING (
  ((tenant_id = get_my_tenant_id()) AND ((requester_id = (select auth.uid())) OR can_act_on_stage(current_stage_id)))
);

ALTER POLICY it_tickets_insert ON public.it_tickets
WITH CHECK (
  ((tenant_id = get_my_tenant_id()) AND (requester_id = (select auth.uid())))
);

ALTER POLICY it_tickets_select ON public.it_tickets
USING (
  ((tenant_id = get_my_tenant_id()) AND ((requester_id = (select auth.uid())) OR (assignee_id = (select auth.uid())) OR is_it_support()))
);

ALTER POLICY law_compliance_update ON public.law_compliance_register
USING (
  ((tenant_id = get_my_tenant_id()) AND (has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]) OR (owner_id = (select auth.uid()))))
);

ALTER POLICY material_request_batches_insert ON public.material_request_batches
WITH CHECK (
  ((tenant_id = get_my_tenant_id()) AND (requester_id = (select auth.uid())))
);

ALTER POLICY material_request_batches_select ON public.material_request_batches
USING (
  ((tenant_id = get_my_tenant_id()) AND ((requester_id = (select auth.uid())) OR has_po_access()))
);

ALTER POLICY material_request_items_insert ON public.material_request_items
WITH CHECK (
  ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM material_request_batches b
  WHERE ((b.id = material_request_items.batch_id) AND (b.requester_id = (select auth.uid()))))))
);

ALTER POLICY material_request_items_select ON public.material_request_items
USING (
  ((tenant_id = get_my_tenant_id()) AND (has_po_access() OR (EXISTS ( SELECT 1
   FROM material_request_batches b
  WHERE ((b.id = material_request_items.batch_id) AND (b.requester_id = (select auth.uid())))))))
);

ALTER POLICY notifications_mark_read_own ON public.notifications
USING (
  (recipient_id = (select auth.uid()))
)
WITH CHECK (
  (recipient_id = (select auth.uid()))
);

ALTER POLICY notifications_select_own ON public.notifications
USING (
  (recipient_id = (select auth.uid()))
);

ALTER POLICY request_line_items_insert ON public.request_line_items
WITH CHECK (
  (EXISTS ( SELECT 1
   FROM requests r
  WHERE ((r.id = request_line_items.request_id) AND (r.requester_id = (select auth.uid())))))
);

ALTER POLICY request_offers_insert_authorized ON public.request_offers
WITH CHECK (
  ((submitted_by = (select auth.uid())) AND (EXISTS ( SELECT 1
   FROM (requests r
     JOIN workflow_stages ws ON ((ws.id = r.current_stage_id)))
  WHERE ((r.id = request_offers.request_id) AND (r.tenant_id = get_my_tenant_id()) AND (r.status = 'open'::text) AND ws.requires_offer_entry AND can_act_on_stage(r.current_stage_id)))))
);

ALTER POLICY request_offers_select_via_request ON public.request_offers
USING (
  (EXISTS ( SELECT 1
   FROM requests r
  WHERE ((r.id = request_offers.request_id) AND (r.tenant_id = get_my_tenant_id()) AND ((r.requester_id = (select auth.uid())) OR can_act_on_stage(r.current_stage_id)))))
);

ALTER POLICY requests_insert_own ON public.requests
WITH CHECK (
  ((requester_id = (select auth.uid())) AND (tenant_id = get_my_tenant_id()))
);

ALTER POLICY requests_select_own_or_actionable ON public.requests
USING (
  ((tenant_id = get_my_tenant_id()) AND ((requester_id = (select auth.uid())) OR can_act_on_stage(current_stage_id)))
);

ALTER POLICY sap_payments_select_tenant ON public.sap_payments
USING (
  (tenant_id = ( SELECT app_users.tenant_id
   FROM app_users
  WHERE (app_users.id = (select auth.uid()))))
);

ALTER POLICY platform_admin_write_staff_roles ON public.staff_roles
USING (
  ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM app_users
  WHERE ((app_users.id = (select auth.uid())) AND app_users.is_platform_admin))))
);
