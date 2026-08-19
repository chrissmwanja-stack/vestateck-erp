-- Performance fix: cover every FK column flagged as unindexed by the
-- advisor since the Aug 8 batch fix (add_missing_fk_indexes) -- all added
-- by the BD, Warehouse/Stock, HR payroll, Sustainability, and
-- platform-admin-impersonation modules that landed afterward. Same
-- rationale as before: these are mostly tenant_id / *_by / *_id columns
-- that are also the primary join/filter keys hit by RLS policies and
-- reporting views.
--
-- Two composite FKs (bd_opportunities -> bd_opportunity_stages,
-- bd_proposals -> bd_proposal_statuses) get composite indexes matching
-- their (tenant_id, <col>) FK definition, since a single-column index
-- wouldn't cover the FK's leading columns.

CREATE INDEX IF NOT EXISTS idx_bd_activities_created_by ON public.bd_activities (created_by);
CREATE INDEX IF NOT EXISTS idx_bd_clients_created_by ON public.bd_clients (created_by);
CREATE INDEX IF NOT EXISTS idx_bd_leads_converted_opportunity_id ON public.bd_leads (converted_opportunity_id);
CREATE INDEX IF NOT EXISTS idx_bd_leads_created_by ON public.bd_leads (created_by);
CREATE INDEX IF NOT EXISTS idx_bd_opportunities_created_by ON public.bd_opportunities (created_by);
CREATE INDEX IF NOT EXISTS idx_bd_opportunities_tenant_id_stage ON public.bd_opportunities (tenant_id, stage);
CREATE INDEX IF NOT EXISTS idx_bd_proposals_created_by ON public.bd_proposals (created_by);
CREATE INDEX IF NOT EXISTS idx_bd_proposals_decided_by ON public.bd_proposals (decided_by);
CREATE INDEX IF NOT EXISTS idx_bd_proposals_tenant_id_status ON public.bd_proposals (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_bd_proposals_type_id ON public.bd_proposals (type_id);
CREATE INDEX IF NOT EXISTS idx_bd_tenders_created_by ON public.bd_tenders (created_by);
CREATE INDEX IF NOT EXISTS idx_bd_tenders_type_id ON public.bd_tenders (type_id);

CREATE INDEX IF NOT EXISTS idx_goods_issue_items_cost_center_id ON public.goods_issue_items (cost_center_id);
CREATE INDEX IF NOT EXISTS idx_goods_issue_items_material_catalog_id ON public.goods_issue_items (material_catalog_id);
CREATE INDEX IF NOT EXISTS idx_goods_issues_tenant_id ON public.goods_issues (tenant_id);
CREATE INDEX IF NOT EXISTS idx_goods_issues_warehouse_id ON public.goods_issues (warehouse_id);
CREATE INDEX IF NOT EXISTS idx_goods_issues_warehouse_officer_id ON public.goods_issues (warehouse_officer_id);

CREATE INDEX IF NOT EXISTS idx_hr_appraisals_created_by ON public.hr_appraisals (created_by);
CREATE INDEX IF NOT EXISTS idx_hr_employee_compensation_created_by ON public.hr_employee_compensation (created_by);
CREATE INDEX IF NOT EXISTS idx_hr_employee_compensation_tenant_id ON public.hr_employee_compensation (tenant_id);
CREATE INDEX IF NOT EXISTS idx_hr_payroll_items_employee_id ON public.hr_payroll_items (employee_id);
CREATE INDEX IF NOT EXISTS idx_hr_payroll_runs_approved_by ON public.hr_payroll_runs (approved_by);
CREATE INDEX IF NOT EXISTS idx_hr_payroll_runs_prepared_by ON public.hr_payroll_runs (prepared_by);
CREATE INDEX IF NOT EXISTS idx_hr_payroll_runs_rejected_by ON public.hr_payroll_runs (rejected_by);
CREATE INDEX IF NOT EXISTS idx_hr_team_members_user_id ON public.hr_team_members (user_id);
CREATE INDEX IF NOT EXISTS idx_hr_trainings_created_by ON public.hr_trainings (created_by);

CREATE INDEX IF NOT EXISTS idx_impersonation_sessions_tenant_id ON public.impersonation_sessions (tenant_id);
CREATE INDEX IF NOT EXISTS idx_invitations_invited_by ON public.invitations (invited_by);

CREATE INDEX IF NOT EXISTS idx_law_case_hearings_created_by ON public.law_case_hearings (created_by);
CREATE INDEX IF NOT EXISTS idx_law_regulatory_filings_created_by ON public.law_regulatory_filings (created_by);

CREATE INDEX IF NOT EXISTS idx_line_item_receipts_approved_by ON public.line_item_receipts (approved_by);
CREATE INDEX IF NOT EXISTS idx_line_item_receipts_warehouse_id ON public.line_item_receipts (warehouse_id);

CREATE INDEX IF NOT EXISTS idx_maintenance_requests_requested_by ON public.maintenance_requests (requested_by);

CREATE INDEX IF NOT EXISTS idx_payroll_approvers_user_id ON public.payroll_approvers (user_id);

CREATE INDEX IF NOT EXISTS idx_pmo_projects_manager_id ON public.pmo_projects (manager_id);
CREATE INDEX IF NOT EXISTS idx_pmo_tasks_assignee_id ON public.pmo_tasks (assignee_id);

CREATE INDEX IF NOT EXISTS idx_stock_balances_material_catalog_id ON public.stock_balances (material_catalog_id);
CREATE INDEX IF NOT EXISTS idx_stock_balances_tenant_id ON public.stock_balances (tenant_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_material_catalog_id ON public.stock_movements (material_catalog_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_recorded_by ON public.stock_movements (recorded_by);
CREATE INDEX IF NOT EXISTS idx_stock_movements_tenant_id ON public.stock_movements (tenant_id);

CREATE INDEX IF NOT EXISTS idx_sustainability_audits_created_by ON public.sustainability_audits (created_by);
CREATE INDEX IF NOT EXISTS idx_sustainability_certifications_created_by ON public.sustainability_certifications (created_by);
CREATE INDEX IF NOT EXISTS idx_sustainability_initiatives_created_by ON public.sustainability_initiatives (created_by);
CREATE INDEX IF NOT EXISTS idx_sustainability_metrics_created_by ON public.sustainability_metrics (created_by);

CREATE INDEX IF NOT EXISTS idx_tenants_created_by ON public.tenants (created_by);

CREATE INDEX IF NOT EXISTS idx_warehouses_created_by ON public.warehouses (created_by);
CREATE INDEX IF NOT EXISTS idx_warehouses_department_id ON public.warehouses (department_id);