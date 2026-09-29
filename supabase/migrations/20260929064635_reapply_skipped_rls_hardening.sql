-- Reapply RLS/trigger hardening that was recorded as applied but never took
-- effect in production (verified against live xownbroirovedkmqyybc on
-- 2026-09-29).
--
-- Cause: the Supabase CLI keys on schema_migrations.version, so a migration
-- file edited after its version was recorded is never re-run (same failure
-- mode documented in 20260928120100_reapply_announcement_dismissal_policies).
-- Live state before this migration:
--   * 22 Law/PMO/Machine/Sustainability SELECT policies still bare tenant_id
--   * prevent_journal_mutation / prevent_posted_invoice_update /
--     void_journal_entry and their triggers do not exist
--   * IT Support SELECT gates, law_contracts direct-update guard, posted-cost
--     locks missing
--   * hr_job_applications/hr_trainings SELECT ungated, hr_attendance_delete absent
--   * BD lookup-table write policies still on flat is_business_dev()
--   * tenant_read_only_guard not attached to ~10 newer tenant tables
--
-- Every statement below is idempotent (drop-if-exists + create, create or
-- replace, ALTER POLICY). Bodies are copied verbatim from the original
-- migrations, except: apply_tenant_read_only_guard() is NOT re-granted to
-- authenticated (20260928120000 locked internal definer helpers down).


-- ===== from 20260820130000_bd_admin_tier_lookup_table_rls =====
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

-- ===== from 20260921090000_hr_select_tightening_and_attendance_delete =====
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
DROP POLICY IF EXISTS "hr_attendance_delete" ON "public"."hr_attendance";
CREATE POLICY "hr_attendance_delete" ON "public"."hr_attendance"
  FOR DELETE USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])
  );

-- ===== from 20260921093000_young_module_select_tightening =====
-- Schema-wide select-policy sweep for the four newest modules (part of the
-- 2026-09-21 RLS audit): Law & Compliance, PMO, Machine Operation,
-- Sustainability. Every table below already had:
--   * RLS enabled (verified: all 131 tables, none naked)
--   * tenant isolation on SELECT: USING (tenant_id = get_my_tenant_id())
--   * module-role gates on INSERT/UPDATE/DELETE (admin/manager tier)
-- What none of them had was a *module* gate on SELECT -- so any
-- authenticated user in a tenant could read every other module's rows via
-- the REST API even though the routes themselves sit behind RequireModule
-- guards. Route guards are UX; this closes the API-side hole with the same
-- boundary the UI enforces: has_module_role('<module>', admin/manager/
-- member). Platform admins keep visibility through the bootstrap already
-- baked into has_module_role(); the tenant-modules entitlement check is
-- likewise inherited from it.
--
-- Verified safe against the frontend before tightening (grep of every
-- .from('<table>') call across apps/web/src): each of these tables is read
-- exclusively by screens inside its own module's RequireModule-gated
-- shell. No cross-module reader loses access.
--
-- One deliberate exception kept: pmo_tasks additionally allows
-- assignee_id = (select auth.uid()) on SELECT, mirroring the existing
-- INSERT exception -- a task can be assigned to a user who holds no pmo
-- staff_roles row, and that assignee must still be able to open their own
-- task. All other rows stay module-scoped.
--
-- Lookup tables (types/categories) are tightened together with their data
-- tables: they hold tenant-configured vocabulary for the module and there
-- is no screen outside the module that needs them.

-- =========================== LAW & COMPLIANCE ===========================

DROP POLICY IF EXISTS "law_cases_select" ON "public"."law_cases";
CREATE POLICY "law_cases_select" ON "public"."law_cases"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "law_hearings_select" ON "public"."law_case_hearings";
CREATE POLICY "law_hearings_select" ON "public"."law_case_hearings"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "law_case_types_select" ON "public"."law_case_types";
CREATE POLICY "law_case_types_select" ON "public"."law_case_types"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "law_contracts_select" ON "public"."law_contracts";
CREATE POLICY "law_contracts_select" ON "public"."law_contracts"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "law_contract_types_select" ON "public"."law_contract_types";
CREATE POLICY "law_contract_types_select" ON "public"."law_contract_types"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "law_compliance_select" ON "public"."law_compliance_register";
CREATE POLICY "law_compliance_select" ON "public"."law_compliance_register"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "law_filings_select" ON "public"."law_regulatory_filings";
CREATE POLICY "law_filings_select" ON "public"."law_regulatory_filings"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- ================================ PMO =================================

