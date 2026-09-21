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
