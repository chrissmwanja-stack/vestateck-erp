-- organizations and requests each had two SELECT policies granting access
-- via genuinely different, non-overlapping conditions (finance-team vs.
-- PO-access; own-request vs. actionable-via-PO-access). Both conditions
-- are logically needed (OR'd), but having them as two separate permissive
-- policies makes Postgres plan and evaluate two policies per query instead
-- of one. Merging into a single OR'd condition is logically identical --
-- permissive policies are OR'd together regardless -- just evaluated once.

DROP POLICY organizations_select ON public.organizations;
DROP POLICY organizations_select_po_access ON public.organizations;
CREATE POLICY organizations_select ON public.organizations
  FOR SELECT
  USING (
    (tenant_id = get_my_tenant_id())
    AND (is_finance_team_member(NULL::text) OR has_po_access())
  );

DROP POLICY requests_select_own_or_actionable ON public.requests;
DROP POLICY requests_select_po_access ON public.requests;
CREATE POLICY requests_select_own_or_actionable ON public.requests
  FOR SELECT
  USING (
    (tenant_id = get_my_tenant_id())
    AND (
      (requester_id = (select auth.uid()))
      OR can_act_on_stage(current_stage_id)
      OR has_po_access()
    )
  );
