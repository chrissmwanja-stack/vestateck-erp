-- DB-level counterpart to BD_ADMIN_ROLES (modules/portals/business-
-- development/access.ts, App.tsx), same shape as
-- 20260820120000_it_support_admin_tier_write_rpcs.sql for IT support.
--
-- is_business_dev() is flat -- admin/manager/member all pass -- and the
-- seven BD lookup-table admin screens (LeadSourcesAdmin,
-- ClientCategoriesAdmin, LeadStatusesAdmin, OpportunityStagesAdmin,
-- ProposalTypesAdmin, ProposalStatusesAdmin, TenderTypesAdmin) write
-- straight to their tables via the Supabase client -- there's no RPC
-- layer to gate the way IT support's admin screens have. So even
-- though the frontend route now hides these screens from plain "bd"
-- members, RLS alone would still let a member INSERT/UPDATE/DELETE
-- rows in any of the seven tables directly.
--
-- SELECT stays on the flat is_business_dev() check on all seven tables
-- -- ordinary data-entry screens every BD member needs (NewLead,
-- NewOpportunity, NewTender, NewProposal, etc.) read these tables to
-- populate dropdowns, confirmed via a grep across
-- modules/portals/business-development/pages -- only the admin screens
-- ever call .insert/.update/.delete on them.
--
-- bd_proposals (the actual proposal-approval decision, made via a
-- plain .update({status: decision}) in ProposalApprovals.tsx) is
-- deliberately NOT touched here: bd_proposals_write_update also covers
-- ordinary proposal editing by any BD member (drafting, revising a
-- proposal in progress), which is legitimate default-tier work. RLS
-- can't tell "member editing their own draft" apart from "member
-- approving someone else's proposal" on the same UPDATE policy --
-- tightening it wholesale would break normal proposal editing for
-- every BD member, not just close the approval gap. Closing that one
-- properly needs a dedicated decide_bd_proposal() SECURITY DEFINER RPC
-- (mirroring IT's record_ticket_approval), which is a bigger change
-- left for a follow-up migration.

CREATE OR REPLACE FUNCTION "public"."is_business_dev_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.has_module_role('bd', array['admin','manager']);
$$;

ALTER FUNCTION "public"."is_business_dev_admin"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "public"."is_business_dev_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_business_dev_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_business_dev_admin"() TO "service_role";

COMMENT ON FUNCTION "public"."is_business_dev_admin"() IS
  'Admin/manager-only counterpart to is_business_dev() (which also passes plain ''member''). Gates INSERT/UPDATE/DELETE on the seven BD lookup tables -- see BD_ADMIN_ROLES in apps/web/src/modules/portals/business-development/access.ts for the matching frontend tier. SELECT on these tables stays on is_business_dev() -- see this migration''s header comment.';

-- bd_lead_sources ---------------------------------------------------------

ALTER POLICY "bd_lead_sources_write_delete" ON "public"."bd_lead_sources"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_lead_sources_write_insert" ON "public"."bd_lead_sources"
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_lead_sources_write_update" ON "public"."bd_lead_sources"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"())
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

-- bd_client_categories ------------------------------------------------------

ALTER POLICY "bd_client_categories_write_delete" ON "public"."bd_client_categories"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_client_categories_write_insert" ON "public"."bd_client_categories"
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_client_categories_write_update" ON "public"."bd_client_categories"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"())
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

-- bd_lead_statuses ----------------------------------------------------------

ALTER POLICY "bd_lead_statuses_write_delete" ON "public"."bd_lead_statuses"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_lead_statuses_write_insert" ON "public"."bd_lead_statuses"
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_lead_statuses_write_update" ON "public"."bd_lead_statuses"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"())
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

-- bd_opportunity_stages -------------------------------------------------------

ALTER POLICY "bd_opportunity_stages_write_delete" ON "public"."bd_opportunity_stages"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_opportunity_stages_write_insert" ON "public"."bd_opportunity_stages"
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_opportunity_stages_write_update" ON "public"."bd_opportunity_stages"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"())
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

-- bd_proposal_types -----------------------------------------------------------

ALTER POLICY "bd_proposal_types_write_delete" ON "public"."bd_proposal_types"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_proposal_types_write_insert" ON "public"."bd_proposal_types"
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_proposal_types_write_update" ON "public"."bd_proposal_types"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"())
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

-- bd_proposal_statuses ---------------------------------------------------------

ALTER POLICY "bd_proposal_statuses_write_delete" ON "public"."bd_proposal_statuses"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_proposal_statuses_write_insert" ON "public"."bd_proposal_statuses"
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_proposal_statuses_write_update" ON "public"."bd_proposal_statuses"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"())
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

-- bd_tender_types -----------------------------------------------------------

ALTER POLICY "bd_tender_types_write_delete" ON "public"."bd_tender_types"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_tender_types_write_insert" ON "public"."bd_tender_types"
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());

ALTER POLICY "bd_tender_types_write_update" ON "public"."bd_tender_types"
  USING (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"())
  WITH CHECK (("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev_admin"());
