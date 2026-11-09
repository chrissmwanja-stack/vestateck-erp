-- "My Approvals" cross-module surface.
--
-- Follow-up to 20260909070000_payroll_approvals_route_access.sql: fixing
-- the payroll route guard surfaced a broader problem. Every approval
-- screen's *nav entry* lives under one module's tree (Human Resources,
-- Business Development, ...), gated the same way the section itself is
-- gated. That's fine when "who can approve X" lines up with "who's in
-- module X" -- but payroll_approvers was deliberately built so it
-- doesn't (separation of duties: an approver need not be HR staff), and
-- the nav had no way to express that. A designated approver sitting
-- outside a module has no path to that module's approval screen short of
-- typing the URL.
--
-- list_my_approval_surfaces() is a single place that answers "which
-- approval screens can I act on right now, and how many items are
-- waiting" for the current user, independent of which module's nav tree
-- they're standing in. Each row's `visible` predicate mirrors that
-- route's actual guard in App.tsx exactly (same RPC/role-check), so this
-- can never show a link the route guard would then reject, and adding a
-- future approval surface is one more branch here plus one call site in
-- the frontend -- not a new nav entry per portal.
--
-- pending_count is NULL where no confidently-accurate count is available
-- (e.g. SAP payment recording isn't a simple status-count) -- the
-- frontend should render those as a plain link with no badge, not "0".
CREATE OR REPLACE FUNCTION "public"."list_my_approval_surfaces"()
RETURNS TABLE(surface_key text, label text, route text, pending_count integer)
LANGUAGE "sql" STABLE SECURITY DEFINER
SET "search_path" TO 'public', 'pg_temp'
AS $$
  WITH my_assignment AS (
    -- Same "am I on the hook for something in the generic workflow
    -- engine" signal get_my_approval_queue()/get_my_invoice_approval_queue()
    -- rely on: a direct approval_assignments row, or an active delegation
    -- from someone who has one. Backs both the Request/Offer queue and
    -- the Invoice queue, since both draw candidate items via the same
    -- workflow_stage_id -> approval_assignments join, just against
    -- different base tables (requests vs invoice_requests).
    SELECT EXISTS (
      SELECT 1 FROM approval_assignments WHERE user_id = auth.uid()
      UNION ALL
      SELECT 1 FROM approval_delegations d
      JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
      WHERE d.delegate_user_id = auth.uid()
        AND d.status = 'active'
        AND now() BETWEEN d.starts_at AND d.ends_at
        AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = aa.workflow_stage_id)
    ) AS is_assigned
  )
  SELECT 'request_approvals', 'Approval Queue', '/approvals',
         (SELECT count(*)::int FROM get_my_approval_queue())
  WHERE (SELECT is_assigned FROM my_assignment)
  UNION ALL
  SELECT 'invoice_approvals', 'Invoice Approval Queue', '/multiplexing/approvals',
         (SELECT count(*)::int FROM get_my_invoice_approval_queue())
  WHERE (SELECT is_assigned FROM my_assignment)
  UNION ALL
  SELECT 'material_request_approvals', 'Material Request Approvals', '/approvals/material-requests',
         (SELECT coalesce(sum(pending_item_count), 0)::int FROM get_pending_material_request_batches())
  WHERE public.am_i_finance()
  UNION ALL
  SELECT 'sap_payment_recording', 'SAP Payment Recording', '/sap/payment-approvals', NULL
  WHERE public.can_access_finance()
  UNION ALL
  SELECT 'ticket_approvals', 'IT Ticket Approvals', '/it-support/approvals',
         (SELECT count(*)::int FROM it_tickets
          WHERE tenant_id = get_my_tenant_id() AND approval_status = 'pending')
  WHERE public.has_module_role('it', ARRAY['admin','manager'])
  UNION ALL
  SELECT 'proposal_approvals', 'Proposal Approvals', '/business-development/proposals/approvals',
         (SELECT count(*)::int FROM bd_proposals
          WHERE tenant_id = get_my_tenant_id() AND status IN ('pending_approval','in_review'))
  WHERE public.has_module_role('bd', ARRAY['admin','manager'])
  UNION ALL
  SELECT 'contract_approvals', 'Contract Approvals', '/law-compliance/contracts/approvals',
         (SELECT count(*)::int FROM law_contracts
          WHERE tenant_id = get_my_tenant_id() AND status IN ('pending_approval','draft'))
  WHERE public.has_module_role('legal', ARRAY['admin','manager','member'])
  UNION ALL
  SELECT 'leave_approvals', 'Leave Approvals', '/hr/leaves/approvals',
         (SELECT count(*)::int FROM hr_leave_requests
          WHERE tenant_id = get_my_tenant_id() AND status = 'pending')
  WHERE public.has_module_role('hr', ARRAY['admin','manager','member'])
  UNION ALL
  SELECT 'payroll_approvals', 'Payroll Approvals', '/hr/payroll/approvals',
         (SELECT count(*)::int FROM hr_payroll_runs
          WHERE tenant_id = get_my_tenant_id() AND status = 'pending_approval')
  WHERE public.can_view_payroll_approvals();
$$;

ALTER FUNCTION "public"."list_my_approval_surfaces"() OWNER TO "postgres";

-- Same REVOKE-PUBLIC-first pattern as every other check/queue RPC in
-- this project (20260901134849_revoke_public_anon_execute_admin_check_fns.sql,
-- can_view_payroll_approvals() above).
REVOKE ALL ON FUNCTION "public"."list_my_approval_surfaces"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_my_approval_surfaces"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_my_approval_surfaces"() TO "service_role";