DROP POLICY IF EXISTS "pmo_projects_select" ON "public"."pmo_projects";
CREATE POLICY "pmo_projects_select" ON "public"."pmo_projects"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "pmo_project_categories_select" ON "public"."pmo_project_categories";
CREATE POLICY "pmo_project_categories_select" ON "public"."pmo_project_categories"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "pmo_tasks_select" ON "public"."pmo_tasks";
CREATE POLICY "pmo_tasks_select" ON "public"."pmo_tasks"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND (
      "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
      OR ("assignee_id" = (select "auth"."uid"()))
    )
  );

DROP POLICY IF EXISTS "pmo_task_types_select" ON "public"."pmo_task_types";
CREATE POLICY "pmo_task_types_select" ON "public"."pmo_task_types"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "pmo_milestones_select" ON "public"."pmo_milestones";
CREATE POLICY "pmo_milestones_select" ON "public"."pmo_milestones"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "pmo_resource_allocations_select" ON "public"."pmo_resource_allocations";
CREATE POLICY "pmo_resource_allocations_select" ON "public"."pmo_resource_allocations"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "pmo_task_dependencies_select" ON "public"."pmo_task_dependencies";
CREATE POLICY "pmo_task_dependencies_select" ON "public"."pmo_task_dependencies"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- ========================== MACHINE OPERATION =========================

DROP POLICY IF EXISTS "machines_select" ON "public"."machines";
CREATE POLICY "machines_select" ON "public"."machines"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "machine_types_select" ON "public"."machine_types";
CREATE POLICY "machine_types_select" ON "public"."machine_types"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "machine_assignments_select" ON "public"."machine_assignments";
CREATE POLICY "machine_assignments_select" ON "public"."machine_assignments"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "maintenance_requests_select" ON "public"."maintenance_requests";
CREATE POLICY "maintenance_requests_select" ON "public"."maintenance_requests"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "maintenance_types_select" ON "public"."maintenance_types";
CREATE POLICY "maintenance_types_select" ON "public"."maintenance_types"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "fuel_logs_select" ON "public"."fuel_logs";
CREATE POLICY "fuel_logs_select" ON "public"."fuel_logs"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- ============================ SUSTAINABILITY ==========================

DROP POLICY IF EXISTS "sustain_metrics_select" ON "public"."sustainability_metrics";
CREATE POLICY "sustain_metrics_select" ON "public"."sustainability_metrics"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "sustain_metric_types_select" ON "public"."sustainability_metric_types";
CREATE POLICY "sustain_metric_types_select" ON "public"."sustainability_metric_types"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "sustain_initiatives_select" ON "public"."sustainability_initiatives";
CREATE POLICY "sustain_initiatives_select" ON "public"."sustainability_initiatives"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "sustain_init_cat_select" ON "public"."sustainability_initiative_categories";
CREATE POLICY "sustain_init_cat_select" ON "public"."sustainability_initiative_categories"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "sustain_audits_select" ON "public"."sustainability_audits";
CREATE POLICY "sustain_audits_select" ON "public"."sustainability_audits"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

DROP POLICY IF EXISTS "sustain_certs_select" ON "public"."sustainability_certifications";
CREATE POLICY "sustain_certs_select" ON "public"."sustainability_certifications"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- ===== from 20260925130000_harden_tenant_readonly_and_reapply_guard =====
-- Harden tenant read_only enforcement
-- Addresses forensic item 1: new tables after 20260922 lacked guard, invitations exempt

-- Re-define apply function with tighter exempt list
-- Previous exempt: platform_audit_events, impersonation_sessions, impersonation_logs,
-- tenant_notes, notifications, invitations, app_users
-- New exempt: platform_audit_events, impersonation_sessions, impersonation_logs,
-- tenant_notes, notifications, app_users
-- (invitations REMOVED — ordinary company admin inviting during read_only should be blocked;
--  service_role (edge functions) already bypasses via platform_request_role() check, and
--  platform_admin bypasses via is_platform_admin() check, so operator can still invite if needed)

create or replace function public.apply_tenant_read_only_guard()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname not in (
        'platform_audit_events', 'impersonation_sessions', 'impersonation_logs', 'tenant_notes',
        'notifications',
        'app_users',
        'platform_digests',
        'platform_job_runs'
      )
  loop
    execute format('drop trigger if exists tenant_read_only_guard on public.%I', r.relname);
    execute format(
      'create trigger tenant_read_only_guard before insert or update or delete on public.%I '
      'for each row execute function public.tenant_read_only_guard()',
      r.relname
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.apply_tenant_read_only_guard() from public;

-- Re-apply to all current tenant_id tables
select public.apply_tenant_read_only_guard();

comment on function public.apply_tenant_read_only_guard() is
  'Attaches tenant_read_only_guard trigger to every public table with tenant_id except platform/audit tables and notifications/app_users. Re-run after adding new tenant-scoped tables. Invitations is intentionally NOT exempt — read_only should block ordinary invites; service_role and platform_admin bypass via guard itself.';

-- ===== from 20260925131000_harden_journal_entries_immutability =====
-- Harden financial immutability — item 4
-- Journal entries are append-only from client perspective (RLS has only SELECT policy),
-- but service_role/owner could still UPDATE/DELETE. Add trigger-level immutability.
-- Also prevent subledger amount mutation after posting.

-- 1. Immutable journal_entries and journal_entry_lines for every role
create or replace function public.prevent_journal_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Allow INSERT via post_journal_entry() only; block UPDATE/DELETE for everyone
  -- including table owner. Voiding must go through void_journal_entry() RPC which
  -- inserts reversal and marks original as void via SECURITY DEFINER bypass of this trigger? 
  -- Actually this trigger blocks even that — so void_journal_entry will need to be
  -- SECURITY DEFINER and temporarily disable trigger or use a flag.
  -- For now, block all UPDATE/DELETE unconditionally — reversal pattern to be added in follow-up.
  -- Exception: allow status change from posted -> void only via void_journal_entry() which sets a session variable.
  if tg_op = 'UPDATE' then
    -- Allow only status transition posted->void when session variable allows it
    if old.status = 'posted' and new.status = 'void' and current_setting('app.allow_journal_void', true) = 'true' then
      return new;
    end if;
    raise exception 'JOURNAL_IMMUTABLE: journal entries are immutable, create a reversal entry instead (attempted % on %)', tg_op, old.id
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'JOURNAL_IMMUTABLE: journal entries cannot be deleted (attempted delete on %)', old.id
      using errcode = 'restrict_violation';
  end if;
  return null;
end;
$$;

revoke execute on function public.prevent_journal_mutation() from public;

drop trigger if exists no_update_journal_entries on public.journal_entries;
create trigger no_update_journal_entries
  before update or delete on public.journal_entries
  for each row execute function public.prevent_journal_mutation();

drop trigger if exists no_update_journal_entry_lines on public.journal_entry_lines;
create trigger no_update_journal_entry_lines
  before update or delete on public.journal_entry_lines
  for each row execute function public.prevent_journal_mutation();

-- 2. Prevent subledger amount mutation after journal posted
create or replace function public.prevent_posted_invoice_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_journal boolean;
begin
  if tg_op = 'UPDATE' then
    -- Only care about amount field changes
    if tg_table_name = 'supplier_invoices' then
      if new.amount_incl_vat is distinct from old.amount_incl_vat
         or new.vat_amount is distinct from old.vat_amount
         or new.wht_amount is distinct from old.wht_amount then
        select exists(select 1 from journal_entries where source_type='supplier_invoice' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_INVOICE_IMMUTABLE: cannot change amount of posted supplier invoice % — create a credit note reversal', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'receivable_invoices' then
      if new.amount_incl_vat is distinct from old.amount_incl_vat
         or new.vat_amount is distinct from old.vat_amount then
        select exists(select 1 from journal_entries where source_type='receivable_invoice' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_INVOICE_IMMUTABLE: cannot change amount of posted receivable invoice %', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'cash_bank_transactions' then
      if new.amount is distinct from old.amount then
        select exists(select 1 from journal_entries where source_type='cash_bank_transaction' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_TRANSACTION_IMMUTABLE: cannot change amount of posted cash/bank transaction %', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.prevent_posted_invoice_update() from public;

drop trigger if exists trg_prevent_posted_supplier_invoice_update on public.supplier_invoices;
create trigger trg_prevent_posted_supplier_invoice_update
  before update on public.supplier_invoices
  for each row execute function public.prevent_posted_invoice_update();

drop trigger if exists trg_prevent_posted_receivable_invoice_update on public.receivable_invoices;
create trigger trg_prevent_posted_receivable_invoice_update
  before update on public.receivable_invoices
  for each row execute function public.prevent_posted_invoice_update();

drop trigger if exists trg_prevent_posted_cash_bank_update on public.cash_bank_transactions;
create trigger trg_prevent_posted_cash_bank_update
  before update on public.cash_bank_transactions
  for each row execute function public.prevent_posted_invoice_update();

-- 3. Void RPC with reversal (proper pattern)
create or replace function public.void_journal_entry(p_entry_id uuid, p_reason text)
returns public.journal_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry journal_entries%rowtype;
  v_reversal journal_entries%rowtype;
  v_lines jsonb;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'A reason (at least 5 characters) is required to void a journal entry';
  end if;

  if not is_finance_team_member('finance') then
    raise exception 'not authorized to void journal entries';
  end if;

  select * into v_entry from journal_entries where id = p_entry_id for update;
  if not found then
    raise exception 'journal entry not found';
  end if;
  if v_entry.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this journal entry';
  end if;
  if v_entry.status = 'void' then
    return v_entry;
  end if;

  -- Check closed period for reversal date (today)
  if exists (
    select 1 from accounting_periods
    where tenant_id = v_entry.tenant_id
      and status = 'closed'
      and current_date between period_start and period_end
  ) then
    raise exception 'cannot void in closed period - current date % is in closed period', current_date;
  end if;

  -- Build reversal lines (swap debit/credit)
  select jsonb_agg(
    jsonb_build_object(
      'gl_account_id', jel.gl_account_id,
      'debit', jel.credit,
      'credit', jel.debit,
      'description', 'Reversal of ' || v_entry.id::text || ': ' || coalesce(jel.description, '')
    )
  ) into v_lines
  from journal_entry_lines jel
  where jel.journal_entry_id = v_entry.id;

  -- Allow status update via session variable
  perform set_config('app.allow_journal_void', 'true', true);
  update journal_entries set status = 'void' where id = p_entry_id returning * into v_entry;
  perform set_config('app.allow_journal_void', 'false', true);

  -- Post reversal
  select * into v_reversal from post_journal_entry(
    v_entry.tenant_id,
    'manual',
    null,
    current_date,
    'Reversal of ' || v_entry.id::text || ' — ' || v_reason,
    v_lines
  );

  perform log_platform_event(
    'journal.void', v_entry.tenant_id, 'journal_entry', p_entry_id::text, v_reason,
    jsonb_build_object('original_entry', v_entry.id, 'original_status', 'posted'),
    jsonb_build_object('reversal_entry', v_reversal.id, 'reason', v_reason)
  );

  return v_reversal;
end;
$$;

revoke execute on function public.void_journal_entry(uuid, text) from public;
grant execute on function public.void_journal_entry(uuid, text) to authenticated;

comment on function public.void_journal_entry(uuid, text) is
  'Voids a posted journal entry by marking original as void and posting reversal with swapped debit/credit. Requires reason, finance role, open period. Enforces immutability pattern.';

-- ===== from 20260925135000_tighten_it_support_select_and_law_direct_update =====
-- Tighten IT Support SELECT and prevent Law direct status bypass — Item 7

-- 1. IT Support lookup tables: tighten SELECT from tenant-only to is_it_support()
-- These were missed in 20260921093000 which tightened Law/PMO/Machine/Sustainability but not IT/BD

drop policy if exists "support_teams_select" on public.support_teams;
create policy "support_teams_select" on public.support_teams
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

drop policy if exists "ticket_categories_select" on public.ticket_categories;
create policy "ticket_categories_select" on public.ticket_categories
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

drop policy if exists "sla_policies_select" on public.sla_policies;
create policy "sla_policies_select" on public.sla_policies
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

drop policy if exists "priority_levels_select" on public.priority_levels;
create policy "priority_levels_select" on public.priority_levels
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

-- support_team_members has no tenant_id of its own (just team_id, user_id,
-- added_at) -- it's a join table, tenant-scoped only indirectly via
-- team_id -> support_teams.tenant_id (see the original policy in the
-- baseline, which used this same exists/join). Re-add is_it_support() on
-- top of that join instead of a direct tenant_id reference that doesn't exist.
drop policy if exists "support_team_members_select" on public.support_team_members;
create policy "support_team_members_select" on public.support_team_members
  for select using (
    exists (
      select 1 from public.support_teams st
      where st.id = support_team_members.team_id
        and st.tenant_id = get_my_tenant_id()
    )
    and is_it_support()
  );

-- faqs and kb_articles already allow is_published OR is_it_support() — keep as is (public KB)

-- 2. Law: prevent direct UPDATE of status via table (require RPC for approval decisions)
-- Direct UPDATE stays allowed for expired/terminated lifecycle, but not for approval transitions
create or replace function public.prevent_law_contract_direct_approval()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and old.status is distinct from new.status then
    -- Allow draft -> pending_approval only via submit_contract_for_approval RPC which sets session var?
    -- For now, allow only transitions that are NOT approval decisions via direct UPDATE:
    -- Block draft->pending_approval, pending_approval->active, pending_approval->rejected via direct UPDATE
    -- These must go through RPCs which set app.allow_law_status_change=true
    if (old.status = 'draft' and new.status = 'pending_approval')
       or (old.status = 'pending_approval' and new.status in ('active', 'rejected')) then
      if current_setting('app.allow_law_status_change', true) != 'true' then
        raise exception 'LAW_STATUS_GUARD: contract status change %->% must go through submit_contract_for_approval() or decide_contract() RPC, not direct table UPDATE', old.status, new.status
          using errcode = 'restrict_violation';
      end if;
    end if;
    -- Allow active->expired, active->terminated, expired->terminated etc via direct UPDATE (lifecycle management)
  end if;
  return new;
end;
$$;

revoke execute on function public.prevent_law_contract_direct_approval() from public;

drop trigger if exists trg_prevent_law_contract_direct_approval on public.law_contracts;
create trigger trg_prevent_law_contract_direct_approval
  before update on public.law_contracts
  for each row execute function public.prevent_law_contract_direct_approval();

-- Update RPCs to allow status change via session variable
create or replace function public.submit_contract_for_approval(p_contract_id uuid)
returns public.law_contracts
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_contract public.law_contracts%rowtype;
begin
  if not has_module_role('legal', array['admin', 'manager', 'member']) then
    raise exception 'not authorized: legal module role required';
  end if;

  select * into v_contract from law_contracts
  where id = p_contract_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'contract not found in this tenant';
  end if;
  if v_contract.status <> 'draft' then
    raise exception 'only draft contracts can be submitted for approval (current status: %)', v_contract.status;
  end if;

  perform set_config('app.allow_law_status_change', 'true', true);
  update law_contracts
  set status = 'pending_approval', updated_at = now()
  where id = v_contract.id
  returning * into v_contract;
  perform set_config('app.allow_law_status_change', 'false', true);

  insert into law_contract_decisions (tenant_id, contract_id, decision, decided_by, notes)
  values (v_contract.tenant_id, v_contract.id, 'submitted', effective_user_id(), null);

  return v_contract;
end;
$$;

revoke all on function public.submit_contract_for_approval(uuid) from public;
revoke all on function public.submit_contract_for_approval(uuid) from anon;
grant execute on function public.submit_contract_for_approval(uuid) to authenticated;
grant execute on function public.submit_contract_for_approval(uuid) to service_role;

create or replace function public.decide_contract(p_contract_id uuid, p_decision text, p_notes text default null)
returns public.law_contracts
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_contract public.law_contracts%rowtype;
  v_actor uuid := auth.uid();
  v_effective uuid := effective_user_id();
begin
  if not has_module_role('legal', array['admin', 'manager']) then
    raise exception 'not authorized: contract approval requires a legal admin or manager role';
  end if;

  if p_decision not in ('approved', 'rejected') then
    raise exception 'p_decision must be ''approved'' or ''rejected''';
  end if;

  if p_decision = 'rejected' and (p_notes is null or btrim(p_notes) = '') then
    raise exception 'rejection requires notes explaining why';
  end if;

  select * into v_contract from law_contracts
  where id = p_contract_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'contract not found in this tenant';
  end if;
  if v_contract.status <> 'pending_approval' then
    raise exception 'only contracts pending approval can be decided (current status: %)', v_contract.status;
  end if;
  -- Separation of duties: the person who drafted a contract must not be
  -- the one who approves it, even if they hold an approver role.
  -- (Wording kept identical to 20260922150000; tests and UI match on it.)
  if v_contract.created_by is not null and v_contract.created_by = v_effective then
    raise exception 'you cannot decide a contract you created -- another legal admin/manager must approve it';
  end if;

  -- Insert the decision row BEFORE updating the contract, so the
  -- notify_contract_status_change trigger (fired by the UPDATE below)
  -- can find it when it looks up the rejection reason. This ordering was
  -- fixed in 20260922150000 and must not be reversed.
  insert into law_contract_decisions (tenant_id, contract_id, decision, decided_by, notes)
  values (v_contract.tenant_id, v_contract.id, p_decision, v_effective, nullif(btrim(coalesce(p_notes, '')), ''));

  perform set_config('app.allow_law_status_change', 'true', true);
  update law_contracts
  set status = case p_decision when 'approved' then 'active' else 'rejected' end,
      updated_at = now()
  where id = v_contract.id
  returning * into v_contract;
  perform set_config('app.allow_law_status_change', 'false', true);

  return v_contract;
end;
$$;

revoke all on function public.decide_contract(uuid, text, text) from public;
revoke all on function public.decide_contract(uuid, text, text) from anon;
grant execute on function public.decide_contract(uuid, text, text) to authenticated;
grant execute on function public.decide_contract(uuid, text, text) to service_role;

-- 3. Extend posted cost immutability to fuel_logs and maintenance_requests (Machine)
--
-- prevent_posted_invoice_update() (defined in 20260925131000) only branches on
-- tg_table_name in ('supplier_invoices', 'receivable_invoices',
-- 'cash_bank_transactions'), with no fallback. Attaching it as-is to fuel_logs
-- / maintenance_requests below would create triggers that fire on every UPDATE
-- but never match any branch -- a silent no-op that doesn't actually enforce
-- immutability, despite this section's stated goal. Re-declaring it here with
-- the two extra branches (source_type values 'machine_fuel_log' and
-- 'machine_maintenance_request' already exist in journal_entries' check
-- constraint, added by 20260921120000_machine_maintenance_workflow.sql).
create or replace function public.prevent_posted_invoice_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_journal boolean;
begin
  if tg_op = 'UPDATE' then
    -- Only care about amount field changes
    if tg_table_name = 'supplier_invoices' then
      if new.amount_incl_vat is distinct from old.amount_incl_vat
         or new.vat_amount is distinct from old.vat_amount
         or new.wht_amount is distinct from old.wht_amount then
        select exists(select 1 from journal_entries where source_type='supplier_invoice' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_INVOICE_IMMUTABLE: cannot change amount of posted supplier invoice % — create a credit note reversal', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'receivable_invoices' then
      if new.amount_incl_vat is distinct from old.amount_incl_vat
         or new.vat_amount is distinct from old.vat_amount then
        select exists(select 1 from journal_entries where source_type='receivable_invoice' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_INVOICE_IMMUTABLE: cannot change amount of posted receivable invoice %', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'cash_bank_transactions' then
      if new.amount is distinct from old.amount then
        select exists(select 1 from journal_entries where source_type='cash_bank_transaction' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_TRANSACTION_IMMUTABLE: cannot change amount of posted cash/bank transaction %', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'fuel_logs' then
      if new.cost is distinct from old.cost then
        select exists(select 1 from journal_entries where source_type='machine_fuel_log' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_FUEL_LOG_IMMUTABLE: cannot change cost of posted fuel log % — create a correcting entry', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'maintenance_requests' then
      if new.actual_cost is distinct from old.actual_cost then
        select exists(select 1 from journal_entries where source_type='machine_maintenance_request' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_MAINTENANCE_COST_IMMUTABLE: cannot change actual_cost of posted maintenance request %', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.prevent_posted_invoice_update() from public;

drop trigger if exists trg_prevent_posted_fuel_cost_update on public.fuel_logs;
create trigger trg_prevent_posted_fuel_cost_update
  before update on public.fuel_logs
  for each row execute function public.prevent_posted_invoice_update();

-- maintenance_requests actual cost (if column exists, check)
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='maintenance_requests' and column_name='actual_cost') then
    -- create trigger only if column exists
    drop trigger if exists trg_prevent_posted_maintenance_cost_update on public.maintenance_requests;
    create trigger trg_prevent_posted_maintenance_cost_update
      before update on public.maintenance_requests
      for each row execute function public.prevent_posted_invoice_update();
  end if;
end $$;

comment on function public.prevent_law_contract_direct_approval() is
  'Blocks direct table UPDATE of law_contracts status for approval transitions (draft->pending_approval, pending_approval->active/rejected) — must go through RPCs. Allows lifecycle transitions active->expired/terminated via direct UPDATE.';