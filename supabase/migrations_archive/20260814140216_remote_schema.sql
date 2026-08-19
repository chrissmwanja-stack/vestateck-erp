create extension if not exists "pg_cron" with schema "pg_catalog";

drop extension if exists "pg_net";

drop trigger if exists "trg_set_account_category_defaults" on "public"."account_categories";

drop trigger if exists "accounts_touch_updated_at" on "public"."accounts";

drop trigger if exists "trg_check_po_completion_on_advance_application" on "public"."advance_payment_applications";

drop trigger if exists "protect_delegation_immutable_fields" on "public"."approval_delegations";

drop trigger if exists "trg_set_asset_tag" on "public"."assets";

drop trigger if exists "trg_bd_clients_upd" on "public"."bd_clients";

drop trigger if exists "trg_bd_lead_no" on "public"."bd_leads";

drop trigger if exists "trg_bd_leads_upd" on "public"."bd_leads";

drop trigger if exists "trg_bd_opportunities_upd" on "public"."bd_opportunities";

drop trigger if exists "trg_bd_opportunity_no" on "public"."bd_opportunities";

drop trigger if exists "trg_bd_proposal_templates_upd" on "public"."bd_proposal_templates";

drop trigger if exists "trg_bd_proposal_no" on "public"."bd_proposals";

drop trigger if exists "trg_bd_proposals_upd" on "public"."bd_proposals";

drop trigger if exists "trg_bd_tender_no" on "public"."bd_tenders";

drop trigger if exists "trg_bd_tenders_upd" on "public"."bd_tenders";

drop trigger if exists "set_cash_bank_transaction_defaults_trigger" on "public"."cash_bank_transactions";

drop trigger if exists "trg_check_payment_against_receipt" on "public"."cash_bank_transactions";

drop trigger if exists "trg_check_payroll_disbursement" on "public"."cash_bank_transactions";

drop trigger if exists "trg_check_po_completion_on_cash_bank" on "public"."cash_bank_transactions";

drop trigger if exists "trg_set_cost_center_defaults" on "public"."cost_centers";

drop trigger if exists "trg_set_department_defaults" on "public"."departments";

drop trigger if exists "set_expenditure_slip_defaults_trigger" on "public"."expenditure_slips";

drop trigger if exists "touch_expenditure_slip_updated_at_trigger" on "public"."expenditure_slips";

drop trigger if exists "trg_set_external_material_groups_defaults" on "public"."external_material_groups";

drop trigger if exists "trg_post_issue_items_to_stock" on "public"."goods_issue_items";

drop trigger if exists "trg_hr_appraisals_upd" on "public"."hr_appraisals";

drop trigger if exists "trg_hr_emp_no" on "public"."hr_employees";

drop trigger if exists "trg_hr_emp_upd" on "public"."hr_employees";

drop trigger if exists "trg_hr_leave_no" on "public"."hr_leave_requests";

drop trigger if exists "trg_hr_leave_upd" on "public"."hr_leave_requests";

drop trigger if exists "trg_hr_trainings_upd" on "public"."hr_trainings";

drop trigger if exists "invoice_request_defaults" on "public"."invoice_requests";

drop trigger if exists "it_tickets_set_number" on "public"."it_tickets";

drop trigger if exists "trg_law_case_no" on "public"."law_cases";

drop trigger if exists "trg_law_cases_upd" on "public"."law_cases";

drop trigger if exists "trg_law_compliance_no" on "public"."law_compliance_register";

drop trigger if exists "trg_law_contract_no" on "public"."law_contracts";

drop trigger if exists "trg_law_contracts_upd" on "public"."law_contracts";

drop trigger if exists "trg_post_receipt_to_stock" on "public"."line_item_receipts";

drop trigger if exists "trg_machine_assignments_upd" on "public"."machine_assignments";

drop trigger if exists "trg_machine_no" on "public"."machines";

drop trigger if exists "trg_machines_upd" on "public"."machines";

drop trigger if exists "trg_maintenance_requests_upd" on "public"."maintenance_requests";

drop trigger if exists "trg_set_material_groups_defaults" on "public"."material_groups";

drop trigger if exists "trg_set_material_request_batch_defaults" on "public"."material_request_batches";

drop trigger if exists "trg_set_material_request_item_defaults" on "public"."material_request_items";

drop trigger if exists "trg_set_material_types_defaults" on "public"."material_types";

drop trigger if exists "trg_set_organization_defaults" on "public"."organizations";

drop trigger if exists "set_petty_cash_float_defaults_trigger" on "public"."petty_cash_floats";

drop trigger if exists "touch_petty_cash_float_updated_at_trigger" on "public"."petty_cash_floats";

drop trigger if exists "set_petty_cash_replenishment_defaults_trigger" on "public"."petty_cash_replenishments";

drop trigger if exists "trg_pmo_milestones_upd" on "public"."pmo_milestones";

drop trigger if exists "trg_pmo_project_no" on "public"."pmo_projects";

drop trigger if exists "trg_pmo_projects_upd" on "public"."pmo_projects";

drop trigger if exists "trg_pmo_resource_allocations_upd" on "public"."pmo_resource_allocations";

drop trigger if exists "trg_pmo_tasks_upd" on "public"."pmo_tasks";

drop trigger if exists "trg_set_problem_number" on "public"."problems";

drop trigger if exists "trg_protect_po_immutable_fields" on "public"."purchase_orders";

drop trigger if exists "lock_receivable_invoice_organization" on "public"."receivable_invoices";

drop trigger if exists "set_receivable_invoice_defaults_trigger" on "public"."receivable_invoices";

drop trigger if exists "set_receivable_invoice_oif" on "public"."receivable_invoices";

drop trigger if exists "touch_receivable_invoice_updated_at_trigger" on "public"."receivable_invoices";

drop trigger if exists "trg_link_vendor_account_on_offer" on "public"."request_offers";

drop trigger if exists "trg_set_request_defaults" on "public"."requests";

drop trigger if exists "trg_set_request_mr_number" on "public"."requests";

drop trigger if exists "trg_set_sap_payment_defaults" on "public"."sap_payments";

drop trigger if exists "trg_apply_stock_movement" on "public"."stock_movements";

drop trigger if exists "lock_supplier_invoice_organization" on "public"."supplier_invoices";

drop trigger if exists "set_supplier_invoice_defaults_trigger" on "public"."supplier_invoices";

drop trigger if exists "set_supplier_invoice_oif" on "public"."supplier_invoices";

drop trigger if exists "touch_supplier_invoice_updated_at_trigger" on "public"."supplier_invoices";

drop trigger if exists "trg_sustain_initiatives_upd" on "public"."sustainability_initiatives";

drop trigger if exists "set_warehouse_defaults_trigger" on "public"."warehouses";

drop policy "access_requests_select" on "public"."access_requests";

drop policy "account_categories_delete" on "public"."account_categories";

drop policy "account_categories_insert" on "public"."account_categories";

drop policy "account_categories_select" on "public"."account_categories";

drop policy "account_categories_update" on "public"."account_categories";

drop policy "accounts_delete" on "public"."accounts";

drop policy "accounts_insert" on "public"."accounts";

drop policy "accounts_select" on "public"."accounts";

drop policy "accounts_update" on "public"."accounts";

drop policy "advance_payment_applications_delete" on "public"."advance_payment_applications";

drop policy "advance_payment_applications_insert" on "public"."advance_payment_applications";

drop policy "advance_payment_applications_select" on "public"."advance_payment_applications";

drop policy "advance_payments_delete" on "public"."advance_payments";

drop policy "advance_payments_insert" on "public"."advance_payments";

drop policy "advance_payments_select" on "public"."advance_payments";

drop policy "advance_payments_update" on "public"."advance_payments";

drop policy "approval_actions_select_tenant" on "public"."approval_actions";

drop policy "approval_delegations_insert_own" on "public"."approval_delegations";

drop policy "asset_assignments_select" on "public"."asset_assignments";

drop policy "asset_requests_select" on "public"."asset_requests";

drop policy "assets_select" on "public"."assets";

drop policy "bd_activities_select" on "public"."bd_activities";

drop policy "bd_activities_write" on "public"."bd_activities";

drop policy "bd_client_categories_select" on "public"."bd_client_categories";

drop policy "bd_client_categories_write" on "public"."bd_client_categories";

drop policy "bd_clients_select" on "public"."bd_clients";

drop policy "bd_clients_write" on "public"."bd_clients";

drop policy "bd_contacts_select" on "public"."bd_contacts";

drop policy "bd_contacts_write" on "public"."bd_contacts";

drop policy "bd_lead_sources_select" on "public"."bd_lead_sources";

drop policy "bd_lead_sources_write" on "public"."bd_lead_sources";

drop policy "bd_lead_statuses_select" on "public"."bd_lead_statuses";

drop policy "bd_lead_statuses_write" on "public"."bd_lead_statuses";

drop policy "bd_leads_select" on "public"."bd_leads";

drop policy "bd_leads_write" on "public"."bd_leads";

drop policy "bd_opportunities_select" on "public"."bd_opportunities";

drop policy "bd_opportunities_write" on "public"."bd_opportunities";

drop policy "bd_opportunity_stages_select" on "public"."bd_opportunity_stages";

drop policy "bd_opportunity_stages_write" on "public"."bd_opportunity_stages";

drop policy "bd_proposal_statuses_select" on "public"."bd_proposal_statuses";

drop policy "bd_proposal_statuses_write" on "public"."bd_proposal_statuses";

drop policy "bd_proposal_templates_select" on "public"."bd_proposal_templates";

drop policy "bd_proposal_templates_write" on "public"."bd_proposal_templates";

drop policy "bd_proposal_types_select" on "public"."bd_proposal_types";

drop policy "bd_proposal_types_write" on "public"."bd_proposal_types";

drop policy "bd_proposals_select" on "public"."bd_proposals";

drop policy "bd_proposals_write" on "public"."bd_proposals";

drop policy "bd_tender_types_select" on "public"."bd_tender_types";

drop policy "bd_tender_types_write" on "public"."bd_tender_types";

drop policy "bd_tenders_select" on "public"."bd_tenders";

drop policy "bd_tenders_write" on "public"."bd_tenders";

drop policy "cash_bank_transactions_delete" on "public"."cash_bank_transactions";

drop policy "cash_bank_transactions_insert" on "public"."cash_bank_transactions";

drop policy "cash_bank_transactions_select" on "public"."cash_bank_transactions";

drop policy "cash_bank_transactions_update" on "public"."cash_bank_transactions";

drop policy "cost_centers_insert_finance" on "public"."cost_centers";

drop policy "cost_centers_select_tenant" on "public"."cost_centers";

drop policy "cost_centers_update_finance" on "public"."cost_centers";

drop policy "departments_delete" on "public"."departments";

drop policy "departments_insert" on "public"."departments";

drop policy "departments_select_tenant" on "public"."departments";

drop policy "departments_update" on "public"."departments";

drop policy "expenditure_slips_delete" on "public"."expenditure_slips";

drop policy "expenditure_slips_insert" on "public"."expenditure_slips";

drop policy "expenditure_slips_select" on "public"."expenditure_slips";

drop policy "expenditure_slips_update" on "public"."expenditure_slips";

drop policy "external_material_groups_insert" on "public"."external_material_groups";

drop policy "external_material_groups_select" on "public"."external_material_groups";

drop policy "external_material_groups_update" on "public"."external_material_groups";

drop policy "faqs_select" on "public"."faqs";

drop policy "finance_team_members_delete_admin" on "public"."finance_team_members";

drop policy "finance_team_members_insert_admin" on "public"."finance_team_members";

drop policy "finance_team_members_select_own_or_admin" on "public"."finance_team_members";

drop policy "finance_team_members_update_admin" on "public"."finance_team_members";

drop policy "fuel_logs_select" on "public"."fuel_logs";

drop policy "fuel_logs_write" on "public"."fuel_logs";

drop policy "goods_issue_items_select" on "public"."goods_issue_items";

drop policy "goods_issues_select" on "public"."goods_issues";

drop policy "hr_appraisals_select" on "public"."hr_appraisals";

drop policy "hr_appraisals_write" on "public"."hr_appraisals";

drop policy "hr_attendance_insert" on "public"."hr_attendance";

drop policy "hr_attendance_select" on "public"."hr_attendance";

drop policy "hr_attendance_update" on "public"."hr_attendance";

drop policy "hr_employee_compensation_select" on "public"."hr_employee_compensation";

drop policy "hr_employees_delete" on "public"."hr_employees";

drop policy "hr_employees_insert" on "public"."hr_employees";

drop policy "hr_employees_select" on "public"."hr_employees";

drop policy "hr_employees_update" on "public"."hr_employees";

drop policy "hr_job_applications_delete" on "public"."hr_job_applications";

drop policy "hr_job_applications_insert" on "public"."hr_job_applications";

drop policy "hr_job_applications_select" on "public"."hr_job_applications";

drop policy "hr_job_applications_update" on "public"."hr_job_applications";

drop policy "hr_job_postings_delete" on "public"."hr_job_postings";

drop policy "hr_job_postings_insert" on "public"."hr_job_postings";

drop policy "hr_job_postings_select" on "public"."hr_job_postings";

drop policy "hr_job_postings_update" on "public"."hr_job_postings";

drop policy "hr_leave_requests_insert" on "public"."hr_leave_requests";

drop policy "hr_leave_requests_select" on "public"."hr_leave_requests";

drop policy "hr_leave_requests_update" on "public"."hr_leave_requests";

drop policy "hr_leave_types_delete" on "public"."hr_leave_types";

drop policy "hr_leave_types_insert" on "public"."hr_leave_types";

drop policy "hr_leave_types_select" on "public"."hr_leave_types";

drop policy "hr_leave_types_update" on "public"."hr_leave_types";

drop policy "hr_payroll_items_select" on "public"."hr_payroll_items";

drop policy "hr_payroll_runs_select" on "public"."hr_payroll_runs";

drop policy "hr_positions_delete" on "public"."hr_positions";

drop policy "hr_positions_insert" on "public"."hr_positions";

drop policy "hr_positions_select" on "public"."hr_positions";

drop policy "hr_positions_update" on "public"."hr_positions";

drop policy "hr_team_members_select" on "public"."hr_team_members";

drop policy "hr_trainings_select" on "public"."hr_trainings";

drop policy "hr_trainings_write" on "public"."hr_trainings";

drop policy "impersonation_logs_select_platform_admin" on "public"."impersonation_logs";

drop policy "invitations_insert_platform_admin" on "public"."invitations";

drop policy "invitations_insert_tenant_admin" on "public"."invitations";

drop policy "invitations_select_platform_admin" on "public"."invitations";

drop policy "invitations_select_tenant_admin" on "public"."invitations";

drop policy "invoice_requests_insert_own" on "public"."invoice_requests";

drop policy "invoice_requests_select_own_or_actionable" on "public"."invoice_requests";

drop policy "it_tickets_insert" on "public"."it_tickets";

drop policy "it_tickets_select" on "public"."it_tickets";

drop policy "kb_articles_select" on "public"."kb_articles";

drop policy "law_hearings_select" on "public"."law_case_hearings";

drop policy "law_hearings_write" on "public"."law_case_hearings";

drop policy "law_case_types_delete" on "public"."law_case_types";

drop policy "law_case_types_insert" on "public"."law_case_types";

drop policy "law_case_types_select" on "public"."law_case_types";

drop policy "law_case_types_update" on "public"."law_case_types";

drop policy "law_cases_delete" on "public"."law_cases";

drop policy "law_cases_insert" on "public"."law_cases";

drop policy "law_cases_select" on "public"."law_cases";

drop policy "law_cases_update" on "public"."law_cases";

drop policy "law_compliance_insert" on "public"."law_compliance_register";

drop policy "law_compliance_select" on "public"."law_compliance_register";

drop policy "law_compliance_update" on "public"."law_compliance_register";

drop policy "law_contract_types_delete" on "public"."law_contract_types";

drop policy "law_contract_types_insert" on "public"."law_contract_types";

drop policy "law_contract_types_select" on "public"."law_contract_types";

drop policy "law_contract_types_update" on "public"."law_contract_types";

drop policy "law_contracts_delete" on "public"."law_contracts";

drop policy "law_contracts_insert" on "public"."law_contracts";

drop policy "law_contracts_select" on "public"."law_contracts";

drop policy "law_contracts_update" on "public"."law_contracts";

drop policy "law_filings_select" on "public"."law_regulatory_filings";

drop policy "law_filings_write" on "public"."law_regulatory_filings";

drop policy "licenses_select" on "public"."licenses";

drop policy "line_item_receipts_select" on "public"."line_item_receipts";

drop policy "machine_assignments_select" on "public"."machine_assignments";

drop policy "machine_assignments_write" on "public"."machine_assignments";

drop policy "machine_types_select" on "public"."machine_types";

drop policy "machine_types_write" on "public"."machine_types";

drop policy "machines_select" on "public"."machines";

drop policy "machines_write" on "public"."machines";

drop policy "maintenance_requests_select" on "public"."maintenance_requests";

drop policy "maintenance_requests_write" on "public"."maintenance_requests";

drop policy "maintenance_types_select" on "public"."maintenance_types";

drop policy "maintenance_types_write" on "public"."maintenance_types";

drop policy "material_catalog_select" on "public"."material_catalog";

drop policy "material_catalog_update" on "public"."material_catalog";

drop policy "material_groups_insert" on "public"."material_groups";

drop policy "material_groups_select" on "public"."material_groups";

drop policy "material_groups_update" on "public"."material_groups";

drop policy "material_receipt_assignments_select" on "public"."material_receipt_assignments";

drop policy "material_request_batches_insert" on "public"."material_request_batches";

drop policy "material_request_batches_select" on "public"."material_request_batches";

drop policy "material_request_items_insert" on "public"."material_request_items";

drop policy "material_request_items_select" on "public"."material_request_items";

drop policy "material_types_insert" on "public"."material_types";

drop policy "material_types_select" on "public"."material_types";

drop policy "material_types_update" on "public"."material_types";

drop policy "finance team can view oif sequences" on "public"."oif_sequences";

drop policy "operation_logs_select" on "public"."operation_logs";

drop policy "operation_logs_write" on "public"."operation_logs";

drop policy "organizations_delete" on "public"."organizations";

drop policy "organizations_insert" on "public"."organizations";

drop policy "organizations_select" on "public"."organizations";

drop policy "organizations_update" on "public"."organizations";

drop policy "payroll_approvers_select" on "public"."payroll_approvers";

drop policy "petty_cash_floats_delete" on "public"."petty_cash_floats";

drop policy "petty_cash_floats_insert" on "public"."petty_cash_floats";

drop policy "petty_cash_floats_select" on "public"."petty_cash_floats";

drop policy "petty_cash_floats_update" on "public"."petty_cash_floats";

drop policy "petty_cash_replenishments_delete" on "public"."petty_cash_replenishments";

drop policy "petty_cash_replenishments_insert" on "public"."petty_cash_replenishments";

drop policy "petty_cash_replenishments_select" on "public"."petty_cash_replenishments";

drop policy "petty_cash_replenishments_update" on "public"."petty_cash_replenishments";

drop policy "pmo_milestones_select" on "public"."pmo_milestones";

drop policy "pmo_milestones_write" on "public"."pmo_milestones";

drop policy "pmo_project_categories_select" on "public"."pmo_project_categories";

drop policy "pmo_project_categories_write" on "public"."pmo_project_categories";

drop policy "pmo_projects_select" on "public"."pmo_projects";

drop policy "pmo_projects_write" on "public"."pmo_projects";

drop policy "pmo_resource_allocations_select" on "public"."pmo_resource_allocations";

drop policy "pmo_resource_allocations_write" on "public"."pmo_resource_allocations";

drop policy "pmo_task_types_select" on "public"."pmo_task_types";

drop policy "pmo_task_types_write" on "public"."pmo_task_types";

drop policy "pmo_tasks_select" on "public"."pmo_tasks";

drop policy "pmo_tasks_write" on "public"."pmo_tasks";

drop policy "po_edits_insert_finance" on "public"."po_edits";

drop policy "po_edits_select_finance" on "public"."po_edits";

drop policy "priority_levels_select" on "public"."priority_levels";

drop policy "problem_tickets_select" on "public"."problem_tickets";

drop policy "problems_select" on "public"."problems";

drop policy "purchase_orders_select_finance" on "public"."purchase_orders";

drop policy "purchase_orders_update_handoff" on "public"."purchase_orders";

drop policy "receivable_invoices_delete" on "public"."receivable_invoices";

drop policy "receivable_invoices_insert" on "public"."receivable_invoices";

drop policy "receivable_invoices_select" on "public"."receivable_invoices";

drop policy "receivable_invoices_update" on "public"."receivable_invoices";

drop policy "request_line_items_insert" on "public"."request_line_items";

drop policy "request_line_items_select" on "public"."request_line_items";

drop policy "request_offers_insert_authorized" on "public"."request_offers";

drop policy "request_offers_select_via_request" on "public"."request_offers";

drop policy "requests_insert_own" on "public"."requests";

drop policy "requests_select_own_or_actionable" on "public"."requests";

drop policy "sap_payments_insert_finance" on "public"."sap_payments";

drop policy "sap_payments_select_tenant" on "public"."sap_payments";

drop policy "sla_policies_select" on "public"."sla_policies";

drop policy "staff_roles_delete" on "public"."staff_roles";

drop policy "staff_roles_insert" on "public"."staff_roles";

drop policy "staff_roles_update" on "public"."staff_roles";

drop policy "tenant_read_staff_roles" on "public"."staff_roles";

drop policy "stock_balances_select" on "public"."stock_balances";

drop policy "stock_movements_select" on "public"."stock_movements";

drop policy "supplier_invoices_delete" on "public"."supplier_invoices";

drop policy "supplier_invoices_insert" on "public"."supplier_invoices";

drop policy "supplier_invoices_select" on "public"."supplier_invoices";

drop policy "supplier_invoices_update" on "public"."supplier_invoices";

drop policy "support_team_members_select" on "public"."support_team_members";

drop policy "support_teams_select" on "public"."support_teams";

drop policy "sustain_audits_select" on "public"."sustainability_audits";

drop policy "sustain_audits_write" on "public"."sustainability_audits";

drop policy "sustain_certs_select" on "public"."sustainability_certifications";

drop policy "sustain_certs_write" on "public"."sustainability_certifications";

drop policy "sustain_init_cat_select" on "public"."sustainability_initiative_categories";

drop policy "sustain_init_cat_write" on "public"."sustainability_initiative_categories";

drop policy "sustain_initiatives_select" on "public"."sustainability_initiatives";

drop policy "sustain_initiatives_write" on "public"."sustainability_initiatives";

drop policy "sustain_metric_types_select" on "public"."sustainability_metric_types";

drop policy "sustain_metric_types_write" on "public"."sustainability_metric_types";

drop policy "sustain_metrics_select" on "public"."sustainability_metrics";

drop policy "sustain_metrics_write" on "public"."sustainability_metrics";

drop policy "tenants_select_platform_admin" on "public"."tenants";

drop policy "ticket_categories_select" on "public"."ticket_categories";

drop policy "user_group_members_select" on "public"."user_group_members";

drop policy "user_groups_select" on "public"."user_groups";

drop policy "warehouses_insert" on "public"."warehouses";

drop policy "warehouses_select" on "public"."warehouses";

drop policy "warehouses_update" on "public"."warehouses";

alter table "public"."access_requests" drop constraint "access_requests_decided_by_fkey";

alter table "public"."access_requests" drop constraint "access_requests_requested_by_fkey";

alter table "public"."access_requests" drop constraint "access_requests_tenant_id_fkey";

alter table "public"."account_categories" drop constraint "account_categories_tenant_id_fkey";

alter table "public"."accounts" drop constraint "accounts_category_id_fkey";

alter table "public"."accounts" drop constraint "accounts_tenant_id_fkey";

alter table "public"."advance_payment_applications" drop constraint "advance_payment_applications_advance_payment_id_fkey";

alter table "public"."advance_payment_applications" drop constraint "advance_payment_applications_applied_by_fkey";

alter table "public"."advance_payments" drop constraint "advance_payments_account_id_fkey";

alter table "public"."advance_payments" drop constraint "advance_payments_recorded_by_fkey";

alter table "public"."advance_payments" drop constraint "advance_payments_tenant_id_fkey";

alter table "public"."app_users" drop constraint "app_users_department_id_fkey";

alter table "public"."app_users" drop constraint "app_users_tenant_id_fkey";

alter table "public"."approval_actions" drop constraint "approval_actions_acted_on_behalf_of_fkey";

alter table "public"."approval_actions" drop constraint "approval_actions_approver_id_fkey";

alter table "public"."approval_actions" drop constraint "approval_actions_invoice_request_id_fkey";

alter table "public"."approval_actions" drop constraint "approval_actions_request_id_fkey";

alter table "public"."approval_actions" drop constraint "approval_actions_workflow_stage_id_fkey";

alter table "public"."approval_assignments" drop constraint "approval_assignments_tenant_id_fkey";

alter table "public"."approval_assignments" drop constraint "approval_assignments_user_id_fkey";

alter table "public"."approval_assignments" drop constraint "approval_assignments_workflow_stage_id_fkey";

alter table "public"."approval_delegations" drop constraint "approval_delegations_delegate_user_id_fkey";

alter table "public"."approval_delegations" drop constraint "approval_delegations_delegator_user_id_fkey";

alter table "public"."approval_delegations" drop constraint "approval_delegations_tenant_id_fkey";

alter table "public"."approval_delegations" drop constraint "approval_delegations_workflow_stage_id_fkey";

alter table "public"."asset_assignments" drop constraint "asset_assignments_asset_id_fkey";

alter table "public"."asset_assignments" drop constraint "asset_assignments_assigned_by_fkey";

alter table "public"."asset_assignments" drop constraint "asset_assignments_assigned_to_fkey";

alter table "public"."asset_assignments" drop constraint "asset_assignments_tenant_id_fkey";

alter table "public"."asset_requests" drop constraint "asset_requests_decided_by_fkey";

alter table "public"."asset_requests" drop constraint "asset_requests_fulfilled_asset_id_fkey";

alter table "public"."asset_requests" drop constraint "asset_requests_fulfilled_assignment_id_fkey";

alter table "public"."asset_requests" drop constraint "asset_requests_requested_by_fkey";

alter table "public"."asset_requests" drop constraint "asset_requests_tenant_id_fkey";

alter table "public"."assets" drop constraint "assets_tenant_id_fkey";

alter table "public"."bd_activities" drop constraint "bd_activities_client_id_fkey";

alter table "public"."bd_activities" drop constraint "bd_activities_created_by_fkey";

alter table "public"."bd_clients" drop constraint "bd_clients_category_id_fkey";

alter table "public"."bd_clients" drop constraint "bd_clients_created_by_fkey";

alter table "public"."bd_contacts" drop constraint "bd_contacts_client_id_fkey";

alter table "public"."bd_leads" drop constraint "bd_leads_converted_opportunity_fk";

alter table "public"."bd_leads" drop constraint "bd_leads_created_by_fkey";

alter table "public"."bd_leads" drop constraint "bd_leads_source_id_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_client_id_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_created_by_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_lead_id_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_tenant_id_stage_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_client_id_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_created_by_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_decided_by_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_opportunity_id_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_tenant_id_status_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_type_id_fkey";

alter table "public"."bd_tenders" drop constraint "bd_tenders_client_id_fkey";

alter table "public"."bd_tenders" drop constraint "bd_tenders_created_by_fkey";

alter table "public"."bd_tenders" drop constraint "bd_tenders_type_id_fkey";

alter table "public"."cash_bank_transactions" drop constraint "cash_bank_transactions_recorded_by_fkey";

alter table "public"."cash_bank_transactions" drop constraint "cash_bank_transactions_tenant_id_fkey";

alter table "public"."cost_centers" drop constraint "cost_centers_tenant_id_fkey";

alter table "public"."departments" drop constraint "departments_parent_department_id_fkey";

alter table "public"."departments" drop constraint "departments_tenant_id_fkey";

alter table "public"."expenditure_slips" drop constraint "expenditure_slips_cost_center_id_fkey";

alter table "public"."expenditure_slips" drop constraint "expenditure_slips_organization_id_fkey";

alter table "public"."expenditure_slips" drop constraint "expenditure_slips_petty_cash_float_id_fkey";

alter table "public"."expenditure_slips" drop constraint "expenditure_slips_recorded_by_fkey";

alter table "public"."expenditure_slips" drop constraint "expenditure_slips_tenant_id_fkey";

alter table "public"."external_material_groups" drop constraint "external_material_groups_tenant_id_fkey";

alter table "public"."faqs" drop constraint "faqs_tenant_id_fkey";

alter table "public"."finance_team_members" drop constraint "finance_team_members_tenant_id_fkey";

alter table "public"."finance_team_members" drop constraint "finance_team_members_user_id_fkey";

alter table "public"."fuel_logs" drop constraint "fuel_logs_machine_id_fkey";

alter table "public"."goods_issue_items" drop constraint "goods_issue_items_cost_center_id_fkey";

alter table "public"."goods_issue_items" drop constraint "goods_issue_items_goods_issue_id_fkey";

alter table "public"."goods_issue_items" drop constraint "goods_issue_items_material_catalog_id_fkey";

alter table "public"."goods_issues" drop constraint "goods_issues_tenant_id_fkey";

alter table "public"."goods_issues" drop constraint "goods_issues_warehouse_id_fkey";

alter table "public"."goods_issues" drop constraint "goods_issues_warehouse_officer_id_fkey";

alter table "public"."hr_appraisals" drop constraint "hr_appraisals_created_by_fkey";

alter table "public"."hr_appraisals" drop constraint "hr_appraisals_employee_id_fkey";

alter table "public"."hr_attendance" drop constraint "hr_attendance_employee_id_fkey";

alter table "public"."hr_employee_compensation" drop constraint "hr_employee_compensation_created_by_fkey";

alter table "public"."hr_employee_compensation" drop constraint "hr_employee_compensation_employee_id_fkey";

alter table "public"."hr_employee_compensation" drop constraint "hr_employee_compensation_tenant_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_department_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_manager_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_position_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_user_id_fkey";

alter table "public"."hr_job_applications" drop constraint "hr_job_applications_job_posting_id_fkey";

alter table "public"."hr_job_postings" drop constraint "hr_job_postings_department_id_fkey";

alter table "public"."hr_job_postings" drop constraint "hr_job_postings_position_id_fkey";

alter table "public"."hr_leave_requests" drop constraint "hr_leave_requests_approver_id_fkey";

alter table "public"."hr_leave_requests" drop constraint "hr_leave_requests_employee_id_fkey";

alter table "public"."hr_leave_requests" drop constraint "hr_leave_requests_leave_type_id_fkey";

alter table "public"."hr_payroll_items" drop constraint "hr_payroll_items_employee_id_fkey";

alter table "public"."hr_payroll_items" drop constraint "hr_payroll_items_payroll_run_id_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_approved_by_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_prepared_by_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_rejected_by_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_tenant_id_fkey";

alter table "public"."hr_team_members" drop constraint "hr_team_members_tenant_id_fkey";

alter table "public"."hr_team_members" drop constraint "hr_team_members_user_id_fkey";

alter table "public"."hr_trainings" drop constraint "hr_trainings_created_by_fkey";

alter table "public"."impersonation_sessions" drop constraint "impersonation_sessions_platform_admin_id_fkey";

alter table "public"."impersonation_sessions" drop constraint "impersonation_sessions_tenant_id_fkey";

alter table "public"."invitations" drop constraint "invitations_invited_by_fkey";

alter table "public"."invitations" drop constraint "invitations_tenant_id_fkey";

alter table "public"."invoice_requests" drop constraint "invoice_requests_cost_center_id_fkey";

alter table "public"."invoice_requests" drop constraint "invoice_requests_current_stage_id_fkey";

alter table "public"."invoice_requests" drop constraint "invoice_requests_department_id_fkey";

alter table "public"."invoice_requests" drop constraint "invoice_requests_requester_id_fkey";

alter table "public"."invoice_requests" drop constraint "invoice_requests_tenant_id_fkey";

alter table "public"."it_tickets" drop constraint "it_tickets_approved_by_fkey";

alter table "public"."it_tickets" drop constraint "it_tickets_assignee_id_fkey";

alter table "public"."it_tickets" drop constraint "it_tickets_department_id_fkey";

alter table "public"."it_tickets" drop constraint "it_tickets_requester_id_fkey";

alter table "public"."it_tickets" drop constraint "it_tickets_tenant_id_fkey";

alter table "public"."kb_articles" drop constraint "kb_articles_created_by_fkey";

alter table "public"."kb_articles" drop constraint "kb_articles_tenant_id_fkey";

alter table "public"."law_case_hearings" drop constraint "law_case_hearings_case_id_fkey";

alter table "public"."law_case_hearings" drop constraint "law_case_hearings_created_by_fkey";

alter table "public"."law_cases" drop constraint "law_cases_created_by_fkey";

alter table "public"."law_cases" drop constraint "law_cases_type_id_fkey";

alter table "public"."law_compliance_register" drop constraint "law_compliance_register_created_by_fkey";

alter table "public"."law_compliance_register" drop constraint "law_compliance_register_owner_id_fkey";

alter table "public"."law_contracts" drop constraint "law_contracts_created_by_fkey";

alter table "public"."law_contracts" drop constraint "law_contracts_type_id_fkey";

alter table "public"."law_regulatory_filings" drop constraint "law_regulatory_filings_created_by_fkey";

alter table "public"."licenses" drop constraint "licenses_asset_id_fkey";

alter table "public"."licenses" drop constraint "licenses_tenant_id_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_approved_by_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_line_item_id_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_received_by_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_warehouse_id_fkey";

alter table "public"."machine_assignments" drop constraint "machine_assignments_machine_id_fkey";

alter table "public"."machines" drop constraint "machines_type_id_fkey";

alter table "public"."maintenance_requests" drop constraint "maintenance_requests_machine_id_fkey";

alter table "public"."maintenance_requests" drop constraint "maintenance_requests_requested_by_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_external_material_group_id_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_material_group_id_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_material_type_id_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_tenant_id_fkey";

alter table "public"."material_groups" drop constraint "material_groups_tenant_id_fkey";

alter table "public"."material_receipt_assignments" drop constraint "material_receipt_assignments_assigned_by_fkey";

alter table "public"."material_receipt_assignments" drop constraint "material_receipt_assignments_user_id_fkey";

alter table "public"."material_request_batches" drop constraint "material_requests_requester_id_fkey";

alter table "public"."material_request_batches" drop constraint "material_requests_tenant_id_fkey";

alter table "public"."material_request_items" drop constraint "material_request_items_batch_id_fkey";

alter table "public"."material_request_items" drop constraint "material_request_items_decided_by_fkey";

alter table "public"."material_request_items" drop constraint "material_request_items_external_material_group_id_fkey";

alter table "public"."material_request_items" drop constraint "material_request_items_material_catalog_id_fkey";

alter table "public"."material_request_items" drop constraint "material_request_items_material_group_id_fkey";

alter table "public"."material_request_items" drop constraint "material_request_items_material_type_id_fkey";

alter table "public"."material_request_items" drop constraint "material_request_items_tenant_id_fkey";

alter table "public"."material_types" drop constraint "material_types_tenant_id_fkey";

alter table "public"."notifications" drop constraint "notifications_invoice_request_id_fkey";

alter table "public"."notifications" drop constraint "notifications_purchase_order_id_fkey";

alter table "public"."notifications" drop constraint "notifications_recipient_id_fkey";

alter table "public"."notifications" drop constraint "notifications_request_id_fkey";

alter table "public"."notifications" drop constraint "notifications_tenant_id_fkey";

alter table "public"."oif_sequences" drop constraint "oif_sequences_organization_id_fkey";

alter table "public"."operation_logs" drop constraint "operation_logs_machine_id_fkey";

alter table "public"."organizations" drop constraint "organizations_tenant_id_fkey";

alter table "public"."payroll_approvers" drop constraint "payroll_approvers_tenant_id_fkey";

alter table "public"."payroll_approvers" drop constraint "payroll_approvers_user_id_fkey";

alter table "public"."petty_cash_floats" drop constraint "petty_cash_floats_cost_center_id_fkey";

alter table "public"."petty_cash_floats" drop constraint "petty_cash_floats_custodian_user_id_fkey";

alter table "public"."petty_cash_floats" drop constraint "petty_cash_floats_tenant_id_fkey";

alter table "public"."petty_cash_replenishments" drop constraint "petty_cash_replenishments_petty_cash_float_id_fkey";

alter table "public"."petty_cash_replenishments" drop constraint "petty_cash_replenishments_recorded_by_fkey";

alter table "public"."petty_cash_replenishments" drop constraint "petty_cash_replenishments_tenant_id_fkey";

alter table "public"."pmo_milestones" drop constraint "pmo_milestones_project_id_fkey";

alter table "public"."pmo_projects" drop constraint "pmo_projects_category_id_fkey";

alter table "public"."pmo_projects" drop constraint "pmo_projects_manager_id_fkey";

alter table "public"."pmo_resource_allocations" drop constraint "pmo_resource_allocations_employee_id_fkey";

alter table "public"."pmo_resource_allocations" drop constraint "pmo_resource_allocations_project_id_fkey";

alter table "public"."pmo_tasks" drop constraint "pmo_tasks_assignee_id_fkey";

alter table "public"."pmo_tasks" drop constraint "pmo_tasks_project_id_fkey";

alter table "public"."pmo_tasks" drop constraint "pmo_tasks_type_id_fkey";

alter table "public"."po_edits" drop constraint "po_edits_edited_by_fkey";

alter table "public"."po_edits" drop constraint "po_edits_purchase_order_id_fkey";

alter table "public"."priority_levels" drop constraint "priority_levels_tenant_id_fkey";

alter table "public"."problem_tickets" drop constraint "problem_tickets_problem_id_fkey";

alter table "public"."problem_tickets" drop constraint "problem_tickets_tenant_id_fkey";

alter table "public"."problem_tickets" drop constraint "problem_tickets_ticket_id_fkey";

alter table "public"."problems" drop constraint "problems_assigned_to_fkey";

alter table "public"."problems" drop constraint "problems_created_by_fkey";

alter table "public"."problems" drop constraint "problems_tenant_id_fkey";

alter table "public"."purchase_orders" drop constraint "purchase_orders_generated_by_fkey";

alter table "public"."purchase_orders" drop constraint "purchase_orders_request_id_fkey";

alter table "public"."purchase_orders" drop constraint "purchase_orders_vendor_account_id_fkey";

alter table "public"."receivable_invoices" drop constraint "receivable_invoices_client_account_id_fkey";

alter table "public"."receivable_invoices" drop constraint "receivable_invoices_cost_center_id_fkey";

alter table "public"."receivable_invoices" drop constraint "receivable_invoices_organization_id_fkey";

alter table "public"."receivable_invoices" drop constraint "receivable_invoices_recorded_by_fkey";

alter table "public"."receivable_invoices" drop constraint "receivable_invoices_tenant_id_fkey";

alter table "public"."request_line_items" drop constraint "request_line_items_request_id_fkey";

alter table "public"."request_offers" drop constraint "request_offers_request_id_fkey";

alter table "public"."request_offers" drop constraint "request_offers_submitted_by_fkey";

alter table "public"."request_offers" drop constraint "request_offers_vendor_account_id_fkey";

alter table "public"."requests" drop constraint "requests_cost_center_id_fkey";

alter table "public"."requests" drop constraint "requests_current_stage_id_fkey";

alter table "public"."requests" drop constraint "requests_department_id_fkey";

alter table "public"."requests" drop constraint "requests_organization_id_fkey";

alter table "public"."requests" drop constraint "requests_replaces_request_id_fkey";

alter table "public"."requests" drop constraint "requests_requester_id_fkey";

alter table "public"."requests" drop constraint "requests_tenant_id_fkey";

alter table "public"."sap_payments" drop constraint "sap_payments_purchase_order_id_fkey";

alter table "public"."sla_policies" drop constraint "sla_policies_tenant_id_fkey";

alter table "public"."staff_roles" drop constraint "staff_roles_module_check";

alter table "public"."staff_roles" drop constraint "staff_roles_user_id_fkey";

alter table "public"."stock_balances" drop constraint "stock_balances_material_catalog_id_fkey";

alter table "public"."stock_balances" drop constraint "stock_balances_tenant_id_fkey";

alter table "public"."stock_balances" drop constraint "stock_balances_warehouse_id_fkey";

alter table "public"."stock_movements" drop constraint "stock_movements_material_catalog_id_fkey";

alter table "public"."stock_movements" drop constraint "stock_movements_recorded_by_fkey";

alter table "public"."stock_movements" drop constraint "stock_movements_tenant_id_fkey";

alter table "public"."stock_movements" drop constraint "stock_movements_warehouse_id_fkey";

alter table "public"."supplier_invoices" drop constraint "supplier_invoices_cost_center_id_fkey";

alter table "public"."supplier_invoices" drop constraint "supplier_invoices_organization_id_fkey";

alter table "public"."supplier_invoices" drop constraint "supplier_invoices_purchase_order_id_fkey";

alter table "public"."supplier_invoices" drop constraint "supplier_invoices_recorded_by_fkey";

alter table "public"."supplier_invoices" drop constraint "supplier_invoices_tenant_id_fkey";

alter table "public"."supplier_invoices" drop constraint "supplier_invoices_vendor_account_id_fkey";

alter table "public"."support_team_members" drop constraint "support_team_members_team_id_fkey";

alter table "public"."support_team_members" drop constraint "support_team_members_user_id_fkey";

alter table "public"."support_teams" drop constraint "support_teams_tenant_id_fkey";

alter table "public"."sustainability_audits" drop constraint "sustainability_audits_created_by_fkey";

alter table "public"."sustainability_certifications" drop constraint "sustainability_certifications_created_by_fkey";

alter table "public"."sustainability_initiatives" drop constraint "sustainability_initiatives_category_id_fkey";

alter table "public"."sustainability_initiatives" drop constraint "sustainability_initiatives_created_by_fkey";

alter table "public"."sustainability_metrics" drop constraint "sustainability_metrics_created_by_fkey";

alter table "public"."sustainability_metrics" drop constraint "sustainability_metrics_metric_type_id_fkey";

alter table "public"."tenants" drop constraint "tenants_created_by_fkey";

alter table "public"."ticket_categories" drop constraint "ticket_categories_tenant_id_fkey";

alter table "public"."user_group_members" drop constraint "user_group_members_group_id_fkey";

alter table "public"."user_group_members" drop constraint "user_group_members_user_id_fkey";

alter table "public"."user_groups" drop constraint "user_groups_tenant_id_fkey";

alter table "public"."warehouses" drop constraint "warehouses_created_by_fkey";

alter table "public"."warehouses" drop constraint "warehouses_department_id_fkey";

alter table "public"."warehouses" drop constraint "warehouses_tenant_id_fkey";

alter table "public"."workflow_stages" drop constraint "workflow_stages_next_stage_high_id_fkey";

alter table "public"."workflow_stages" drop constraint "workflow_stages_next_stage_low_id_fkey";

alter table "public"."workflow_stages" drop constraint "workflow_stages_tenant_id_fkey";

drop view if exists "public"."v_request_tracking";

CREATE UNIQUE INDEX hr_team_members_tenant_id_user_id_key ON public.hr_team_members USING btree (tenant_id, user_id);

CREATE INDEX idx_hr_employee_compensation_employee ON public.hr_employee_compensation USING btree (employee_id, effective_date DESC);

CREATE INDEX idx_hr_payroll_items_run ON public.hr_payroll_items USING btree (payroll_run_id);

CREATE INDEX notifications_recipient_unread_idx ON public.notifications USING btree (recipient_id, created_at DESC) WHERE (read_at IS NULL);

CREATE UNIQUE INDEX supplier_invoices_purchase_order_id_unique ON public.supplier_invoices USING btree (purchase_order_id) WHERE (purchase_order_id IS NOT NULL);

alter table "public"."hr_team_members" add constraint "hr_team_members_tenant_id_user_id_key" UNIQUE using index "hr_team_members_tenant_id_user_id_key";

alter table "public"."access_requests" add constraint "access_requests_decided_by_fkey" FOREIGN KEY (decided_by) REFERENCES public.app_users(id) not valid;

alter table "public"."access_requests" validate constraint "access_requests_decided_by_fkey";

alter table "public"."access_requests" add constraint "access_requests_requested_by_fkey" FOREIGN KEY (requested_by) REFERENCES public.app_users(id) not valid;

alter table "public"."access_requests" validate constraint "access_requests_requested_by_fkey";

alter table "public"."access_requests" add constraint "access_requests_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."access_requests" validate constraint "access_requests_tenant_id_fkey";

alter table "public"."account_categories" add constraint "account_categories_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."account_categories" validate constraint "account_categories_tenant_id_fkey";

alter table "public"."accounts" add constraint "accounts_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.account_categories(id) not valid;

alter table "public"."accounts" validate constraint "accounts_category_id_fkey";

alter table "public"."accounts" add constraint "accounts_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."accounts" validate constraint "accounts_tenant_id_fkey";

alter table "public"."advance_payment_applications" add constraint "advance_payment_applications_advance_payment_id_fkey" FOREIGN KEY (advance_payment_id) REFERENCES public.advance_payments(id) not valid;

alter table "public"."advance_payment_applications" validate constraint "advance_payment_applications_advance_payment_id_fkey";

alter table "public"."advance_payment_applications" add constraint "advance_payment_applications_applied_by_fkey" FOREIGN KEY (applied_by) REFERENCES public.app_users(id) not valid;

alter table "public"."advance_payment_applications" validate constraint "advance_payment_applications_applied_by_fkey";

alter table "public"."advance_payments" add constraint "advance_payments_account_id_fkey" FOREIGN KEY (account_id) REFERENCES public.accounts(id) not valid;

alter table "public"."advance_payments" validate constraint "advance_payments_account_id_fkey";

alter table "public"."advance_payments" add constraint "advance_payments_recorded_by_fkey" FOREIGN KEY (recorded_by) REFERENCES public.app_users(id) not valid;

alter table "public"."advance_payments" validate constraint "advance_payments_recorded_by_fkey";

alter table "public"."advance_payments" add constraint "advance_payments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."advance_payments" validate constraint "advance_payments_tenant_id_fkey";

alter table "public"."app_users" add constraint "app_users_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE SET NULL not valid;

alter table "public"."app_users" validate constraint "app_users_department_id_fkey";

alter table "public"."app_users" add constraint "app_users_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."app_users" validate constraint "app_users_tenant_id_fkey";

alter table "public"."approval_actions" add constraint "approval_actions_acted_on_behalf_of_fkey" FOREIGN KEY (acted_on_behalf_of) REFERENCES public.app_users(id) not valid;

alter table "public"."approval_actions" validate constraint "approval_actions_acted_on_behalf_of_fkey";

alter table "public"."approval_actions" add constraint "approval_actions_approver_id_fkey" FOREIGN KEY (approver_id) REFERENCES public.app_users(id) not valid;

alter table "public"."approval_actions" validate constraint "approval_actions_approver_id_fkey";

alter table "public"."approval_actions" add constraint "approval_actions_invoice_request_id_fkey" FOREIGN KEY (invoice_request_id) REFERENCES public.invoice_requests(id) not valid;

alter table "public"."approval_actions" validate constraint "approval_actions_invoice_request_id_fkey";

alter table "public"."approval_actions" add constraint "approval_actions_request_id_fkey" FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE not valid;

alter table "public"."approval_actions" validate constraint "approval_actions_request_id_fkey";

alter table "public"."approval_actions" add constraint "approval_actions_workflow_stage_id_fkey" FOREIGN KEY (workflow_stage_id) REFERENCES public.workflow_stages(id) not valid;

alter table "public"."approval_actions" validate constraint "approval_actions_workflow_stage_id_fkey";

alter table "public"."approval_assignments" add constraint "approval_assignments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."approval_assignments" validate constraint "approval_assignments_tenant_id_fkey";

alter table "public"."approval_assignments" add constraint "approval_assignments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE not valid;

alter table "public"."approval_assignments" validate constraint "approval_assignments_user_id_fkey";

alter table "public"."approval_assignments" add constraint "approval_assignments_workflow_stage_id_fkey" FOREIGN KEY (workflow_stage_id) REFERENCES public.workflow_stages(id) ON DELETE CASCADE not valid;

alter table "public"."approval_assignments" validate constraint "approval_assignments_workflow_stage_id_fkey";

alter table "public"."approval_delegations" add constraint "approval_delegations_delegate_user_id_fkey" FOREIGN KEY (delegate_user_id) REFERENCES public.app_users(id) ON DELETE CASCADE not valid;

alter table "public"."approval_delegations" validate constraint "approval_delegations_delegate_user_id_fkey";

alter table "public"."approval_delegations" add constraint "approval_delegations_delegator_user_id_fkey" FOREIGN KEY (delegator_user_id) REFERENCES public.app_users(id) ON DELETE CASCADE not valid;

alter table "public"."approval_delegations" validate constraint "approval_delegations_delegator_user_id_fkey";

alter table "public"."approval_delegations" add constraint "approval_delegations_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."approval_delegations" validate constraint "approval_delegations_tenant_id_fkey";

alter table "public"."approval_delegations" add constraint "approval_delegations_workflow_stage_id_fkey" FOREIGN KEY (workflow_stage_id) REFERENCES public.workflow_stages(id) not valid;

alter table "public"."approval_delegations" validate constraint "approval_delegations_workflow_stage_id_fkey";

alter table "public"."asset_assignments" add constraint "asset_assignments_asset_id_fkey" FOREIGN KEY (asset_id) REFERENCES public.assets(id) not valid;

alter table "public"."asset_assignments" validate constraint "asset_assignments_asset_id_fkey";

alter table "public"."asset_assignments" add constraint "asset_assignments_assigned_by_fkey" FOREIGN KEY (assigned_by) REFERENCES public.app_users(id) not valid;

alter table "public"."asset_assignments" validate constraint "asset_assignments_assigned_by_fkey";

alter table "public"."asset_assignments" add constraint "asset_assignments_assigned_to_fkey" FOREIGN KEY (assigned_to) REFERENCES public.app_users(id) not valid;

alter table "public"."asset_assignments" validate constraint "asset_assignments_assigned_to_fkey";

alter table "public"."asset_assignments" add constraint "asset_assignments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."asset_assignments" validate constraint "asset_assignments_tenant_id_fkey";

alter table "public"."asset_requests" add constraint "asset_requests_decided_by_fkey" FOREIGN KEY (decided_by) REFERENCES public.app_users(id) not valid;

alter table "public"."asset_requests" validate constraint "asset_requests_decided_by_fkey";

alter table "public"."asset_requests" add constraint "asset_requests_fulfilled_asset_id_fkey" FOREIGN KEY (fulfilled_asset_id) REFERENCES public.assets(id) not valid;

alter table "public"."asset_requests" validate constraint "asset_requests_fulfilled_asset_id_fkey";

alter table "public"."asset_requests" add constraint "asset_requests_fulfilled_assignment_id_fkey" FOREIGN KEY (fulfilled_assignment_id) REFERENCES public.asset_assignments(id) not valid;

alter table "public"."asset_requests" validate constraint "asset_requests_fulfilled_assignment_id_fkey";

alter table "public"."asset_requests" add constraint "asset_requests_requested_by_fkey" FOREIGN KEY (requested_by) REFERENCES public.app_users(id) not valid;

alter table "public"."asset_requests" validate constraint "asset_requests_requested_by_fkey";

alter table "public"."asset_requests" add constraint "asset_requests_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."asset_requests" validate constraint "asset_requests_tenant_id_fkey";

alter table "public"."assets" add constraint "assets_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."assets" validate constraint "assets_tenant_id_fkey";

alter table "public"."bd_activities" add constraint "bd_activities_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE SET NULL not valid;

alter table "public"."bd_activities" validate constraint "bd_activities_client_id_fkey";

alter table "public"."bd_activities" add constraint "bd_activities_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_activities" validate constraint "bd_activities_created_by_fkey";

alter table "public"."bd_clients" add constraint "bd_clients_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.bd_client_categories(id) ON DELETE SET NULL not valid;

alter table "public"."bd_clients" validate constraint "bd_clients_category_id_fkey";

alter table "public"."bd_clients" add constraint "bd_clients_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_clients" validate constraint "bd_clients_created_by_fkey";

alter table "public"."bd_contacts" add constraint "bd_contacts_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE CASCADE not valid;

alter table "public"."bd_contacts" validate constraint "bd_contacts_client_id_fkey";

alter table "public"."bd_leads" add constraint "bd_leads_converted_opportunity_fk" FOREIGN KEY (converted_opportunity_id) REFERENCES public.bd_opportunities(id) ON DELETE SET NULL not valid;

alter table "public"."bd_leads" validate constraint "bd_leads_converted_opportunity_fk";

alter table "public"."bd_leads" add constraint "bd_leads_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_leads" validate constraint "bd_leads_created_by_fkey";

alter table "public"."bd_leads" add constraint "bd_leads_source_id_fkey" FOREIGN KEY (source_id) REFERENCES public.bd_lead_sources(id) ON DELETE SET NULL not valid;

alter table "public"."bd_leads" validate constraint "bd_leads_source_id_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE SET NULL not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_client_id_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_created_by_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_lead_id_fkey" FOREIGN KEY (lead_id) REFERENCES public.bd_leads(id) ON DELETE SET NULL not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_lead_id_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_tenant_id_stage_fkey" FOREIGN KEY (tenant_id, stage) REFERENCES public.bd_opportunity_stages(tenant_id, stage) not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_tenant_id_stage_fkey";

alter table "public"."bd_proposals" add constraint "bd_proposals_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE SET NULL not valid;

alter table "public"."bd_proposals" validate constraint "bd_proposals_client_id_fkey";

alter table "public"."bd_proposals" add constraint "bd_proposals_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_proposals" validate constraint "bd_proposals_created_by_fkey";

alter table "public"."bd_proposals" add constraint "bd_proposals_decided_by_fkey" FOREIGN KEY (decided_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_proposals" validate constraint "bd_proposals_decided_by_fkey";

alter table "public"."bd_proposals" add constraint "bd_proposals_opportunity_id_fkey" FOREIGN KEY (opportunity_id) REFERENCES public.bd_opportunities(id) ON DELETE SET NULL not valid;

alter table "public"."bd_proposals" validate constraint "bd_proposals_opportunity_id_fkey";

alter table "public"."bd_proposals" add constraint "bd_proposals_tenant_id_status_fkey" FOREIGN KEY (tenant_id, status) REFERENCES public.bd_proposal_statuses(tenant_id, status) not valid;

alter table "public"."bd_proposals" validate constraint "bd_proposals_tenant_id_status_fkey";

alter table "public"."bd_proposals" add constraint "bd_proposals_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.bd_proposal_types(id) ON DELETE SET NULL not valid;

alter table "public"."bd_proposals" validate constraint "bd_proposals_type_id_fkey";

alter table "public"."bd_tenders" add constraint "bd_tenders_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE SET NULL not valid;

alter table "public"."bd_tenders" validate constraint "bd_tenders_client_id_fkey";

alter table "public"."bd_tenders" add constraint "bd_tenders_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_tenders" validate constraint "bd_tenders_created_by_fkey";

alter table "public"."bd_tenders" add constraint "bd_tenders_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.bd_tender_types(id) ON DELETE SET NULL not valid;

alter table "public"."bd_tenders" validate constraint "bd_tenders_type_id_fkey";

alter table "public"."cash_bank_transactions" add constraint "cash_bank_transactions_recorded_by_fkey" FOREIGN KEY (recorded_by) REFERENCES public.app_users(id) not valid;

alter table "public"."cash_bank_transactions" validate constraint "cash_bank_transactions_recorded_by_fkey";

alter table "public"."cash_bank_transactions" add constraint "cash_bank_transactions_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."cash_bank_transactions" validate constraint "cash_bank_transactions_tenant_id_fkey";

alter table "public"."cost_centers" add constraint "cost_centers_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."cost_centers" validate constraint "cost_centers_tenant_id_fkey";

alter table "public"."departments" add constraint "departments_parent_department_id_fkey" FOREIGN KEY (parent_department_id) REFERENCES public.departments(id) ON DELETE SET NULL not valid;

alter table "public"."departments" validate constraint "departments_parent_department_id_fkey";

alter table "public"."departments" add constraint "departments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."departments" validate constraint "departments_tenant_id_fkey";

alter table "public"."expenditure_slips" add constraint "expenditure_slips_cost_center_id_fkey" FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) not valid;

alter table "public"."expenditure_slips" validate constraint "expenditure_slips_cost_center_id_fkey";

alter table "public"."expenditure_slips" add constraint "expenditure_slips_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) not valid;

alter table "public"."expenditure_slips" validate constraint "expenditure_slips_organization_id_fkey";

alter table "public"."expenditure_slips" add constraint "expenditure_slips_petty_cash_float_id_fkey" FOREIGN KEY (petty_cash_float_id) REFERENCES public.petty_cash_floats(id) not valid;

alter table "public"."expenditure_slips" validate constraint "expenditure_slips_petty_cash_float_id_fkey";

alter table "public"."expenditure_slips" add constraint "expenditure_slips_recorded_by_fkey" FOREIGN KEY (recorded_by) REFERENCES public.app_users(id) not valid;

alter table "public"."expenditure_slips" validate constraint "expenditure_slips_recorded_by_fkey";

alter table "public"."expenditure_slips" add constraint "expenditure_slips_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."expenditure_slips" validate constraint "expenditure_slips_tenant_id_fkey";

alter table "public"."external_material_groups" add constraint "external_material_groups_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."external_material_groups" validate constraint "external_material_groups_tenant_id_fkey";

alter table "public"."faqs" add constraint "faqs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."faqs" validate constraint "faqs_tenant_id_fkey";

alter table "public"."finance_team_members" add constraint "finance_team_members_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."finance_team_members" validate constraint "finance_team_members_tenant_id_fkey";

alter table "public"."finance_team_members" add constraint "finance_team_members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE not valid;

alter table "public"."finance_team_members" validate constraint "finance_team_members_user_id_fkey";

alter table "public"."fuel_logs" add constraint "fuel_logs_machine_id_fkey" FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE CASCADE not valid;

alter table "public"."fuel_logs" validate constraint "fuel_logs_machine_id_fkey";

alter table "public"."goods_issue_items" add constraint "goods_issue_items_cost_center_id_fkey" FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) not valid;

alter table "public"."goods_issue_items" validate constraint "goods_issue_items_cost_center_id_fkey";

alter table "public"."goods_issue_items" add constraint "goods_issue_items_goods_issue_id_fkey" FOREIGN KEY (goods_issue_id) REFERENCES public.goods_issues(id) ON DELETE CASCADE not valid;

alter table "public"."goods_issue_items" validate constraint "goods_issue_items_goods_issue_id_fkey";

alter table "public"."goods_issue_items" add constraint "goods_issue_items_material_catalog_id_fkey" FOREIGN KEY (material_catalog_id) REFERENCES public.material_catalog(id) not valid;

alter table "public"."goods_issue_items" validate constraint "goods_issue_items_material_catalog_id_fkey";

alter table "public"."goods_issues" add constraint "goods_issues_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."goods_issues" validate constraint "goods_issues_tenant_id_fkey";

alter table "public"."goods_issues" add constraint "goods_issues_warehouse_id_fkey" FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) not valid;

alter table "public"."goods_issues" validate constraint "goods_issues_warehouse_id_fkey";

alter table "public"."goods_issues" add constraint "goods_issues_warehouse_officer_id_fkey" FOREIGN KEY (warehouse_officer_id) REFERENCES public.app_users(id) not valid;

alter table "public"."goods_issues" validate constraint "goods_issues_warehouse_officer_id_fkey";

alter table "public"."hr_appraisals" add constraint "hr_appraisals_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_appraisals" validate constraint "hr_appraisals_created_by_fkey";

alter table "public"."hr_appraisals" add constraint "hr_appraisals_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."hr_appraisals" validate constraint "hr_appraisals_employee_id_fkey";

alter table "public"."hr_attendance" add constraint "hr_attendance_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."hr_attendance" validate constraint "hr_attendance_employee_id_fkey";

alter table "public"."hr_employee_compensation" add constraint "hr_employee_compensation_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_employee_compensation" validate constraint "hr_employee_compensation_created_by_fkey";

alter table "public"."hr_employee_compensation" add constraint "hr_employee_compensation_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."hr_employee_compensation" validate constraint "hr_employee_compensation_employee_id_fkey";

alter table "public"."hr_employee_compensation" add constraint "hr_employee_compensation_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_employee_compensation" validate constraint "hr_employee_compensation_tenant_id_fkey";

alter table "public"."hr_employees" add constraint "hr_employees_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE SET NULL not valid;

alter table "public"."hr_employees" validate constraint "hr_employees_department_id_fkey";

alter table "public"."hr_employees" add constraint "hr_employees_manager_id_fkey" FOREIGN KEY (manager_id) REFERENCES public.hr_employees(id) ON DELETE SET NULL not valid;

alter table "public"."hr_employees" validate constraint "hr_employees_manager_id_fkey";

alter table "public"."hr_employees" add constraint "hr_employees_position_id_fkey" FOREIGN KEY (position_id) REFERENCES public.hr_positions(id) ON DELETE SET NULL not valid;

alter table "public"."hr_employees" validate constraint "hr_employees_position_id_fkey";

alter table "public"."hr_employees" add constraint "hr_employees_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."hr_employees" validate constraint "hr_employees_user_id_fkey";

alter table "public"."hr_job_applications" add constraint "hr_job_applications_job_posting_id_fkey" FOREIGN KEY (job_posting_id) REFERENCES public.hr_job_postings(id) ON DELETE SET NULL not valid;

alter table "public"."hr_job_applications" validate constraint "hr_job_applications_job_posting_id_fkey";

alter table "public"."hr_job_postings" add constraint "hr_job_postings_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE SET NULL not valid;

alter table "public"."hr_job_postings" validate constraint "hr_job_postings_department_id_fkey";

alter table "public"."hr_job_postings" add constraint "hr_job_postings_position_id_fkey" FOREIGN KEY (position_id) REFERENCES public.hr_positions(id) ON DELETE SET NULL not valid;

alter table "public"."hr_job_postings" validate constraint "hr_job_postings_position_id_fkey";

alter table "public"."hr_leave_requests" add constraint "hr_leave_requests_approver_id_fkey" FOREIGN KEY (approver_id) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_leave_requests" validate constraint "hr_leave_requests_approver_id_fkey";

alter table "public"."hr_leave_requests" add constraint "hr_leave_requests_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."hr_leave_requests" validate constraint "hr_leave_requests_employee_id_fkey";

alter table "public"."hr_leave_requests" add constraint "hr_leave_requests_leave_type_id_fkey" FOREIGN KEY (leave_type_id) REFERENCES public.hr_leave_types(id) ON DELETE RESTRICT not valid;

alter table "public"."hr_leave_requests" validate constraint "hr_leave_requests_leave_type_id_fkey";

alter table "public"."hr_payroll_items" add constraint "hr_payroll_items_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) not valid;

alter table "public"."hr_payroll_items" validate constraint "hr_payroll_items_employee_id_fkey";

alter table "public"."hr_payroll_items" add constraint "hr_payroll_items_payroll_run_id_fkey" FOREIGN KEY (payroll_run_id) REFERENCES public.hr_payroll_runs(id) ON DELETE CASCADE not valid;

alter table "public"."hr_payroll_items" validate constraint "hr_payroll_items_payroll_run_id_fkey";

alter table "public"."hr_payroll_runs" add constraint "hr_payroll_runs_approved_by_fkey" FOREIGN KEY (approved_by) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_payroll_runs" validate constraint "hr_payroll_runs_approved_by_fkey";

alter table "public"."hr_payroll_runs" add constraint "hr_payroll_runs_prepared_by_fkey" FOREIGN KEY (prepared_by) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_payroll_runs" validate constraint "hr_payroll_runs_prepared_by_fkey";

alter table "public"."hr_payroll_runs" add constraint "hr_payroll_runs_rejected_by_fkey" FOREIGN KEY (rejected_by) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_payroll_runs" validate constraint "hr_payroll_runs_rejected_by_fkey";

alter table "public"."hr_payroll_runs" add constraint "hr_payroll_runs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_payroll_runs" validate constraint "hr_payroll_runs_tenant_id_fkey";

alter table "public"."hr_team_members" add constraint "hr_team_members_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_team_members" validate constraint "hr_team_members_tenant_id_fkey";

alter table "public"."hr_team_members" add constraint "hr_team_members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_team_members" validate constraint "hr_team_members_user_id_fkey";

alter table "public"."hr_trainings" add constraint "hr_trainings_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_trainings" validate constraint "hr_trainings_created_by_fkey";

alter table "public"."impersonation_sessions" add constraint "impersonation_sessions_platform_admin_id_fkey" FOREIGN KEY (platform_admin_id) REFERENCES public.app_users(id) not valid;

alter table "public"."impersonation_sessions" validate constraint "impersonation_sessions_platform_admin_id_fkey";

alter table "public"."impersonation_sessions" add constraint "impersonation_sessions_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."impersonation_sessions" validate constraint "impersonation_sessions_tenant_id_fkey";

alter table "public"."invitations" add constraint "invitations_invited_by_fkey" FOREIGN KEY (invited_by) REFERENCES public.app_users(id) not valid;

alter table "public"."invitations" validate constraint "invitations_invited_by_fkey";

alter table "public"."invitations" add constraint "invitations_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."invitations" validate constraint "invitations_tenant_id_fkey";

alter table "public"."invoice_requests" add constraint "invoice_requests_cost_center_id_fkey" FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) ON DELETE SET NULL not valid;

alter table "public"."invoice_requests" validate constraint "invoice_requests_cost_center_id_fkey";

alter table "public"."invoice_requests" add constraint "invoice_requests_current_stage_id_fkey" FOREIGN KEY (current_stage_id) REFERENCES public.workflow_stages(id) not valid;

alter table "public"."invoice_requests" validate constraint "invoice_requests_current_stage_id_fkey";

alter table "public"."invoice_requests" add constraint "invoice_requests_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE SET NULL not valid;

alter table "public"."invoice_requests" validate constraint "invoice_requests_department_id_fkey";

alter table "public"."invoice_requests" add constraint "invoice_requests_requester_id_fkey" FOREIGN KEY (requester_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."invoice_requests" validate constraint "invoice_requests_requester_id_fkey";

alter table "public"."invoice_requests" add constraint "invoice_requests_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."invoice_requests" validate constraint "invoice_requests_tenant_id_fkey";

alter table "public"."it_tickets" add constraint "it_tickets_approved_by_fkey" FOREIGN KEY (approved_by) REFERENCES public.app_users(id) not valid;

alter table "public"."it_tickets" validate constraint "it_tickets_approved_by_fkey";

alter table "public"."it_tickets" add constraint "it_tickets_assignee_id_fkey" FOREIGN KEY (assignee_id) REFERENCES public.app_users(id) not valid;

alter table "public"."it_tickets" validate constraint "it_tickets_assignee_id_fkey";

alter table "public"."it_tickets" add constraint "it_tickets_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) not valid;

alter table "public"."it_tickets" validate constraint "it_tickets_department_id_fkey";

alter table "public"."it_tickets" add constraint "it_tickets_requester_id_fkey" FOREIGN KEY (requester_id) REFERENCES public.app_users(id) not valid;

alter table "public"."it_tickets" validate constraint "it_tickets_requester_id_fkey";

alter table "public"."it_tickets" add constraint "it_tickets_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."it_tickets" validate constraint "it_tickets_tenant_id_fkey";

alter table "public"."kb_articles" add constraint "kb_articles_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."kb_articles" validate constraint "kb_articles_created_by_fkey";

alter table "public"."kb_articles" add constraint "kb_articles_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."kb_articles" validate constraint "kb_articles_tenant_id_fkey";

alter table "public"."law_case_hearings" add constraint "law_case_hearings_case_id_fkey" FOREIGN KEY (case_id) REFERENCES public.law_cases(id) ON DELETE CASCADE not valid;

alter table "public"."law_case_hearings" validate constraint "law_case_hearings_case_id_fkey";

alter table "public"."law_case_hearings" add constraint "law_case_hearings_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_case_hearings" validate constraint "law_case_hearings_created_by_fkey";

alter table "public"."law_cases" add constraint "law_cases_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_cases" validate constraint "law_cases_created_by_fkey";

alter table "public"."law_cases" add constraint "law_cases_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.law_case_types(id) ON DELETE SET NULL not valid;

alter table "public"."law_cases" validate constraint "law_cases_type_id_fkey";

alter table "public"."law_compliance_register" add constraint "law_compliance_register_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_compliance_register" validate constraint "law_compliance_register_created_by_fkey";

alter table "public"."law_compliance_register" add constraint "law_compliance_register_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES public.app_users(id) not valid;

alter table "public"."law_compliance_register" validate constraint "law_compliance_register_owner_id_fkey";

alter table "public"."law_contracts" add constraint "law_contracts_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_contracts" validate constraint "law_contracts_created_by_fkey";

alter table "public"."law_contracts" add constraint "law_contracts_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.law_contract_types(id) ON DELETE SET NULL not valid;

alter table "public"."law_contracts" validate constraint "law_contracts_type_id_fkey";

alter table "public"."law_regulatory_filings" add constraint "law_regulatory_filings_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_regulatory_filings" validate constraint "law_regulatory_filings_created_by_fkey";

alter table "public"."licenses" add constraint "licenses_asset_id_fkey" FOREIGN KEY (asset_id) REFERENCES public.assets(id) not valid;

alter table "public"."licenses" validate constraint "licenses_asset_id_fkey";

alter table "public"."licenses" add constraint "licenses_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."licenses" validate constraint "licenses_tenant_id_fkey";

alter table "public"."line_item_receipts" add constraint "line_item_receipts_approved_by_fkey" FOREIGN KEY (approved_by) REFERENCES public.app_users(id) not valid;

alter table "public"."line_item_receipts" validate constraint "line_item_receipts_approved_by_fkey";

alter table "public"."line_item_receipts" add constraint "line_item_receipts_line_item_id_fkey" FOREIGN KEY (line_item_id) REFERENCES public.request_line_items(id) ON DELETE CASCADE not valid;

alter table "public"."line_item_receipts" validate constraint "line_item_receipts_line_item_id_fkey";

alter table "public"."line_item_receipts" add constraint "line_item_receipts_received_by_fkey" FOREIGN KEY (received_by) REFERENCES public.app_users(id) not valid;

alter table "public"."line_item_receipts" validate constraint "line_item_receipts_received_by_fkey";

alter table "public"."line_item_receipts" add constraint "line_item_receipts_warehouse_id_fkey" FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) not valid;

alter table "public"."line_item_receipts" validate constraint "line_item_receipts_warehouse_id_fkey";

alter table "public"."machine_assignments" add constraint "machine_assignments_machine_id_fkey" FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE CASCADE not valid;

alter table "public"."machine_assignments" validate constraint "machine_assignments_machine_id_fkey";

alter table "public"."machines" add constraint "machines_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.machine_types(id) ON DELETE SET NULL not valid;

alter table "public"."machines" validate constraint "machines_type_id_fkey";

alter table "public"."maintenance_requests" add constraint "maintenance_requests_machine_id_fkey" FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE CASCADE not valid;

alter table "public"."maintenance_requests" validate constraint "maintenance_requests_machine_id_fkey";

alter table "public"."maintenance_requests" add constraint "maintenance_requests_requested_by_fkey" FOREIGN KEY (requested_by) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."maintenance_requests" validate constraint "maintenance_requests_requested_by_fkey";

alter table "public"."material_catalog" add constraint "material_catalog_external_material_group_id_fkey" FOREIGN KEY (external_material_group_id) REFERENCES public.external_material_groups(id) not valid;

alter table "public"."material_catalog" validate constraint "material_catalog_external_material_group_id_fkey";

alter table "public"."material_catalog" add constraint "material_catalog_material_group_id_fkey" FOREIGN KEY (material_group_id) REFERENCES public.material_groups(id) not valid;

alter table "public"."material_catalog" validate constraint "material_catalog_material_group_id_fkey";

alter table "public"."material_catalog" add constraint "material_catalog_material_type_id_fkey" FOREIGN KEY (material_type_id) REFERENCES public.material_types(id) not valid;

alter table "public"."material_catalog" validate constraint "material_catalog_material_type_id_fkey";

alter table "public"."material_catalog" add constraint "material_catalog_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."material_catalog" validate constraint "material_catalog_tenant_id_fkey";

alter table "public"."material_groups" add constraint "material_groups_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."material_groups" validate constraint "material_groups_tenant_id_fkey";

alter table "public"."material_receipt_assignments" add constraint "material_receipt_assignments_assigned_by_fkey" FOREIGN KEY (assigned_by) REFERENCES public.app_users(id) not valid;

alter table "public"."material_receipt_assignments" validate constraint "material_receipt_assignments_assigned_by_fkey";

alter table "public"."material_receipt_assignments" add constraint "material_receipt_assignments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) not valid;

alter table "public"."material_receipt_assignments" validate constraint "material_receipt_assignments_user_id_fkey";

alter table "public"."material_request_batches" add constraint "material_requests_requester_id_fkey" FOREIGN KEY (requester_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."material_request_batches" validate constraint "material_requests_requester_id_fkey";

alter table "public"."material_request_batches" add constraint "material_requests_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."material_request_batches" validate constraint "material_requests_tenant_id_fkey";

alter table "public"."material_request_items" add constraint "material_request_items_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES public.material_request_batches(id) ON DELETE CASCADE not valid;

alter table "public"."material_request_items" validate constraint "material_request_items_batch_id_fkey";

alter table "public"."material_request_items" add constraint "material_request_items_decided_by_fkey" FOREIGN KEY (decided_by) REFERENCES public.app_users(id) not valid;

alter table "public"."material_request_items" validate constraint "material_request_items_decided_by_fkey";

alter table "public"."material_request_items" add constraint "material_request_items_external_material_group_id_fkey" FOREIGN KEY (external_material_group_id) REFERENCES public.external_material_groups(id) not valid;

alter table "public"."material_request_items" validate constraint "material_request_items_external_material_group_id_fkey";

alter table "public"."material_request_items" add constraint "material_request_items_material_catalog_id_fkey" FOREIGN KEY (material_catalog_id) REFERENCES public.material_catalog(id) not valid;

alter table "public"."material_request_items" validate constraint "material_request_items_material_catalog_id_fkey";

alter table "public"."material_request_items" add constraint "material_request_items_material_group_id_fkey" FOREIGN KEY (material_group_id) REFERENCES public.material_groups(id) not valid;

alter table "public"."material_request_items" validate constraint "material_request_items_material_group_id_fkey";

alter table "public"."material_request_items" add constraint "material_request_items_material_type_id_fkey" FOREIGN KEY (material_type_id) REFERENCES public.material_types(id) not valid;

alter table "public"."material_request_items" validate constraint "material_request_items_material_type_id_fkey";

alter table "public"."material_request_items" add constraint "material_request_items_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."material_request_items" validate constraint "material_request_items_tenant_id_fkey";

alter table "public"."material_types" add constraint "material_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."material_types" validate constraint "material_types_tenant_id_fkey";

alter table "public"."notifications" add constraint "notifications_invoice_request_id_fkey" FOREIGN KEY (invoice_request_id) REFERENCES public.invoice_requests(id) not valid;

alter table "public"."notifications" validate constraint "notifications_invoice_request_id_fkey";

alter table "public"."notifications" add constraint "notifications_purchase_order_id_fkey" FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE SET NULL not valid;

alter table "public"."notifications" validate constraint "notifications_purchase_order_id_fkey";

alter table "public"."notifications" add constraint "notifications_recipient_id_fkey" FOREIGN KEY (recipient_id) REFERENCES public.app_users(id) not valid;

alter table "public"."notifications" validate constraint "notifications_recipient_id_fkey";

alter table "public"."notifications" add constraint "notifications_request_id_fkey" FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE SET NULL not valid;

alter table "public"."notifications" validate constraint "notifications_request_id_fkey";

alter table "public"."notifications" add constraint "notifications_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."notifications" validate constraint "notifications_tenant_id_fkey";

alter table "public"."oif_sequences" add constraint "oif_sequences_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) not valid;

alter table "public"."oif_sequences" validate constraint "oif_sequences_organization_id_fkey";

alter table "public"."operation_logs" add constraint "operation_logs_machine_id_fkey" FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE CASCADE not valid;

alter table "public"."operation_logs" validate constraint "operation_logs_machine_id_fkey";

alter table "public"."organizations" add constraint "organizations_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."organizations" validate constraint "organizations_tenant_id_fkey";

alter table "public"."payroll_approvers" add constraint "payroll_approvers_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."payroll_approvers" validate constraint "payroll_approvers_tenant_id_fkey";

alter table "public"."payroll_approvers" add constraint "payroll_approvers_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) not valid;

alter table "public"."payroll_approvers" validate constraint "payroll_approvers_user_id_fkey";

alter table "public"."petty_cash_floats" add constraint "petty_cash_floats_cost_center_id_fkey" FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) not valid;

alter table "public"."petty_cash_floats" validate constraint "petty_cash_floats_cost_center_id_fkey";

alter table "public"."petty_cash_floats" add constraint "petty_cash_floats_custodian_user_id_fkey" FOREIGN KEY (custodian_user_id) REFERENCES public.app_users(id) not valid;

alter table "public"."petty_cash_floats" validate constraint "petty_cash_floats_custodian_user_id_fkey";

alter table "public"."petty_cash_floats" add constraint "petty_cash_floats_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."petty_cash_floats" validate constraint "petty_cash_floats_tenant_id_fkey";

alter table "public"."petty_cash_replenishments" add constraint "petty_cash_replenishments_petty_cash_float_id_fkey" FOREIGN KEY (petty_cash_float_id) REFERENCES public.petty_cash_floats(id) not valid;

alter table "public"."petty_cash_replenishments" validate constraint "petty_cash_replenishments_petty_cash_float_id_fkey";

alter table "public"."petty_cash_replenishments" add constraint "petty_cash_replenishments_recorded_by_fkey" FOREIGN KEY (recorded_by) REFERENCES public.app_users(id) not valid;

alter table "public"."petty_cash_replenishments" validate constraint "petty_cash_replenishments_recorded_by_fkey";

alter table "public"."petty_cash_replenishments" add constraint "petty_cash_replenishments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."petty_cash_replenishments" validate constraint "petty_cash_replenishments_tenant_id_fkey";

alter table "public"."pmo_milestones" add constraint "pmo_milestones_project_id_fkey" FOREIGN KEY (project_id) REFERENCES public.pmo_projects(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_milestones" validate constraint "pmo_milestones_project_id_fkey";

alter table "public"."pmo_projects" add constraint "pmo_projects_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.pmo_project_categories(id) ON DELETE SET NULL not valid;

alter table "public"."pmo_projects" validate constraint "pmo_projects_category_id_fkey";

alter table "public"."pmo_projects" add constraint "pmo_projects_manager_id_fkey" FOREIGN KEY (manager_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."pmo_projects" validate constraint "pmo_projects_manager_id_fkey";

alter table "public"."pmo_resource_allocations" add constraint "pmo_resource_allocations_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_resource_allocations" validate constraint "pmo_resource_allocations_employee_id_fkey";

alter table "public"."pmo_resource_allocations" add constraint "pmo_resource_allocations_project_id_fkey" FOREIGN KEY (project_id) REFERENCES public.pmo_projects(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_resource_allocations" validate constraint "pmo_resource_allocations_project_id_fkey";

alter table "public"."pmo_tasks" add constraint "pmo_tasks_assignee_id_fkey" FOREIGN KEY (assignee_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."pmo_tasks" validate constraint "pmo_tasks_assignee_id_fkey";

alter table "public"."pmo_tasks" add constraint "pmo_tasks_project_id_fkey" FOREIGN KEY (project_id) REFERENCES public.pmo_projects(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_tasks" validate constraint "pmo_tasks_project_id_fkey";

alter table "public"."pmo_tasks" add constraint "pmo_tasks_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.pmo_task_types(id) ON DELETE SET NULL not valid;

alter table "public"."pmo_tasks" validate constraint "pmo_tasks_type_id_fkey";

alter table "public"."po_edits" add constraint "po_edits_edited_by_fkey" FOREIGN KEY (edited_by) REFERENCES public.app_users(id) not valid;

alter table "public"."po_edits" validate constraint "po_edits_edited_by_fkey";

alter table "public"."po_edits" add constraint "po_edits_purchase_order_id_fkey" FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE CASCADE not valid;

alter table "public"."po_edits" validate constraint "po_edits_purchase_order_id_fkey";

alter table "public"."priority_levels" add constraint "priority_levels_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."priority_levels" validate constraint "priority_levels_tenant_id_fkey";

alter table "public"."problem_tickets" add constraint "problem_tickets_problem_id_fkey" FOREIGN KEY (problem_id) REFERENCES public.problems(id) ON DELETE CASCADE not valid;

alter table "public"."problem_tickets" validate constraint "problem_tickets_problem_id_fkey";

alter table "public"."problem_tickets" add constraint "problem_tickets_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."problem_tickets" validate constraint "problem_tickets_tenant_id_fkey";

alter table "public"."problem_tickets" add constraint "problem_tickets_ticket_id_fkey" FOREIGN KEY (ticket_id) REFERENCES public.it_tickets(id) ON DELETE CASCADE not valid;

alter table "public"."problem_tickets" validate constraint "problem_tickets_ticket_id_fkey";

alter table "public"."problems" add constraint "problems_assigned_to_fkey" FOREIGN KEY (assigned_to) REFERENCES public.app_users(id) not valid;

alter table "public"."problems" validate constraint "problems_assigned_to_fkey";

alter table "public"."problems" add constraint "problems_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."problems" validate constraint "problems_created_by_fkey";

alter table "public"."problems" add constraint "problems_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."problems" validate constraint "problems_tenant_id_fkey";

alter table "public"."purchase_orders" add constraint "purchase_orders_generated_by_fkey" FOREIGN KEY (generated_by) REFERENCES public.app_users(id) not valid;

alter table "public"."purchase_orders" validate constraint "purchase_orders_generated_by_fkey";

alter table "public"."purchase_orders" add constraint "purchase_orders_request_id_fkey" FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE not valid;

alter table "public"."purchase_orders" validate constraint "purchase_orders_request_id_fkey";

alter table "public"."purchase_orders" add constraint "purchase_orders_vendor_account_id_fkey" FOREIGN KEY (vendor_account_id) REFERENCES public.accounts(id) not valid;

alter table "public"."purchase_orders" validate constraint "purchase_orders_vendor_account_id_fkey";

alter table "public"."receivable_invoices" add constraint "receivable_invoices_client_account_id_fkey" FOREIGN KEY (client_account_id) REFERENCES public.accounts(id) not valid;

alter table "public"."receivable_invoices" validate constraint "receivable_invoices_client_account_id_fkey";

alter table "public"."receivable_invoices" add constraint "receivable_invoices_cost_center_id_fkey" FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) not valid;

alter table "public"."receivable_invoices" validate constraint "receivable_invoices_cost_center_id_fkey";

alter table "public"."receivable_invoices" add constraint "receivable_invoices_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) not valid;

alter table "public"."receivable_invoices" validate constraint "receivable_invoices_organization_id_fkey";

alter table "public"."receivable_invoices" add constraint "receivable_invoices_recorded_by_fkey" FOREIGN KEY (recorded_by) REFERENCES public.app_users(id) not valid;

alter table "public"."receivable_invoices" validate constraint "receivable_invoices_recorded_by_fkey";

alter table "public"."receivable_invoices" add constraint "receivable_invoices_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."receivable_invoices" validate constraint "receivable_invoices_tenant_id_fkey";

alter table "public"."request_line_items" add constraint "request_line_items_request_id_fkey" FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE not valid;

alter table "public"."request_line_items" validate constraint "request_line_items_request_id_fkey";

alter table "public"."request_offers" add constraint "request_offers_request_id_fkey" FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE not valid;

alter table "public"."request_offers" validate constraint "request_offers_request_id_fkey";

alter table "public"."request_offers" add constraint "request_offers_submitted_by_fkey" FOREIGN KEY (submitted_by) REFERENCES public.app_users(id) not valid;

alter table "public"."request_offers" validate constraint "request_offers_submitted_by_fkey";

alter table "public"."request_offers" add constraint "request_offers_vendor_account_id_fkey" FOREIGN KEY (vendor_account_id) REFERENCES public.accounts(id) not valid;

alter table "public"."request_offers" validate constraint "request_offers_vendor_account_id_fkey";

alter table "public"."requests" add constraint "requests_cost_center_id_fkey" FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) not valid;

alter table "public"."requests" validate constraint "requests_cost_center_id_fkey";

alter table "public"."requests" add constraint "requests_current_stage_id_fkey" FOREIGN KEY (current_stage_id) REFERENCES public.workflow_stages(id) not valid;

alter table "public"."requests" validate constraint "requests_current_stage_id_fkey";

alter table "public"."requests" add constraint "requests_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) not valid;

alter table "public"."requests" validate constraint "requests_department_id_fkey";

alter table "public"."requests" add constraint "requests_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) not valid;

alter table "public"."requests" validate constraint "requests_organization_id_fkey";

alter table "public"."requests" add constraint "requests_replaces_request_id_fkey" FOREIGN KEY (replaces_request_id) REFERENCES public.requests(id) not valid;

alter table "public"."requests" validate constraint "requests_replaces_request_id_fkey";

alter table "public"."requests" add constraint "requests_requester_id_fkey" FOREIGN KEY (requester_id) REFERENCES public.app_users(id) not valid;

alter table "public"."requests" validate constraint "requests_requester_id_fkey";

alter table "public"."requests" add constraint "requests_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."requests" validate constraint "requests_tenant_id_fkey";

alter table "public"."sap_payments" add constraint "sap_payments_purchase_order_id_fkey" FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) not valid;

alter table "public"."sap_payments" validate constraint "sap_payments_purchase_order_id_fkey";

alter table "public"."sla_policies" add constraint "sla_policies_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."sla_policies" validate constraint "sla_policies_tenant_id_fkey";

alter table "public"."staff_roles" add constraint "staff_roles_module_check" CHECK ((module = ANY (ARRAY['hr'::text, 'legal'::text, 'bd'::text, 'it'::text, 'pmo'::text, 'machine_operation'::text, 'sustainability'::text]))) not valid;

alter table "public"."staff_roles" validate constraint "staff_roles_module_check";

alter table "public"."staff_roles" add constraint "staff_roles_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE not valid;

alter table "public"."staff_roles" validate constraint "staff_roles_user_id_fkey";

alter table "public"."stock_balances" add constraint "stock_balances_material_catalog_id_fkey" FOREIGN KEY (material_catalog_id) REFERENCES public.material_catalog(id) not valid;

alter table "public"."stock_balances" validate constraint "stock_balances_material_catalog_id_fkey";

alter table "public"."stock_balances" add constraint "stock_balances_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."stock_balances" validate constraint "stock_balances_tenant_id_fkey";

alter table "public"."stock_balances" add constraint "stock_balances_warehouse_id_fkey" FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) not valid;

alter table "public"."stock_balances" validate constraint "stock_balances_warehouse_id_fkey";

alter table "public"."stock_movements" add constraint "stock_movements_material_catalog_id_fkey" FOREIGN KEY (material_catalog_id) REFERENCES public.material_catalog(id) not valid;

alter table "public"."stock_movements" validate constraint "stock_movements_material_catalog_id_fkey";

alter table "public"."stock_movements" add constraint "stock_movements_recorded_by_fkey" FOREIGN KEY (recorded_by) REFERENCES public.app_users(id) not valid;

alter table "public"."stock_movements" validate constraint "stock_movements_recorded_by_fkey";

alter table "public"."stock_movements" add constraint "stock_movements_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."stock_movements" validate constraint "stock_movements_tenant_id_fkey";

alter table "public"."stock_movements" add constraint "stock_movements_warehouse_id_fkey" FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) not valid;

alter table "public"."stock_movements" validate constraint "stock_movements_warehouse_id_fkey";

alter table "public"."supplier_invoices" add constraint "supplier_invoices_cost_center_id_fkey" FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) not valid;

alter table "public"."supplier_invoices" validate constraint "supplier_invoices_cost_center_id_fkey";

alter table "public"."supplier_invoices" add constraint "supplier_invoices_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) not valid;

alter table "public"."supplier_invoices" validate constraint "supplier_invoices_organization_id_fkey";

alter table "public"."supplier_invoices" add constraint "supplier_invoices_purchase_order_id_fkey" FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) not valid;

alter table "public"."supplier_invoices" validate constraint "supplier_invoices_purchase_order_id_fkey";

alter table "public"."supplier_invoices" add constraint "supplier_invoices_recorded_by_fkey" FOREIGN KEY (recorded_by) REFERENCES public.app_users(id) not valid;

alter table "public"."supplier_invoices" validate constraint "supplier_invoices_recorded_by_fkey";

alter table "public"."supplier_invoices" add constraint "supplier_invoices_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."supplier_invoices" validate constraint "supplier_invoices_tenant_id_fkey";

alter table "public"."supplier_invoices" add constraint "supplier_invoices_vendor_account_id_fkey" FOREIGN KEY (vendor_account_id) REFERENCES public.accounts(id) not valid;

alter table "public"."supplier_invoices" validate constraint "supplier_invoices_vendor_account_id_fkey";

alter table "public"."support_team_members" add constraint "support_team_members_team_id_fkey" FOREIGN KEY (team_id) REFERENCES public.support_teams(id) ON DELETE CASCADE not valid;

alter table "public"."support_team_members" validate constraint "support_team_members_team_id_fkey";

alter table "public"."support_team_members" add constraint "support_team_members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) not valid;

alter table "public"."support_team_members" validate constraint "support_team_members_user_id_fkey";

alter table "public"."support_teams" add constraint "support_teams_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."support_teams" validate constraint "support_teams_tenant_id_fkey";

alter table "public"."sustainability_audits" add constraint "sustainability_audits_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."sustainability_audits" validate constraint "sustainability_audits_created_by_fkey";

alter table "public"."sustainability_certifications" add constraint "sustainability_certifications_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."sustainability_certifications" validate constraint "sustainability_certifications_created_by_fkey";

alter table "public"."sustainability_initiatives" add constraint "sustainability_initiatives_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.sustainability_initiative_categories(id) ON DELETE SET NULL not valid;

alter table "public"."sustainability_initiatives" validate constraint "sustainability_initiatives_category_id_fkey";

alter table "public"."sustainability_initiatives" add constraint "sustainability_initiatives_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."sustainability_initiatives" validate constraint "sustainability_initiatives_created_by_fkey";

alter table "public"."sustainability_metrics" add constraint "sustainability_metrics_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."sustainability_metrics" validate constraint "sustainability_metrics_created_by_fkey";

alter table "public"."sustainability_metrics" add constraint "sustainability_metrics_metric_type_id_fkey" FOREIGN KEY (metric_type_id) REFERENCES public.sustainability_metric_types(id) ON DELETE SET NULL not valid;

alter table "public"."sustainability_metrics" validate constraint "sustainability_metrics_metric_type_id_fkey";

alter table "public"."tenants" add constraint "tenants_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."tenants" validate constraint "tenants_created_by_fkey";

alter table "public"."ticket_categories" add constraint "ticket_categories_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."ticket_categories" validate constraint "ticket_categories_tenant_id_fkey";

alter table "public"."user_group_members" add constraint "user_group_members_group_id_fkey" FOREIGN KEY (group_id) REFERENCES public.user_groups(id) ON DELETE CASCADE not valid;

alter table "public"."user_group_members" validate constraint "user_group_members_group_id_fkey";

alter table "public"."user_group_members" add constraint "user_group_members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) not valid;

alter table "public"."user_group_members" validate constraint "user_group_members_user_id_fkey";

alter table "public"."user_groups" add constraint "user_groups_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."user_groups" validate constraint "user_groups_tenant_id_fkey";

alter table "public"."warehouses" add constraint "warehouses_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."warehouses" validate constraint "warehouses_created_by_fkey";

alter table "public"."warehouses" add constraint "warehouses_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE SET NULL not valid;

alter table "public"."warehouses" validate constraint "warehouses_department_id_fkey";

alter table "public"."warehouses" add constraint "warehouses_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."warehouses" validate constraint "warehouses_tenant_id_fkey";

alter table "public"."workflow_stages" add constraint "workflow_stages_next_stage_high_id_fkey" FOREIGN KEY (next_stage_high_id) REFERENCES public.workflow_stages(id) not valid;

alter table "public"."workflow_stages" validate constraint "workflow_stages_next_stage_high_id_fkey";

alter table "public"."workflow_stages" add constraint "workflow_stages_next_stage_low_id_fkey" FOREIGN KEY (next_stage_low_id) REFERENCES public.workflow_stages(id) not valid;

alter table "public"."workflow_stages" validate constraint "workflow_stages_next_stage_low_id_fkey";

alter table "public"."workflow_stages" add constraint "workflow_stages_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."workflow_stages" validate constraint "workflow_stages_tenant_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.record_employee_compensation(p_employee_id uuid, p_basic_salary numeric, p_effective_date date, p_contract_reference text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS public.hr_employee_compensation
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_employee_compensation%ROWTYPE;
  v_tenant_id uuid;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to record compensation';
  END IF;

  SELECT tenant_id INTO v_tenant_id FROM hr_employees WHERE id = p_employee_id;
  IF v_tenant_id IS NULL OR v_tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'employee not found';
  END IF;

  INSERT INTO hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, contract_reference, note, created_by)
  VALUES (v_tenant_id, p_employee_id, p_basic_salary, p_effective_date, p_contract_reference, p_note, auth.uid())
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.add_group_member(p_group_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage group membership';
  end if;
  if not exists (select 1 from user_groups where id = p_group_id and tenant_id = get_my_tenant_id()) then
    raise exception 'group not found';
  end if;
  insert into user_group_members (group_id, user_id)
  values (p_group_id, p_user_id)
  on conflict do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.add_support_team_member(p_team_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage team membership';
  end if;
  if not exists (select 1 from support_teams where id = p_team_id and tenant_id = get_my_tenant_id()) then
    raise exception 'team not found';
  end if;
  insert into support_team_members (team_id, user_id) values (p_team_id, p_user_id)
  on conflict do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.am_i_finance()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select has_po_access();
$function$
;

CREATE OR REPLACE FUNCTION public.apply_stock_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_delta numeric := CASE WHEN NEW.movement_type = 'in' THEN NEW.quantity ELSE -NEW.quantity END;
BEGIN
  INSERT INTO stock_balances (tenant_id, warehouse_id, material_catalog_id, material_name, unit, quantity_on_hand, updated_at)
  VALUES (NEW.tenant_id, NEW.warehouse_id, NEW.material_catalog_id, NEW.material_name, NEW.unit, v_delta, now())
  ON CONFLICT (warehouse_id, stock_key) DO UPDATE
    SET quantity_on_hand = stock_balances.quantity_on_hand + v_delta,
        updated_at = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.approve_all_material_request_items(p_batch_id uuid)
 RETURNS SETOF public.material_catalog
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item_id uuid;
begin
  for v_item_id in
    select id from material_request_items
    where batch_id = p_batch_id and tenant_id = get_my_tenant_id() and status = 'pending'
  loop
    return next approve_material_request_item(v_item_id);
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.approve_line_item_receipt(p_receipt_id uuid)
 RETURNS public.line_item_receipts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row line_item_receipts%ROWTYPE;
BEGIN
  IF NOT is_finance_team_member(NULL) THEN
    RAISE EXCEPTION 'not authorized to approve a goods receipt';
  END IF;

  UPDATE line_item_receipts
  SET approved_by = auth.uid(), approved_at = now()
  WHERE id = p_receipt_id
    AND EXISTS (
      SELECT 1 FROM request_line_items rli JOIN requests r ON r.id = rli.request_id
      WHERE rli.id = line_item_receipts.line_item_id AND r.tenant_id = get_my_tenant_id()
    )
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'receipt not found';
  END IF;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.approve_material_request_item(p_item_id uuid)
 RETURNS public.material_catalog
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item material_request_items%rowtype;
  v_batch material_request_batches%rowtype;
  v_catalog material_catalog%rowtype;
begin
  if not has_po_access() then
    raise exception 'not authorized to approve material requests';
  end if;

  select * into v_item from material_request_items
  where id = p_item_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'material request item not found';
  end if;

  if v_item.status <> 'pending' then
    raise exception 'this item has already been decided';
  end if;

  insert into material_catalog (
    tenant_id, name, code, unit, material_type_id, material_group_id,
    external_material_group_id, description_tr, description_en, description_fr,
    old_material_code, is_active
  )
  values (
    v_item.tenant_id, v_item.name, next_material_catalog_code(v_item.tenant_id), v_item.unit,
    v_item.material_type_id, v_item.material_group_id, v_item.external_material_group_id,
    v_item.description_tr, v_item.description_en, v_item.description_fr,
    v_item.old_material_code, true
  )
  returning * into v_catalog;

  update material_request_items
  set status = 'approved', material_catalog_id = v_catalog.id, decided_by = auth.uid(), decided_at = now()
  where id = p_item_id;

  select * into v_batch from material_request_batches where id = v_item.batch_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_item.tenant_id, v_batch.requester_id, 'material_request_approved',
    'Material request approved',
    format('"%s" was approved and added to the material catalog as %s.', v_item.name, v_catalog.code)
  );

  return v_catalog;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.approve_payroll_run(p_run_id uuid)
 RETURNS public.hr_payroll_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_payroll_approver() THEN
    RAISE EXCEPTION 'not authorized to approve payroll';
  END IF;

  UPDATE hr_payroll_runs
  SET status = 'approved', approved_by = auth.uid(), approved_at = now()
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'pending_approval'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not pending approval';
  END IF;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.assign_asset(p_asset_id uuid, p_assigned_to uuid, p_notes text DEFAULT NULL::text)
 RETURNS public.asset_assignments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_asset public.assets%rowtype;
  v_assignment public.asset_assignments%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to assign assets';
  end if;
  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.status != 'in_stock' then
    raise exception 'asset is not available (status: %)', v_asset.status;
  end if;

  insert into asset_assignments (tenant_id, asset_id, assigned_to, assigned_by, notes)
  values (v_asset.tenant_id, p_asset_id, p_assigned_to, auth.uid(), p_notes)
  returning * into v_assignment;

  update assets set status = 'assigned', updated_at = now() where id = p_asset_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_asset.tenant_id,
    p_assigned_to,
    'asset_assigned',
    'Asset assigned: ' || v_asset.asset_tag,
    format('"%s" (%s) has been assigned to you.', v_asset.name, v_asset.asset_tag)
  );

  return v_assignment;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.assign_receipt_access(p_user_id uuid)
 RETURNS public.material_receipt_assignments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row material_receipt_assignments%ROWTYPE;
BEGIN
  IF NOT is_finance_team_member('finance') THEN
    RAISE EXCEPTION 'not authorized to assign material receipt access';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_user_id AND tenant_id = get_my_tenant_id()) THEN
    RAISE EXCEPTION 'user not found in this tenant';
  END IF;

  INSERT INTO material_receipt_assignments (tenant_id, user_id, assigned_by)
  VALUES (get_my_tenant_id(), p_user_id, auth.uid())
  ON CONFLICT (tenant_id, user_id) DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'this user already has material receipt access';
  END IF;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.assign_receivable_invoice_oif()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company_code text;
  v_next_number integer;
begin
  select company_code into v_company_code
  from public.organizations
  where id = new.organization_id;

  if v_company_code is null then
    raise exception 'organization % has no company_code', new.organization_id;
  end if;

  insert into public.oif_sequences (organization_id, invoice_type, last_number)
  values (new.organization_id, 'receivable', 1)
  on conflict (organization_id, invoice_type)
  do update set last_number = public.oif_sequences.last_number + 1
  returning last_number into v_next_number;

  new.prf_oif_number := v_company_code || '-UG-' || lpad(v_next_number::text, 6, '0');
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.assign_supplier_invoice_oif()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company_code text;
  v_next_number integer;
begin
  select company_code into v_company_code
  from public.organizations
  where id = new.organization_id;

  if v_company_code is null then
    raise exception 'organization % has no company_code', new.organization_id;
  end if;

  insert into public.oif_sequences (organization_id, invoice_type, last_number)
  values (new.organization_id, 'supplier', 1)
  on conflict (organization_id, invoice_type)
  do update set last_number = public.oif_sequences.last_number + 1
  returning last_number into v_next_number;

  new.prf_oif_number := v_company_code || '-UG-' || lpad(v_next_number::text, 6, '0');
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.assign_ticket(p_ticket_id uuid, p_assignee_id uuid)
 RETURNS public.it_tickets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to assign tickets';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status = 'pending' then
    raise exception 'ticket is awaiting approval and cannot be assigned yet';
  end if;

  if p_assignee_id is not null and not exists (
    select 1 from app_users u
    where u.id = p_assignee_id
      and (
        coalesce(u.is_platform_admin, false)
        or exists (
          select 1 from staff_roles sr
          where sr.user_id = p_assignee_id
            and sr.module = 'it'
            and sr.tenant_id = v_ticket.tenant_id
        )
      )
  ) then
    raise exception 'assignee must be IT Support staff';
  end if;

  update it_tickets
  set assignee_id = p_assignee_id,
      status = case when status = 'open' and p_assignee_id is not null then 'in_progress' else status end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  if p_assignee_id is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (
      v_ticket.tenant_id,
      p_assignee_id,
      'ticket_assigned',
      'Ticket ' || v_ticket.ticket_number || ' assigned to you',
      format('"%s" has been assigned to you.', v_ticket.subject)
    );
  end if;

  return v_ticket;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.can_act_on_stage(check_stage_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    is_platform_admin()
    or exists (
      select 1 from approval_assignments aa
      where aa.user_id = auth.uid()
        and aa.workflow_stage_id = check_stage_id
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      where d.delegate_user_id = auth.uid()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and aa.workflow_stage_id = check_stage_id
        and (d.workflow_stage_id is null or d.workflow_stage_id = check_stage_id)
    );
$function$
;

CREATE OR REPLACE FUNCTION public.can_manage_po_handoff(p_purchase_order_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request_id uuid;
  v_selected_offer_submitter uuid;
BEGIN
  SELECT request_id INTO v_request_id
  FROM purchase_orders
  WHERE id = p_purchase_order_id;

  IF v_request_id IS NULL THEN
    RETURN false;
  END IF;

  -- 1. Offer submitter (procurement) -- the winning offer now, not
  --    whichever was entered last (there can be several competing
  --    quotes on a request).
  SELECT submitted_by INTO v_selected_offer_submitter
  FROM request_offers
  WHERE request_id = v_request_id AND is_selected
  LIMIT 1;

  IF v_selected_offer_submitter = auth.uid() THEN
    RETURN true;
  END IF;

  -- 2. Anyone in the approval trail for this request.
  IF EXISTS (
    SELECT 1 FROM approval_actions
    WHERE request_id = v_request_id AND approver_id = auth.uid()
  ) THEN
    RETURN true;
  END IF;

  -- 3. Finance / terminal-stage access.
  RETURN has_po_access();
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cancel_request(p_request_id uuid, p_reason text)
 RETURNS TABLE(out_request_id uuid, out_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request      requests%ROWTYPE;
  v_is_requester boolean;
  v_can_act      boolean;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a reason is required to cancel a request';
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'request not found';
  END IF;
  IF v_request.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this request';
  END IF;
  IF v_request.status != 'open' THEN
    RAISE EXCEPTION 'only open requests can be cancelled (status: %)', v_request.status;
  END IF;

  v_is_requester := v_request.requester_id = auth.uid();
  v_can_act := v_request.current_stage_id IS NOT NULL AND can_act_on_stage(v_request.current_stage_id);

  IF NOT (v_is_requester OR v_can_act) THEN
    RAISE EXCEPTION 'not authorized to cancel this request';
  END IF;

  -- Audit trail, reusing approval_actions rather than a new table --
  -- same shape as an approve/reject decision, just a different
  -- decision value.
  INSERT INTO approval_actions
    (request_id, workflow_stage_id, approver_id, decision, comment)
  VALUES
    (p_request_id, v_request.current_stage_id, auth.uid(), 'cancelled', p_reason);

  UPDATE requests
  SET status = 'cancelled', current_stage_id = NULL, updated_at = now()
  WHERE id = p_request_id;

  IF v_is_requester THEN
    -- Requester withdrew it -- notify whoever currently held it.
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    SELECT DISTINCT
      v_request.tenant_id,
      recipient_id,
      'request_cancelled',
      'Request withdrawn',
      format('Request "%s" was withdrawn by the requester: %s', v_request.item_description, p_reason),
      p_request_id
    FROM (
      SELECT aa.user_id AS recipient_id
      FROM approval_assignments aa
      WHERE aa.workflow_stage_id = v_request.current_stage_id

      UNION

      SELECT d.delegate_user_id AS recipient_id
      FROM approval_delegations d
      JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
      WHERE d.status = 'active'
        AND now() BETWEEN d.starts_at AND d.ends_at
        AND aa.workflow_stage_id = v_request.current_stage_id
        AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = v_request.current_stage_id)
    ) recipients;
  ELSE
    -- An approver/assignee cancelled it -- notify the requester.
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    VALUES (
      v_request.tenant_id,
      v_request.requester_id,
      'request_cancelled',
      'Request cancelled',
      format('Your request "%s" was cancelled: %s', v_request.item_description, p_reason),
      p_request_id
    );
  END IF;

  RETURN QUERY SELECT p_request_id, 'cancelled'::text;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_payment_against_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cap numeric;
  v_already_paid numeric;
  v_invoice supplier_invoices%ROWTYPE;
BEGIN
  IF NEW.reference_type != 'supplier_invoice' OR NEW.transaction_type != 'payment' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_invoice FROM supplier_invoices WHERE id = NEW.reference_id;
  IF NOT FOUND THEN
    RETURN NEW; -- unrelated reference_id / bad data -- not this trigger's job to police
  END IF;

  v_cap := supplier_invoice_receipt_cap(v_invoice.id);
  v_already_paid := v_invoice.amount_incl_vat - supplier_invoice_outstanding(v_invoice.id);

  IF v_already_paid + NEW.amount > v_cap + 0.01 THEN -- small epsilon for rounding
    RAISE EXCEPTION
      'payment blocked: only % of % has been confirmed received for this invoice (already paid %, this payment %)',
      round(v_cap, 2), v_invoice.amount_incl_vat, round(v_already_paid, 2), NEW.amount;
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_payroll_disbursement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_run hr_payroll_runs%ROWTYPE;
  v_total_net numeric;
BEGIN
  IF NEW.reference_type != 'payroll_run' OR NEW.transaction_type != 'payment' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_run FROM hr_payroll_runs WHERE id = NEW.reference_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_run.status NOT IN ('approved', 'disbursed') THEN
    RAISE EXCEPTION 'payroll run must be approved before it can be disbursed';
  END IF;

  SELECT COALESCE(SUM(net_pay), 0) INTO v_total_net FROM hr_payroll_items WHERE payroll_run_id = v_run.id;

  IF v_run.amount_disbursed + NEW.amount > v_total_net + 0.01 THEN
    RAISE EXCEPTION
      'payment blocked: run total is %, already disbursed %, this payment %',
      round(v_total_net, 2), round(v_run.amount_disbursed, 2), NEW.amount;
  END IF;

  UPDATE hr_payroll_runs
  SET amount_disbursed = amount_disbursed + NEW.amount,
      status = CASE WHEN amount_disbursed + NEW.amount >= v_total_net - 0.01 THEN 'disbursed' ELSE 'approved' END
  WHERE id = v_run.id;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_po_completion_on_advance_application()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_po_id uuid;
begin
  if NEW.reference_type = 'supplier_invoice' then
    select purchase_order_id into v_po_id from supplier_invoices where id = NEW.reference_id;
    if v_po_id is not null then
      perform try_complete_po(v_po_id);
    end if;
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.check_po_completion_on_cash_bank()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_po_id uuid;
begin
  if NEW.reference_type = 'supplier_invoice' then
    select purchase_order_id into v_po_id from supplier_invoices where id = NEW.reference_id;
    if v_po_id is not null then
      perform try_complete_po(v_po_id);
    end if;
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.complete_purchase_order_manually(p_purchase_order_id uuid, p_reason text)
 RETURNS public.purchase_orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_po purchase_orders%rowtype;
  v_request requests%rowtype;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'a reason is required to mark a purchase order settled manually';
  end if;

  select po.* into v_po
  from purchase_orders po
  join requests r on r.id = po.request_id
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id()
  for update of po;

  if not found then
    raise exception 'purchase order not found';
  end if;

  if not has_po_access() then
    raise exception 'not authorized to manually settle purchase orders';
  end if;

  if v_po.delivered_at is null then
    raise exception 'cannot mark a purchase order settled before it has been delivered';
  end if;

  if v_po.completed_at is not null then
    return v_po;
  end if;

  update purchase_orders set completed_at = now() where id = p_purchase_order_id returning * into v_po;

  insert into po_edits (purchase_order_id, edited_by, reason, changes)
  values (p_purchase_order_id, auth.uid(), p_reason, jsonb_build_object('completed_at', v_po.completed_at));

  select * into v_request from requests where id = v_po.request_id;
  insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
  values (
    v_request.tenant_id,
    v_request.requester_id,
    'po_completed',
    'Purchase order settled',
    format('PO %s (%s) was manually marked settled: %s', v_po.po_number, v_po.vendor_name, p_reason),
    v_request.id,
    v_po.id
  );

  return v_po;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.confirm_po_delivered(p_purchase_order_id uuid)
 RETURNS public.purchase_orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_po purchase_orders%ROWTYPE;
  v_request requests%ROWTYPE;
BEGIN
  SELECT po.* INTO v_po
  FROM purchase_orders po
  JOIN requests r ON r.id = po.request_id
  WHERE po.id = p_purchase_order_id
    AND r.tenant_id = get_my_tenant_id()
  FOR UPDATE OF po;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'purchase order not found';
  END IF;

  IF NOT can_manage_po_handoff(p_purchase_order_id) THEN
    RAISE EXCEPTION 'not authorized to confirm delivery for this purchase order';
  END IF;

  IF NOT v_po.shared_with_supplier THEN
    RAISE EXCEPTION 'cannot confirm delivery before the PO has been shared with the supplier';
  END IF;

  IF v_po.delivered_at IS NOT NULL THEN
    RETURN v_po;
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_po.request_id;

  UPDATE purchase_orders
  SET delivered_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_po;

  INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
  VALUES (
    v_request.tenant_id,
    v_request.requester_id,
    'po_delivered',
    'Order delivered',
    format('PO %s (%s) has been marked as delivered.', v_po.po_number, v_po.vendor_name),
    v_request.id,
    v_po.id
  );

  PERFORM try_complete_po(p_purchase_order_id);

  RETURN v_po;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_access_request(p_resource text, p_access_level text DEFAULT NULL::text, p_justification text DEFAULT NULL::text)
 RETURNS public.access_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request public.access_requests%rowtype;
begin
  if p_resource is null or trim(p_resource) = '' then
    raise exception 'resource/system is required';
  end if;

  insert into access_requests (tenant_id, requested_by, resource, access_level, justification)
  values (get_my_tenant_id(), auth.uid(), p_resource, p_access_level, p_justification)
  returning * into v_request;

  return v_request;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_asset(p_type text, p_name text, p_category text DEFAULT NULL::text, p_serial_number text DEFAULT NULL::text, p_vendor text DEFAULT NULL::text, p_purchase_date date DEFAULT NULL::date, p_purchase_cost numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS public.assets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create assets';
  end if;
  if p_type not in ('hardware','software') then
    raise exception 'invalid type: %', p_type;
  end if;

  insert into assets (tenant_id, type, name, category, serial_number, vendor, purchase_date, purchase_cost, notes)
  values (get_my_tenant_id(), p_type, p_name, p_category, p_serial_number, p_vendor, p_purchase_date, p_purchase_cost, p_notes)
  returning * into v_asset;

  return v_asset;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_asset_request(p_asset_type text, p_item_description text, p_justification text DEFAULT NULL::text)
 RETURNS public.asset_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request public.asset_requests%rowtype;
begin
  if p_asset_type not in ('hardware','software') then
    raise exception 'invalid asset type: %', p_asset_type;
  end if;
  if p_item_description is null or trim(p_item_description) = '' then
    raise exception 'item description is required';
  end if;

  insert into asset_requests (tenant_id, requested_by, asset_type, item_description, justification)
  values (get_my_tenant_id(), auth.uid(), p_asset_type, p_item_description, p_justification)
  returning * into v_request;

  return v_request;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_faq(p_question text, p_answer text, p_category text DEFAULT NULL::text, p_sort_order integer DEFAULT 0, p_is_published boolean DEFAULT true)
 RETURNS public.faqs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_faq public.faqs%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create FAQ entries';
  end if;
  insert into faqs (tenant_id, question, answer, category, sort_order, is_published)
  values (get_my_tenant_id(), p_question, p_answer, p_category, p_sort_order, p_is_published)
  returning * into v_faq;
  return v_faq;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_group(p_name text, p_description text DEFAULT NULL::text)
 RETURNS public.user_groups
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_group public.user_groups%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create groups';
  end if;
  insert into user_groups (tenant_id, name, description)
  values (get_my_tenant_id(), p_name, p_description)
  returning * into v_group;
  return v_group;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_kb_article(p_title text, p_content text, p_category text DEFAULT NULL::text, p_is_published boolean DEFAULT true)
 RETURNS public.kb_articles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_article public.kb_articles%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create knowledge base articles';
  end if;
  insert into kb_articles (tenant_id, title, content, category, is_published, created_by)
  values (get_my_tenant_id(), p_title, p_content, p_category, p_is_published, auth.uid())
  returning * into v_article;
  return v_article;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_license(p_asset_id uuid, p_seats_total integer DEFAULT 1, p_license_key text DEFAULT NULL::text, p_vendor text DEFAULT NULL::text, p_expiry_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS public.licenses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_asset public.assets%rowtype;
  v_license public.licenses%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create licenses';
  end if;
  select * into v_asset from assets where id = p_asset_id;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.type != 'software' then
    raise exception 'licenses can only be linked to software assets';
  end if;

  insert into licenses (tenant_id, asset_id, license_key, seats_total, vendor, expiry_date, notes)
  values (v_asset.tenant_id, p_asset_id, p_license_key, p_seats_total, p_vendor, p_expiry_date, p_notes)
  returning * into v_license;

  return v_license;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_payroll_run(p_period text)
 RETURNS public.hr_payroll_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_run hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to prepare payroll';
  END IF;

  INSERT INTO hr_payroll_runs (tenant_id, period, prepared_by)
  VALUES (get_my_tenant_id(), p_period, auth.uid())
  RETURNING * INTO v_run;

  RETURN v_run;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_problem(p_title text, p_description text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_priority text DEFAULT 'medium'::text)
 RETURNS public.problems
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_problem public.problems%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create problems';
  end if;
  if p_priority not in ('low','medium','high','urgent') then
    raise exception 'invalid priority: %', p_priority;
  end if;

  insert into problems (tenant_id, title, description, category, priority, created_by)
  values (get_my_tenant_id(), p_title, p_description, p_category, p_priority, auth.uid())
  returning * into v_problem;
  return v_problem;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_support_team(p_name text, p_description text DEFAULT NULL::text)
 RETURNS public.support_teams
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage support teams';
  end if;
  insert into support_teams (tenant_id, name, description)
  values (get_my_tenant_id(), p_name, p_description)
  returning * into v_row;
  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_ticket_category(p_code text, p_name text)
 RETURNS public.ticket_categories
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  insert into ticket_categories (tenant_id, code, name)
  values (get_my_tenant_id(), p_code, p_name)
  returning * into v_row;
  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.decide_access_request(p_request_id uuid, p_decision text, p_notes text DEFAULT NULL::text)
 RETURNS public.access_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request public.access_requests%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to decide access requests';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from access_requests where id = p_request_id for update;
  if not found or v_request.tenant_id != get_my_tenant_id() then
    raise exception 'request not found';
  end if;
  if v_request.status != 'pending' then
    raise exception 'request is not pending (status: %)', v_request.status;
  end if;

  update access_requests
  set status = p_decision, decided_by = auth.uid(), decided_at = now(),
      decision_notes = p_notes, updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_request.tenant_id, v_request.requested_by, 'access_request_' || p_decision,
    'Access request ' || p_decision || ': ' || v_request.resource,
    coalesce(p_notes, 'Your access request has been ' || p_decision || '.')
  );

  return v_request;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.decide_asset_request(p_request_id uuid, p_decision text, p_notes text DEFAULT NULL::text)
 RETURNS public.asset_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request public.asset_requests%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to decide asset requests';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from asset_requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'pending' then
    raise exception 'request is not pending (status: %)', v_request.status;
  end if;

  update asset_requests
  set status = p_decision,
      decided_by = auth.uid(),
      decided_at = now(),
      decision_notes = p_notes,
      updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_request.tenant_id,
    v_request.requested_by,
    'asset_request_' || p_decision,
    'Asset request ' || p_decision || ': ' || v_request.item_description,
    coalesce(p_notes, 'Your asset request has been ' || p_decision || '.')
  );

  return v_request;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_purchase_order(p_purchase_order_id uuid, p_vendor_name text, p_amount numeric, p_reason text, p_initial_po_number text DEFAULT NULL::text, p_currency text DEFAULT NULL::text, p_delivery_date date DEFAULT NULL::date, p_project_sap_no text DEFAULT NULL::text, p_payment_conditions text DEFAULT NULL::text, p_terms_of_delivery text DEFAULT NULL::text)
 RETURNS public.po_edits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_po      purchase_orders%rowtype;
  v_request requests%rowtype;
  v_changes jsonb := '{}'::jsonb;
  v_edit    po_edits%rowtype;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required for every PO edit';
  end if;
  if p_vendor_name is null or btrim(p_vendor_name) = '' then
    raise exception 'vendor name cannot be empty';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be greater than zero';
  end if;

  select po.* into v_po
  from purchase_orders po
  join requests r on r.id = po.request_id
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id()
  for update of po;

  if not found then
    raise exception 'purchase order not found';
  end if;
  if not has_po_access() then
    raise exception 'not authorized to edit purchase orders';
  end if;

  select * into v_request from requests where id = v_po.request_id;

  if p_vendor_name is distinct from v_po.vendor_name then
    v_changes := v_changes || jsonb_build_object(
      'vendor_name', jsonb_build_object('old', v_po.vendor_name, 'new', p_vendor_name)
    );
  end if;
  if p_amount is distinct from v_po.amount then
    v_changes := v_changes || jsonb_build_object(
      'amount', jsonb_build_object('old', v_po.amount, 'new', p_amount)
    );
  end if;
  if p_initial_po_number is not null and p_initial_po_number is distinct from v_po.initial_po_number then
    v_changes := v_changes || jsonb_build_object(
      'initial_po_number', jsonb_build_object('old', v_po.initial_po_number, 'new', p_initial_po_number)
    );
  end if;
  if p_currency is not null and p_currency is distinct from v_po.currency then
    v_changes := v_changes || jsonb_build_object(
      'currency', jsonb_build_object('old', v_po.currency, 'new', p_currency)
    );
  end if;
  if p_delivery_date is not null and p_delivery_date is distinct from v_request.delivery_date then
    v_changes := v_changes || jsonb_build_object(
      'delivery_date', jsonb_build_object('old', v_request.delivery_date, 'new', p_delivery_date)
    );
  end if;
  if p_project_sap_no is not null and p_project_sap_no is distinct from v_po.project_sap_no then
    v_changes := v_changes || jsonb_build_object(
      'project_sap_no', jsonb_build_object('old', v_po.project_sap_no, 'new', p_project_sap_no)
    );
  end if;
  if p_payment_conditions is not null and p_payment_conditions is distinct from v_po.payment_conditions then
    v_changes := v_changes || jsonb_build_object(
      'payment_conditions', jsonb_build_object('old', v_po.payment_conditions, 'new', p_payment_conditions)
    );
  end if;
  if p_terms_of_delivery is not null and p_terms_of_delivery is distinct from v_po.terms_of_delivery then
    v_changes := v_changes || jsonb_build_object(
      'terms_of_delivery', jsonb_build_object('old', v_po.terms_of_delivery, 'new', p_terms_of_delivery)
    );
  end if;

  if v_changes = '{}'::jsonb then
    raise exception 'nothing has changed -- update a field, or cancel';
  end if;

  insert into po_edits (purchase_order_id, edited_by, reason, changes)
  values (p_purchase_order_id, auth.uid(), p_reason, v_changes)
  returning * into v_edit;

  -- Open the narrow escape hatch just for this statement, then update.
  perform set_config('vestateck.allow_po_financial_edit', 'on', true);
  update purchase_orders
  set
    vendor_name = p_vendor_name,
    amount = p_amount,
    initial_po_number = coalesce(p_initial_po_number, initial_po_number),
    currency = coalesce(p_currency, currency),
    project_sap_no = coalesce(p_project_sap_no, project_sap_no),
    payment_conditions = coalesce(p_payment_conditions, payment_conditions),
    terms_of_delivery = coalesce(p_terms_of_delivery, terms_of_delivery)
  where id = p_purchase_order_id;
  perform set_config('vestateck.allow_po_financial_edit', 'off', true);

  if p_delivery_date is not null then
    update requests set delivery_date = p_delivery_date, updated_at = now() where id = v_po.request_id;
  end if;

  return v_edit;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.end_impersonation()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id
  from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null
  limit 1;

  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), v_tenant_id, 'end');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.fulfill_asset_request(p_request_id uuid, p_asset_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS public.asset_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request public.asset_requests%rowtype;
  v_asset public.assets%rowtype;
  v_assignment public.asset_assignments%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to fulfill asset requests';
  end if;

  select * into v_request from asset_requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'approved' then
    raise exception 'request must be approved before fulfillment (status: %)', v_request.status;
  end if;

  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.type != v_request.asset_type then
    raise exception 'asset type (%) does not match requested type (%)', v_asset.type, v_request.asset_type;
  end if;
  if v_asset.status != 'in_stock' then
    raise exception 'asset is not available (status: %)', v_asset.status;
  end if;

  insert into asset_assignments (tenant_id, asset_id, assigned_to, assigned_by, notes)
  values (v_asset.tenant_id, p_asset_id, v_request.requested_by, auth.uid(), p_notes)
  returning * into v_assignment;

  update assets set status = 'assigned', updated_at = now() where id = p_asset_id;

  update asset_requests
  set status = 'fulfilled',
      fulfilled_asset_id = p_asset_id,
      fulfilled_assignment_id = v_assignment.id,
      updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_asset.tenant_id,
    v_request.requested_by,
    'asset_request_fulfilled',
    'Asset request fulfilled: ' || v_asset.asset_tag,
    format('"%s" (%s) has been assigned to you.', v_asset.name, v_asset.asset_tag)
  );

  return v_request;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_bd_lead_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if NEW.lead_no is null then
    NEW.lead_no := public.next_doc_number(NEW.tenant_id, 'bd_lead', 'BD-L');
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_bd_opportunity_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if NEW.opportunity_no is null then
    NEW.opportunity_no := public.next_doc_number(NEW.tenant_id, 'bd_opportunity', 'BD-O');
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_bd_proposal_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if NEW.proposal_no is null then
    NEW.proposal_no := public.next_doc_number(NEW.tenant_id, 'bd_proposal', 'BD-P');
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_bd_tender_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if NEW.tender_no is null then
    NEW.tender_no := public.next_doc_number(NEW.tenant_id, 'bd_tender', 'BD-T');
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_hr_employee_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.employee_no := public.next_doc_number(NEW.tenant_id, 'hr_employee', 'HR-EMP');
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_hr_leave_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.leave_no := public.next_doc_number(NEW.tenant_id, 'hr_leave', 'HR-LV');
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_law_case_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.case_no := public.next_doc_number(NEW.tenant_id, 'law_case', 'LAW-CASE');
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_law_compliance_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.item_no := public.next_doc_number(NEW.tenant_id, 'law_compliance', 'LAW-COMP');
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_law_contract_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.contract_no := public.next_doc_number(NEW.tenant_id, 'law_contract', 'LAW-C');
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_machine_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  NEW.machine_no := public.next_doc_number(NEW.tenant_id, 'machine', 'MCH');
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_payroll_items(p_run_id uuid)
 RETURNS SETOF public.hr_payroll_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_run hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to prepare payroll';
  END IF;

  SELECT * INTO v_run FROM hr_payroll_runs WHERE id = p_run_id AND tenant_id = get_my_tenant_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'payroll run not found';
  END IF;
  IF v_run.status != 'draft' THEN
    RAISE EXCEPTION 'can only generate items while the run is in draft';
  END IF;

  RETURN QUERY
  INSERT INTO hr_payroll_items (payroll_run_id, employee_id, basic_salary)
  SELECT p_run_id, e.id, cc.basic_salary
  FROM hr_employees e
  JOIN hr_employee_current_compensation cc ON cc.employee_id = e.id
  WHERE e.tenant_id = get_my_tenant_id()
    AND e.is_active
    AND NOT EXISTS (SELECT 1 FROM hr_payroll_items i WHERE i.payroll_run_id = p_run_id AND i.employee_id = e.id)
  ON CONFLICT (payroll_run_id, employee_id) DO NOTHING
  RETURNING *;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_pmo_project_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  NEW.project_no := public.next_doc_number(NEW.tenant_id, 'pmo_project', 'PMO-P');
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_access_requests(p_status text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, requested_by uuid, requester_name text, resource text, access_level text, justification text, status text, decided_by uuid, decided_at timestamp with time zone, decision_notes text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to view access requests';
  end if;

  return query
  select r.id, r.requested_by, u.name, r.resource, r.access_level, r.justification,
         r.status, r.decided_by, r.decided_at, r.decision_notes, r.created_at
  from access_requests r
  join app_users u on u.id = r.requested_by
  where r.tenant_id = get_my_tenant_id()
    and (p_status is null or r.status = p_status)
  order by r.created_at desc;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_active_impersonation()
 RETURNS TABLE(tenant_id uuid, tenant_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select t.id, t.name
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  where s.platform_admin_id = auth.uid() and s.ended_at is null
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_all_tickets()
 RETURNS SETOF public.it_tickets
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and is_it_support()
  order by
    case status when 'open' then 0 when 'in_progress' then 1 when 'resolved' then 2 else 3 end,
    created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_asset_assignments(p_active_only boolean DEFAULT true)
 RETURNS TABLE(id uuid, asset_id uuid, asset_tag text, asset_name text, asset_type text, assigned_to uuid, assigned_to_name text, assigned_by uuid, assigned_at timestamp with time zone, returned_at timestamp with time zone, notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    aa.id, aa.asset_id, a.asset_tag, a.name as asset_name, a.type as asset_type,
    aa.assigned_to, u.name as assigned_to_name, aa.assigned_by, aa.assigned_at, aa.returned_at, aa.notes
  from asset_assignments aa
  join assets a on a.id = aa.asset_id
  join app_users u on u.id = aa.assigned_to
  where aa.tenant_id = get_my_tenant_id() and is_it_support()
    and (not p_active_only or aa.returned_at is null)
  order by aa.assigned_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_asset_requests(p_status text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, requested_by uuid, requester_name text, asset_type text, item_description text, justification text, status text, decided_by uuid, decided_at timestamp with time zone, decision_notes text, fulfilled_asset_id uuid, fulfilled_asset_tag text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to view asset requests';
  end if;

  return query
  select
    r.id, r.requested_by, u.name, r.asset_type, r.item_description, r.justification,
    r.status, r.decided_by, r.decided_at, r.decision_notes,
    r.fulfilled_asset_id, a.asset_tag, r.created_at
  from asset_requests r
  join app_users u on u.id = r.requested_by
  left join assets a on a.id = r.fulfilled_asset_id
  where r.tenant_id = get_my_tenant_id()
    and (p_status is null or r.status = p_status)
  order by r.created_at desc;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_assets(p_type text DEFAULT NULL::text)
 RETURNS SETOF public.assets
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from assets
  where tenant_id = get_my_tenant_id() and is_it_support()
    and (p_type is null or type = p_type)
  order by created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_faqs(p_category text DEFAULT NULL::text)
 RETURNS SETOF public.faqs
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from faqs
  where tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
    and (p_category is null or category = p_category)
  order by sort_order, created_at;
$function$
;

CREATE OR REPLACE FUNCTION public.get_group_members(p_group_id uuid)
 RETURNS TABLE(user_id uuid, name text, email text, added_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to view group members';
  end if;
  return query
  select u.id, u.name, u.email, m.added_at
  from user_group_members m
  join app_users u on u.id = m.user_id
  join user_groups g on g.id = m.group_id
  where m.group_id = p_group_id and g.tenant_id = get_my_tenant_id()
  order by u.name;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_groups()
 RETURNS TABLE(id uuid, name text, description text, member_count bigint, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to view groups';
  end if;
  return query
  select g.id, g.name, g.description, count(m.user_id), g.created_at
  from user_groups g
  left join user_group_members m on m.group_id = g.id
  where g.tenant_id = get_my_tenant_id()
  group by g.id
  order by g.name;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_kb_articles(p_category text DEFAULT NULL::text)
 RETURNS SETOF public.kb_articles
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from kb_articles
  where tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
    and (p_category is null or category = p_category)
  order by updated_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_licenses()
 RETURNS TABLE(id uuid, asset_id uuid, asset_tag text, asset_name text, license_key text, seats_total integer, seats_used bigint, vendor text, expiry_date date, notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    l.id, l.asset_id, a.asset_tag, a.name as asset_name, l.license_key, l.seats_total,
    (select count(*) from asset_assignments aa where aa.asset_id = l.asset_id and aa.returned_at is null) as seats_used,
    l.vendor, l.expiry_date, l.notes
  from licenses l
  join assets a on a.id = l.asset_id
  where l.tenant_id = get_my_tenant_id() and is_it_support()
  order by l.expiry_date nulls last, l.created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_access_requests()
 RETURNS SETOF public.access_requests
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from access_requests where requested_by = auth.uid() order by created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_approval_queue()
 RETURNS TABLE(id uuid, tenant_id uuid, requester_id uuid, department_id uuid, cost_center_id uuid, current_stage_id uuid, item_description text, quantity integer, status text, created_at timestamp with time zone, cost_center jsonb, department jsonb, requester jsonb, current_stage jsonb, acting_on_behalf_of jsonb, offers jsonb, selected_offer jsonb, purchase_order jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with my_tenant as (
    select tenant_id from app_users where id = auth.uid()
  ),
  direct_stages as (
    select workflow_stage_id, null::uuid as delegator_user_id
    from approval_assignments
    where user_id = auth.uid()
  ),
  delegated_stages as (
    select coalesce(d.workflow_stage_id, aa.workflow_stage_id) as workflow_stage_id,
           d.delegator_user_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.delegate_user_id = auth.uid()
      and d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and (d.workflow_stage_id is null or d.workflow_stage_id = aa.workflow_stage_id)
  ),
  my_stages as (
    select * from direct_stages
    union all
    select * from delegated_stages
  ),
  offers_by_request as (
    select
      ro.request_id,
      jsonb_agg(
        jsonb_build_object(
          'id', ro.id,
          'vendor_name', ro.vendor_name,
          'quotation_amount', ro.quotation_amount,
          'quantity', ro.quantity,
          'submitted_by', ro.submitted_by,
          'submitted_at', ro.submitted_at,
          'is_selected', ro.is_selected
        ) order by ro.submitted_at asc
      ) as offers,
      jsonb_agg(
        jsonb_build_object(
          'id', ro.id,
          'vendor_name', ro.vendor_name,
          'quotation_amount', ro.quotation_amount,
          'quantity', ro.quantity,
          'submitted_by', ro.submitted_by,
          'submitted_at', ro.submitted_at,
          'is_selected', ro.is_selected
        )
      ) filter (where ro.is_selected) as selected_offer_arr
    from request_offers ro
    group by ro.request_id
  )
  select
    r.id, r.tenant_id, r.requester_id, r.department_id, r.cost_center_id,
    r.current_stage_id, r.item_description, r.quantity, r.status, r.created_at,
    jsonb_build_object('id', cc.id, 'name', cc.name, 'project_code', cc.project_code) as cost_center,
    case when dept.id is not null
      then jsonb_build_object('id', dept.id, 'name', dept.name)
      else null
    end as department,
    jsonb_build_object('id', req.id, 'name', req.name) as requester,
    jsonb_build_object(
      'id', ws.id,
      'name', ws.name,
      'approver_role', ws.approver_role,
      'threshold_amount', ws.threshold_amount,
      'requires_offer_entry', ws.requires_offer_entry,
      'requires_offer_selection', ws.requires_offer_selection,
      'blocks_offer_submitter_approval', ws.blocks_offer_submitter_approval,
      'is_finance_terminal_stage', ws.is_finance_terminal_stage
    ) as current_stage,
    case when ms.delegator_user_id is not null
      then jsonb_build_object('id', delegator.id, 'name', delegator.name)
      else null
    end as acting_on_behalf_of,
    coalesce(ofr.offers, '[]'::jsonb) as offers,
    (ofr.selected_offer_arr -> 0) as selected_offer,
    case when po.id is not null
      then jsonb_build_object(
        'id', po.id,
        'po_number', po.po_number,
        'vendor_name', po.vendor_name,
        'amount', po.amount,
        'shared_with_supplier', po.shared_with_supplier
      )
      else null
    end as purchase_order
  from requests r
  join my_stages ms on ms.workflow_stage_id = r.current_stage_id
  join cost_centers cc on cc.id = r.cost_center_id
  left join departments dept on dept.id = r.department_id
  join app_users req on req.id = r.requester_id
  join workflow_stages ws on ws.id = r.current_stage_id
  left join app_users delegator on delegator.id = ms.delegator_user_id
  left join offers_by_request ofr on ofr.request_id = r.id
  left join purchase_orders po on po.request_id = r.id
  where r.status = 'open'
    and r.tenant_id = (select tenant_id from my_tenant)
  order by r.created_at asc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_asset_requests()
 RETURNS TABLE(id uuid, asset_type text, item_description text, justification text, status text, decision_notes text, decided_at timestamp with time zone, fulfilled_asset_id uuid, fulfilled_asset_tag text, created_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    r.id, r.asset_type, r.item_description, r.justification, r.status,
    r.decision_notes, r.decided_at, r.fulfilled_asset_id, a.asset_tag, r.created_at
  from asset_requests r
  left join assets a on a.id = r.fulfilled_asset_id
  where r.requested_by = auth.uid()
  order by r.created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_procurement_orders()
 RETURNS TABLE(id uuid, po_number text, item_description text, vendor_name text, amount numeric, request_id uuid, shared_with_supplier boolean, delivered_at timestamp with time zone, completed_at timestamp with time zone, request_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    po.id,
    po.po_number,
    req.item_description,
    po.vendor_name,
    po.amount,
    po.request_id,
    COALESCE(po.shared_with_supplier, false)::boolean AS shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    req.status AS request_status
  FROM public.purchase_orders po
  INNER JOIN public.requests req ON req.id = po.request_id
  INNER JOIN public.request_offers ro ON ro.request_id = req.id
  WHERE ro.submitted_by = auth.uid()
    AND req.status = 'closed'
  ORDER BY po.generated_at DESC;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_purchase_orders()
 RETURNS TABLE(id uuid, request_id uuid, po_number text, initial_po_number text, vendor_name text, amount numeric, currency text, generated_by jsonb, generated_at timestamp with time zone, delivery_date date, shared_with_supplier boolean, delivered_at timestamp with time zone, completed_at timestamp with time zone, request jsonb, requester jsonb, department jsonb, cost_center jsonb, organization jsonb, mr_number text, project_sap_no text, payment_conditions text, terms_of_delivery text, edit_count integer, last_edited_at timestamp with time zone, last_edited_by jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with last_edit as (
    select
      pe.purchase_order_id,
      pe.edited_at,
      pe.edited_by,
      row_number() over (partition by pe.purchase_order_id order by pe.edited_at desc) as rn
    from po_edits pe
  ),
  edit_counts as (
    select purchase_order_id, count(*) as cnt
    from po_edits
    group by purchase_order_id
  )
  select
    po.id, po.request_id, po.po_number, po.initial_po_number, po.vendor_name, po.amount, po.currency,
    jsonb_build_object('id', gen.id, 'name', gen.name) as generated_by,
    po.generated_at,
    r.delivery_date,
    coalesce(po.shared_with_supplier, false) as shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    jsonb_build_object('id', r.id, 'item_description', r.item_description, 'quantity', r.quantity, 'status', r.status) as request,
    jsonb_build_object('id', req.id, 'name', req.name) as requester,
    case when dept.id is not null
      then jsonb_build_object('id', dept.id, 'name', dept.name)
      else null
    end as department,
    jsonb_build_object('id', cc.id, 'name', cc.name, 'project_code', cc.project_code) as cost_center,
    case when org.id is not null
      then jsonb_build_object('id', org.id, 'company_code', org.company_code, 'site_name', org.site_name)
      else null
    end as organization,
    r.mr_number,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    coalesce(ec.cnt, 0)::int as edit_count,
    le.edited_at as last_edited_at,
    case when le.edited_by is not null
      then jsonb_build_object('id', editor.id, 'name', editor.name)
      else null
    end as last_edited_by
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users req on req.id = r.requester_id
  left join departments dept on dept.id = r.department_id
  join cost_centers cc on cc.id = r.cost_center_id
  join app_users gen on gen.id = po.generated_by
  left join organizations org on org.id = r.organization_id
  left join last_edit le on le.purchase_order_id = po.id and le.rn = 1
  left join app_users editor on editor.id = le.edited_by
  left join edit_counts ec on ec.purchase_order_id = po.id
  where has_po_access()
    and r.tenant_id = get_my_tenant_id()
  order by po.generated_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_tenant_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select tenant_id from impersonation_sessions
     where platform_admin_id = auth.uid()
       and ended_at is null
       and started_at > now() - interval '2 hours'
     limit 1),
    (select tenant_id from app_users where id = auth.uid())
  );
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_tickets()
 RETURNS SETOF public.it_tickets
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and requester_id = auth.uid()
  order by created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_offer_detail(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'request', (
      select jsonb_build_object(
        'mr_number', r.mr_number,
        'item_description', r.item_description,
        'requester_name', ru.name,
        'created_at', r.created_at
      )
      from requests r
      join app_users ru on ru.id = r.requester_id
      where r.id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    ),
    'offers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ro.id,
        'vendor_name', ro.vendor_name,
        'quotation_amount', ro.quotation_amount,
        'quantity', ro.quantity,
        'submitted_at', ro.submitted_at,
        'submitted_by_name', su.name,
        'is_selected', ro.is_selected
      ) order by ro.submitted_at asc), '[]'::jsonb)
      from request_offers ro
      join requests r on r.id = ro.request_id
      left join app_users su on su.id = ro.submitted_by
      where ro.request_id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    ),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', rli.id,
        'material_service', rli.material_service,
        'cost_code', rli.cost_code,
        'group_code', rli.group_code,
        'place_of_use', rli.place_of_use,
        'quantity', rli.quantity,
        'unit_price', rli.unit_price,
        'total', rli.total,
        'currency', rli.currency
      ) order by rli.created_at), '[]'::jsonb)
      from request_line_items rli
      join requests r on r.id = rli.request_id
      where rli.request_id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    )
  );
$function$
;

CREATE OR REPLACE FUNCTION public.get_pending_material_request_batches()
 RETURNS TABLE(batch_id uuid, requester_id uuid, requester_name text, requested_at timestamp with time zone, pending_item_count bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select b.id, b.requester_id, u.name, b.created_at, count(i.id)
  from material_request_batches b
  join app_users u on u.id = b.requester_id
  join material_request_items i on i.batch_id = b.id and i.status = 'pending'
  where b.tenant_id = get_my_tenant_id() and has_po_access()
  group by b.id, b.requester_id, u.name, b.created_at
  order by b.created_at;
$function$
;

CREATE OR REPLACE FUNCTION public.get_pending_ticket_approvals()
 RETURNS SETOF public.it_tickets
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and is_it_support() and approval_status = 'pending'
  order by created_at asc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_po_detail(p_purchase_order_id uuid)
 RETURNS TABLE(purchase_order_id uuid, request_id uuid, po_number text, initial_po_number text, vendor_name text, po_amount numeric, currency text, generated_at timestamp with time zone, generated_by_name text, shared_with_supplier boolean, delivered_at timestamp with time zone, completed_at timestamp with time zone, mr_number text, mr_title text, mr_date date, requester_name text, delivery_date date, project_sap_no text, payment_conditions text, terms_of_delivery text, offer_quotation_amount numeric, offer_quantity integer, offer_submitted_by_name text, offer_submitted_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    po.id as purchase_order_id,
    po.request_id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name,
    po.amount as po_amount,
    po.currency,
    po.generated_at,
    generator.name as generated_by_name,
    po.shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    r.mr_number,
    r.item_description as mr_title,
    r.created_at::date as mr_date,
    requester.name as requester_name,
    r.delivery_date,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    ro.quotation_amount as offer_quotation_amount,
    ro.quantity as offer_quantity,
    submitter.name as offer_submitted_by_name,
    ro.submitted_at as offer_submitted_at
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  join app_users generator on generator.id = po.generated_by
  left join request_offers ro
    on ro.request_id = po.request_id
    and ro.vendor_name = po.vendor_name
  left join app_users submitter on submitter.id = ro.submitted_by
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id()
  order by ro.submitted_at desc
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_po_pdf_data(p_purchase_order_id uuid)
 RETURNS TABLE(purchase_order_id uuid, po_number text, initial_po_number text, company text, po_total numeric, currency text, po_date date, mr_number text, mr_title text, requester_name text, purchaser_name text, delivery_date date, organization_name text, project_sap_no text, payment_conditions text, terms_of_delivery text, primary_cost_code text, line_items jsonb, approvals jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    po.id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name,
    po.amount,
    po.currency,
    po.generated_at::date,
    r.mr_number,
    r.item_description,
    requester.name,
    purchaser.name,
    r.delivery_date,
    o.site_name,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    (
      select rli.cost_code
      from request_line_items rli
      where rli.request_id = r.id
      order by rli.created_at
      limit 1
    ),
    coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'material_service', rli.material_service,
          'cost_code', rli.cost_code,
          'place_of_use', rli.place_of_use,
          'quantity', rli.quantity,
          'unit_price', rli.unit_price,
          'total', rli.total,
          'currency', rli.currency
        ) order by rli.created_at)
        from request_line_items rli
        where rli.request_id = r.id
      ),
      '[]'::jsonb
    ),
    coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'stage_name', ws.name,
          'approver_role', ws.approver_role,
          'approver_name', au.name,
          'sequence_order', ws.sequence_order,
          'acted_at', aa.acted_at
        ) order by ws.sequence_order, aa.acted_at)
        from approval_actions aa
        join workflow_stages ws on ws.id = aa.workflow_stage_id
        join app_users au on au.id = aa.approver_id
        where aa.request_id = r.id
          and aa.decision = 'approved'
          and aa.acted_at = (
            select max(aa2.acted_at)
            from approval_actions aa2
            where aa2.request_id = aa.request_id
              and aa2.workflow_stage_id = aa.workflow_stage_id
              and aa2.decision = 'approved'
          )
      ),
      '[]'::jsonb
    )
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join organizations o on o.id = r.organization_id
  left join request_offers ro on ro.request_id = r.id
  left join app_users purchaser on purchaser.id = ro.submitted_by
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id();
$function$
;

CREATE OR REPLACE FUNCTION public.get_priority_levels()
 RETURNS SETOF public.priority_levels
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from priority_levels where tenant_id = get_my_tenant_id() order by sort_order;
$function$
;

CREATE OR REPLACE FUNCTION public.get_problem_tickets(p_problem_id uuid)
 RETURNS SETOF public.it_tickets
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select t.* from it_tickets t
  join problem_tickets pt on pt.ticket_id = t.id
  where pt.problem_id = p_problem_id and t.tenant_id = get_my_tenant_id() and is_it_support()
  order by t.created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_problems()
 RETURNS SETOF public.problems
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from problems
  where tenant_id = get_my_tenant_id() and is_it_support()
  order by
    case status when 'open' then 0 when 'investigating' then 1 when 'resolved' then 2 else 3 end,
    created_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_procurement_info(p_organization_id uuid DEFAULT NULL::uuid, p_initial_po_number text DEFAULT NULL::text, p_company text DEFAULT NULL::text, p_purchaser text DEFAULT NULL::text, p_mr_number text DEFAULT NULL::text, p_po_number text DEFAULT NULL::text, p_po_status text DEFAULT NULL::text)
 RETURNS TABLE(request_id uuid, purchase_order_id uuid, initial_po_number text, po_number text, po_total numeric, currency text, company text, requester_name text, mr_originator_name text, mr_title text, mr_number text, mr_created_at timestamp with time zone, po_date date, delivery_date date, shared_with_supplier boolean, delivered_at timestamp with time zone, completed_at timestamp with time zone, po_status text, pdf_storage_path text, pdf_generated_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    r.id as request_id,
    po.id as purchase_order_id,
    po.initial_po_number,
    po.po_number,
    po.amount as po_total,
    po.currency,
    po.vendor_name as company,
    requester.name as requester_name,
    purchaser.name as mr_originator_name,
    r.item_description as mr_title,
    r.mr_number,
    r.created_at as mr_created_at,
    po.generated_at::date as po_date,
    r.delivery_date,
    po.shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    case
      when po.completed_at is not null then 'completed'
      when po.delivered_at is not null then 'delivered'
      when po.shared_with_supplier then 'shared'
      else 'pending'
    end as po_status,
    po.pdf_storage_path,
    po.pdf_generated_at
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join request_offers ro on ro.request_id = r.id
  left join app_users purchaser on purchaser.id = ro.submitted_by
  where r.tenant_id = get_my_tenant_id()
    and (p_organization_id is null or r.organization_id = p_organization_id)
    and (p_initial_po_number is null or po.initial_po_number ilike '%' || p_initial_po_number || '%')
    and (p_company is null or po.vendor_name ilike '%' || p_company || '%')
    and (p_purchaser is null or purchaser.name ilike '%' || p_purchaser || '%')
    and (p_mr_number is null or r.mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po.po_number ilike '%' || p_po_number || '%')
    and (
      p_po_status is null or p_po_status = 'All' or
      (case
        when po.completed_at is not null then 'completed'
        when po.delivered_at is not null then 'delivered'
        when po.shared_with_supplier then 'shared'
        else 'pending'
      end) = p_po_status
    )
  order by po.generated_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_request_tracking(p_organization_id uuid DEFAULT NULL::uuid, p_mr_number text DEFAULT NULL::text, p_po_number text DEFAULT NULL::text, p_company text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_subcontractor text DEFAULT NULL::text, p_mr_originator text DEFAULT NULL::text, p_pending_authority text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_cost_code text DEFAULT NULL::text, p_place_of_use text DEFAULT NULL::text, p_mr_date_from date DEFAULT NULL::date, p_mr_date_to date DEFAULT NULL::date, p_po_date_from date DEFAULT NULL::date, p_po_date_to date DEFAULT NULL::date, p_delivery_date_from date DEFAULT NULL::date, p_delivery_date_to date DEFAULT NULL::date, p_market_offer_date_from date DEFAULT NULL::date, p_market_offer_date_to date DEFAULT NULL::date, p_closing_date_from date DEFAULT NULL::date, p_closing_date_to date DEFAULT NULL::date)
 RETURNS TABLE(request_id uuid, purchase_order_id uuid, mr_number text, mr_date date, mr_created_at timestamp with time zone, mr_title text, subcontractor text, requester_name text, order_placer_name text, initial_po_number text, po_number text, po_date date, delivery_date date, market_offer_date date, company text, po_total numeric, currency text, closing_date date, status text, lifecycle_status text, pending_authority text, cost_code text, place_of_use text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
    select
      r.id as request_id,
      po.id as purchase_order_id,
      r.mr_number,
      r.created_at::date as mr_date,
      r.created_at as mr_created_at,
      r.item_description as mr_title,
      r.subcontractor,
      requester.name as requester_name,
      submitter.name as order_placer_name,
      po.initial_po_number,
      po.po_number,
      po.generated_at::date as po_date,
      r.delivery_date,
      ro.submitted_at::date as market_offer_date,
      coalesce(po.vendor_name, ro.vendor_name) as company,
      po.amount as po_total,
      po.currency,
      po.completed_at::date as closing_date,
      r.status,
      case
        when r.status = 'rejected' then 'rejected'
        when r.status = 'cancelled' then 'cancelled'
        when po.completed_at is not null then 'closed_order'
        when po.id is not null then 'open_order'
        when ro.id is not null then 'pending_po'
        when ws.requires_offer_entry then 'pending_bid_entry'
        else 'pending_mr'
      end as lifecycle_status,
      ws.name as pending_authority,
      rli.cost_code,
      rli.place_of_use
    from requests r
    join app_users requester on requester.id = r.requester_id
    left join organizations o on o.id = r.organization_id
    left join purchase_orders po on po.request_id = r.id
    left join request_offers ro on ro.request_id = r.id
    left join app_users submitter on submitter.id = ro.submitted_by
    left join workflow_stages ws on ws.id = r.current_stage_id
    left join lateral (
      select cost_code, place_of_use
      from request_line_items rli
      where rli.request_id = r.id
      order by rli.created_at
      limit 1
    ) rli on true
    where r.tenant_id = get_my_tenant_id()
      and (p_organization_id is null or r.organization_id = p_organization_id)
  )
  select *
  from base
  where (p_mr_number is null or mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po_number ilike '%' || p_po_number || '%')
    and (p_company is null or company ilike '%' || p_company || '%')
    and (p_description is null or mr_title ilike '%' || p_description || '%')
    and (p_subcontractor is null or subcontractor ilike '%' || p_subcontractor || '%')
    and (p_mr_originator is null or requester_name ilike '%' || p_mr_originator || '%')
    and (p_pending_authority is null or pending_authority ilike '%' || p_pending_authority || '%')
    and (p_cost_code is null or cost_code ilike '%' || p_cost_code || '%')
    and (p_place_of_use is null or place_of_use ilike '%' || p_place_of_use || '%')
    and (p_mr_date_from is null or mr_date >= p_mr_date_from)
    and (p_mr_date_to is null or mr_date <= p_mr_date_to)
    and (p_po_date_from is null or po_date >= p_po_date_from)
    and (p_po_date_to is null or po_date <= p_po_date_to)
    and (p_delivery_date_from is null or delivery_date >= p_delivery_date_from)
    and (p_delivery_date_to is null or delivery_date <= p_delivery_date_to)
    and (p_market_offer_date_from is null or market_offer_date >= p_market_offer_date_from)
    and (p_market_offer_date_to is null or market_offer_date <= p_market_offer_date_to)
    and (p_closing_date_from is null or closing_date >= p_closing_date_from)
    and (p_closing_date_to is null or closing_date <= p_closing_date_to)
    and (
      p_status is null or p_status = 'All' or
      (p_status = 'pending_all' and lifecycle_status in ('pending_mr', 'pending_bid_entry', 'pending_po')) or
      (p_status <> 'pending_all' and lifecycle_status = p_status)
    )
  order by mr_date desc;
$function$
;

CREATE OR REPLACE FUNCTION public.get_sla_policies()
 RETURNS SETOF public.sla_policies
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from sla_policies where tenant_id = get_my_tenant_id()
  order by case priority when 'urgent' then 0 when 'high' then 1 when 'medium' then 2 else 3 end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_support_team_members(p_team_id uuid)
 RETURNS TABLE(user_id uuid, name text, email text, added_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to view team members';
  end if;
  return query
  select u.id, u.name, u.email, m.added_at
  from support_team_members m
  join app_users u on u.id = m.user_id
  join support_teams st on st.id = m.team_id
  where m.team_id = p_team_id and st.tenant_id = get_my_tenant_id()
  order by u.name;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_support_teams()
 RETURNS TABLE(id uuid, name text, description text, is_active boolean, member_count bigint, created_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select st.id, st.name, st.description, st.is_active, count(m.user_id), st.created_at
  from support_teams st
  left join support_team_members m on m.team_id = st.id
  where st.tenant_id = get_my_tenant_id()
  group by st.id
  order by st.name;
$function$
;

CREATE OR REPLACE FUNCTION public.get_ticket_categories()
 RETURNS SETOF public.ticket_categories
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from ticket_categories where tenant_id = get_my_tenant_id() order by name;
$function$
;

CREATE OR REPLACE FUNCTION public.get_vendor_evaluation()
 RETURNS TABLE(vendor_account_id uuid, account_code text, vendor_name text, contact_name text, contact_phone text, contact_email text, is_active boolean, total_pos bigint, total_po_value numeric, delivered_pos bigint, avg_days_to_deliver numeric, on_time_delivery_pct numeric, fulfillment_accuracy_pct numeric, over_delivery_pct numeric, under_delivery_pct numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (is_finance_team_member(null) or has_po_access()) then
    raise exception 'not authorized to view vendor evaluation data';
  end if;

  return query
  select
    v.vendor_account_id, v.account_code, v.vendor_name, v.contact_name,
    v.contact_phone, v.contact_email, v.is_active, v.total_pos, v.total_po_value,
    v.delivered_pos, v.avg_days_to_deliver, v.on_time_delivery_pct,
    v.fulfillment_accuracy_pct, v.over_delivery_pct, v.under_delivery_pct
  from v_vendor_evaluation v
  where v.tenant_id = get_my_tenant_id()
  order by v.total_pos desc nulls last, v.vendor_name;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.grant_delegation(p_delegate_user_id uuid, p_workflow_stage_id uuid DEFAULT NULL::uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS public.approval_delegations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_delegator_tenant uuid;
  v_delegate_tenant  uuid;
  v_starts_at        timestamptz := coalesce(p_starts_at, now());
  v_created          approval_delegations%ROWTYPE;
BEGIN
  IF p_delegate_user_id IS NULL OR p_ends_at IS NULL THEN
    RAISE EXCEPTION 'delegate_user_id and ends_at are required';
  END IF;
  IF p_delegate_user_id = auth.uid() THEN
    RAISE EXCEPTION 'you cannot delegate to yourself';
  END IF;
  IF p_ends_at <= v_starts_at THEN
    RAISE EXCEPTION 'ends_at must be after starts_at';
  END IF;

  SELECT tenant_id INTO v_delegator_tenant FROM app_users WHERE id = auth.uid();
  IF v_delegator_tenant IS NULL THEN
    RAISE EXCEPTION 'delegator profile not found';
  END IF;

  SELECT tenant_id INTO v_delegate_tenant FROM app_users WHERE id = p_delegate_user_id;
  IF v_delegate_tenant IS NULL THEN
    RAISE EXCEPTION 'delegate user not found';
  END IF;
  IF v_delegate_tenant != v_delegator_tenant THEN
    RAISE EXCEPTION 'delegate must belong to the same tenant';
  END IF;

  IF p_workflow_stage_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM approval_assignments
      WHERE user_id = auth.uid() AND workflow_stage_id = p_workflow_stage_id
    ) THEN
      RAISE EXCEPTION 'you do not hold approval authority for that stage, so you cannot delegate it';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM approval_assignments WHERE user_id = auth.uid()) THEN
      RAISE EXCEPTION 'you do not hold any approval assignments to delegate';
    END IF;
  END IF;

  BEGIN
    INSERT INTO approval_delegations (
      tenant_id, delegator_user_id, delegate_user_id, workflow_stage_id, starts_at, ends_at, status
    ) VALUES (
      v_delegator_tenant, auth.uid(), p_delegate_user_id, p_workflow_stage_id, v_starts_at, p_ends_at, 'active'
    ) RETURNING * INTO v_created;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'an overlapping active delegation already exists for this delegator, delegate, and stage';
  END;

  RETURN v_created;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.handle_updated_at_generic()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.updated_at = now();
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.has_module_role(p_module text, p_roles text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    exists (
      select 1 from public.app_users
      where id = auth.uid() and is_platform_admin
    )
    or exists (
      select 1 from public.staff_roles
      where user_id = auth.uid()
        and module = p_module
        and role = any(p_roles)
        and tenant_id = public.get_my_tenant_id()
    );
$function$
;

CREATE OR REPLACE FUNCTION public.has_po_access()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    is_platform_admin()
    or exists (
      select 1
      from approval_assignments aa
      join workflow_stages ws on ws.id = aa.workflow_stage_id
      where aa.user_id = auth.uid()
        and ws.next_stage_low_id is null
        and ws.next_stage_high_id is null
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      join workflow_stages ws on ws.id = aa.workflow_stage_id
      where d.delegate_user_id = auth.uid()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and ws.next_stage_low_id is null
        and ws.next_stage_high_id is null
        and (d.workflow_stage_id is null or d.workflow_stage_id = ws.id)
    );
$function$
;

CREATE OR REPLACE FUNCTION public.has_receipt_access()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM material_receipt_assignments
    WHERE user_id = auth.uid() AND tenant_id = get_my_tenant_id()
  );
$function$
;

create or replace view "public"."hr_employee_current_compensation" as  SELECT DISTINCT ON (employee_id) employee_id,
    tenant_id,
    basic_salary,
    currency,
    effective_date,
    contract_reference
   FROM public.hr_employee_compensation
  WHERE (effective_date <= CURRENT_DATE)
  ORDER BY employee_id, effective_date DESC, created_at DESC;


CREATE OR REPLACE FUNCTION public.is_business_dev()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.has_module_role('bd', array['admin','manager','member']);
$function$
;

CREATE OR REPLACE FUNCTION public.is_finance_team_member(p_role text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM finance_team_members
      WHERE user_id = auth.uid()
        AND tenant_id = get_my_tenant_id()
        AND (p_role IS NULL OR role = p_role)
    );
$function$
;

CREATE OR REPLACE FUNCTION public.is_hr_team_member(p_role text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM hr_team_members
      WHERE user_id = auth.uid()
        AND tenant_id = get_my_tenant_id()
        AND (p_role IS NULL OR role = p_role)
    );
$function$
;

CREATE OR REPLACE FUNCTION public.is_it_support()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.has_module_role('it', array['admin','manager','member']);
$function$
;

CREATE OR REPLACE FUNCTION public.is_payroll_approver()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM payroll_approvers
      WHERE user_id = auth.uid()
        AND tenant_id = get_my_tenant_id()
        AND is_active
    );
$function$
;

CREATE OR REPLACE FUNCTION public.is_platform_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE((SELECT is_platform_admin FROM app_users WHERE id = auth.uid()), false);
$function$
;

create or replace view "public"."line_item_receipt_status" as  SELECT rli.id AS line_item_id,
    rli.request_id,
    rli.material_service,
    rli.quantity AS ordered_qty,
    COALESCE(sum(lir.received_qty), (0)::numeric) AS received_qty,
        CASE
            WHEN (COALESCE(sum(lir.received_qty), (0)::numeric) = (0)::numeric) THEN 'none'::text
            WHEN (COALESCE(sum(lir.received_qty), (0)::numeric) < rli.quantity) THEN 'partial'::text
            WHEN (COALESCE(sum(lir.received_qty), (0)::numeric) = rli.quantity) THEN 'full'::text
            ELSE 'over'::text
        END AS receipt_status,
    max(lir.received_at) AS last_received_at
   FROM (public.request_line_items rli
     LEFT JOIN public.line_item_receipts lir ON ((lir.line_item_id = rli.id)))
  GROUP BY rli.id, rli.request_id, rli.material_service, rli.quantity;


CREATE OR REPLACE FUNCTION public.link_ticket_to_problem(p_problem_id uuid, p_ticket_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
begin
  if not is_it_support() then
    raise exception 'not authorized to link tickets to problems';
  end if;
  if not exists (select 1 from problems where id = p_problem_id and tenant_id = v_tenant) then
    raise exception 'problem not found';
  end if;
  if not exists (select 1 from it_tickets where id = p_ticket_id and tenant_id = v_tenant) then
    raise exception 'ticket not found';
  end if;

  insert into problem_tickets (problem_id, ticket_id, tenant_id)
  values (p_problem_id, p_ticket_id, v_tenant)
  on conflict do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.link_vendor_account_on_offer()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid;
begin
  if NEW.vendor_account_id is null then
    select tenant_id into v_tenant_id from requests where id = NEW.request_id;
    NEW.vendor_account_id := resolve_or_create_vendor_account(v_tenant_id, NEW.vendor_name);
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_receipt_assignees()
 RETURNS TABLE(id uuid, user_id uuid, user_name text, assigned_by_name text, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT mra.id, mra.user_id, u.name, ab.name, mra.created_at
  FROM material_receipt_assignments mra
  JOIN app_users u ON u.id = mra.user_id
  JOIN app_users ab ON ab.id = mra.assigned_by
  WHERE mra.tenant_id = get_my_tenant_id()
  ORDER BY mra.created_at DESC;
$function$
;

CREATE OR REPLACE FUNCTION public.next_asset_tag(p_tenant_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(asset_tag, '^AST-', ''), asset_tag)::int), 0) + 1
  into v_next_num
  from assets
  where tenant_id = p_tenant_id and asset_tag like 'AST-%';

  return 'AST-' || lpad(v_next_num::text, 5, '0');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.next_doc_number(p_tenant_id uuid, p_doc_type text, p_prefix text, p_pad integer DEFAULT 4)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  yr text := to_char(now(), 'YYYY');
  n int;
begin
  insert into public.doc_sequences (tenant_id, doc_type, year, last_number)
  values (p_tenant_id, p_doc_type, yr, 1)
  on conflict (tenant_id, doc_type, year)
  do update set last_number = public.doc_sequences.last_number + 1
  returning last_number into n;

  return p_prefix || '-' || yr || '-' || lpad(n::text, p_pad, '0');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.next_material_catalog_code(p_tenant_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(code, '^MAT-', ''), code)::int), 0) + 1
  into v_next_num
  from material_catalog
  where tenant_id = p_tenant_id and code like 'MAT-%';

  return 'MAT-' || lpad(v_next_num::text, 5, '0');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.next_mr_number(p_tenant_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(mr_number, '^MR-', ''), mr_number)::int), 0) + 1
  into v_next_num
  from requests
  where tenant_id = p_tenant_id and mr_number like 'MR-%';

  return 'MR-' || lpad(v_next_num::text, 5, '0');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.next_problem_number(p_tenant_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(problem_number, '^PRB-', ''), problem_number)::int), 0) + 1
  into v_next_num
  from problems
  where tenant_id = p_tenant_id and problem_number like 'PRB-%';

  return 'PRB-' || lpad(v_next_num::text, 5, '0');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.next_ticket_number(p_tenant_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(ticket_number, '^TCK-', ''), ticket_number)::int), 0) + 1
  into v_next_num
  from it_tickets
  where tenant_id = p_tenant_id and ticket_number like 'TCK-%';

  return 'TCK-' || lpad(v_next_num::text, 5, '0');
end;
$function$
;

create or replace view "public"."petty_cash_float_balances" as  SELECT f.id AS petty_cash_float_id,
    f.tenant_id,
    f.cost_center_id,
    f.custodian_user_id,
    f.float_name,
    f.ceiling_amount,
    f.currency,
    f.is_active,
    COALESCE(r.total_replenished, (0)::numeric) AS total_replenished,
    COALESCE(s.total_spent, (0)::numeric) AS total_spent,
    (COALESCE(r.total_replenished, (0)::numeric) - COALESCE(s.total_spent, (0)::numeric)) AS current_balance
   FROM ((public.petty_cash_floats f
     LEFT JOIN ( SELECT petty_cash_replenishments.petty_cash_float_id,
            sum(petty_cash_replenishments.amount) AS total_replenished
           FROM public.petty_cash_replenishments
          GROUP BY petty_cash_replenishments.petty_cash_float_id) r ON ((r.petty_cash_float_id = f.id)))
     LEFT JOIN ( SELECT expenditure_slips.petty_cash_float_id,
            sum(expenditure_slips.amount) AS total_spent
           FROM public.expenditure_slips
          WHERE (expenditure_slips.petty_cash_float_id IS NOT NULL)
          GROUP BY expenditure_slips.petty_cash_float_id) s ON ((s.petty_cash_float_id = f.id)));


CREATE OR REPLACE FUNCTION public.platform_has_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from app_users where is_platform_admin = true);
$function$
;

CREATE OR REPLACE FUNCTION public.post_issue_items_to_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_issue goods_issues%ROWTYPE;
BEGIN
  SELECT * INTO v_issue FROM goods_issues WHERE id = NEW.goods_issue_id;

  INSERT INTO stock_movements (tenant_id, warehouse_id, material_catalog_id, material_name, unit, movement_type, quantity, reference_type, reference_id, recorded_by)
  VALUES (v_issue.tenant_id, v_issue.warehouse_id, NEW.material_catalog_id, NEW.material_description, NEW.unit, 'out', NEW.delivered_qty, 'goods_issue', NEW.id, v_issue.warehouse_officer_id);

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.post_receipt_to_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_line request_line_items%ROWTYPE;
  v_tenant_id uuid;
BEGIN
  IF NEW.warehouse_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_line FROM request_line_items WHERE id = NEW.line_item_id;
  SELECT r.tenant_id INTO v_tenant_id FROM requests r WHERE r.id = v_line.request_id;

  INSERT INTO stock_movements (tenant_id, warehouse_id, material_name, unit, movement_type, quantity, reference_type, reference_id, recorded_by)
  VALUES (v_tenant_id, NEW.warehouse_id, v_line.material_service, NULL, 'in', NEW.received_qty, 'goods_receipt', NEW.id, NEW.received_by);

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_invoice_organization_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization cannot be changed on an existing invoice (was %, attempted %) -- void and re-enter under the correct organization instead', old.organization_id, new.organization_id;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.protect_delegation_immutable_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.tenant_id           IS DISTINCT FROM OLD.tenant_id
     OR NEW.delegator_user_id IS DISTINCT FROM OLD.delegator_user_id
     OR NEW.delegate_user_id  IS DISTINCT FROM OLD.delegate_user_id
     OR NEW.workflow_stage_id IS DISTINCT FROM OLD.workflow_stage_id
     OR NEW.starts_at         IS DISTINCT FROM OLD.starts_at
     OR NEW.ends_at           IS DISTINCT FROM OLD.ends_at
  THEN
    RAISE EXCEPTION 'only status can be changed on an existing delegation -- revoke it and create a new one instead';
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.record_approval_decision(p_request_id uuid, p_decision text, p_comment text DEFAULT NULL::text, p_acting_on_behalf_of uuid DEFAULT NULL::uuid, p_selected_offer_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(out_request_id uuid, out_status text, out_stage_id uuid, out_purchase_order_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request       requests%rowtype;
  v_stage         workflow_stages%rowtype;
  v_next_stage    workflow_stages%rowtype;
  v_next_stage_id uuid;
  v_offer         request_offers%rowtype;
  v_po_id         uuid;
  v_po_number     text;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'open' then
    raise exception 'request is not open (status: %)', v_request.status;
  end if;
  if v_request.current_stage_id is null then
    raise exception 'request has no current stage';
  end if;
  if not can_act_on_stage(v_request.current_stage_id) then
    raise exception 'not authorized to act on this stage';
  end if;

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;

  -- Anti-collusion guard: if this stage blocks the offer submitter from
  -- approving their own request, check ALL offers on the request now
  -- that there can be several -- not just "the latest one" as before.
  if v_stage.blocks_offer_submitter_approval then
    if exists (
      select 1 from request_offers
      where request_id = p_request_id and submitted_by = auth.uid()
    ) then
      raise exception 'you submitted an offer on this request -- a different reviewer must act on it at this stage';
    end if;
  end if;

  insert into approval_actions
    (request_id, workflow_stage_id, approver_id, acted_on_behalf_of, decision, comment)
  values
    (p_request_id, v_stage.id, auth.uid(), p_acting_on_behalf_of, p_decision, p_comment);

  if p_decision = 'rejected' then
    update requests set status = 'rejected', updated_at = now() where id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_rejected',
      'Request rejected',
      format('Your request "%s" was rejected at the %s stage.', v_request.item_description, v_stage.name),
      p_request_id
    );

    return query select p_request_id, 'rejected'::text, v_stage.id, null::uuid;
    return;
  end if;

  if v_stage.is_finance_terminal_stage then
    update requests
    set status = 'closed', current_stage_id = null, updated_at = now()
    where id = p_request_id;

    select id into v_po_id from purchase_orders where request_id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_closed',
      'Request closed',
      format('Your request "%s" has been closed. The purchase order is ready for procurement.', v_request.item_description),
      p_request_id,
      v_po_id
    );

    return query select p_request_id, 'closed'::text, null::uuid, v_po_id;
    return;
  end if;

  -- Selection happens exactly once, at the stage flagged
  -- requires_offer_selection (Budget Controller). Every other stage --
  -- before offers exist, or after a winner has already been picked --
  -- just reads whichever offer is currently marked selected.
  if v_stage.requires_offer_selection then
    if p_selected_offer_id is null then
      raise exception 'select a winning offer before approving';
    end if;
    if not exists (
      select 1 from request_offers
      where id = p_selected_offer_id and request_id = p_request_id
    ) then
      raise exception 'selected offer does not belong to this request';
    end if;

    update request_offers
    set is_selected = (id = p_selected_offer_id)
    where request_id = p_request_id;

    select * into v_offer from request_offers where id = p_selected_offer_id;
  else
    select * into v_offer from request_offers
    where request_id = p_request_id and is_selected
    limit 1;
  end if;

  if v_stage.threshold_amount is not null then
    if not found and v_offer.id is null then
      raise exception 'no offer on file to evaluate threshold';
    end if;
    if v_offer.quotation_amount <= v_stage.threshold_amount then
      v_next_stage_id := v_stage.next_stage_low_id;
    else
      v_next_stage_id := v_stage.next_stage_high_id;
    end if;
  else
    v_next_stage_id := v_stage.next_stage_low_id;
  end if;

  if v_next_stage_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  select * into v_next_stage from workflow_stages where id = v_next_stage_id;

  if v_next_stage.is_finance_terminal_stage then
    if v_offer.id is null then
      raise exception 'no offer on file to generate a purchase order';
    end if;
    if exists (select 1 from purchase_orders where request_id = p_request_id) then
      raise exception 'a purchase order already exists for this request';
    end if;

    v_po_number := 'PO-' || to_char(now(), 'YYYY') || '-'
                   || lpad(nextval('public.po_number_seq')::text, 5, '0');

    insert into purchase_orders (request_id, po_number, vendor_name, vendor_account_id, amount, generated_by)
    values (p_request_id, v_po_number, v_offer.vendor_name, v_offer.vendor_account_id, v_offer.quotation_amount, auth.uid())
    returning id into v_po_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'purchase_order_generated',
      'Purchase order generated',
      format('A purchase order (%s) has been generated for your request "%s".', v_po_number, v_request.item_description),
      p_request_id,
      v_po_id
    );
  end if;

  update requests
  set current_stage_id = v_next_stage_id, updated_at = now()
  where id = p_request_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select distinct
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('Request "%s" is awaiting your approval at the %s stage.', v_request.item_description, v_next_stage.name),
    p_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage_id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage_id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  return query select p_request_id, 'open'::text, v_next_stage_id, v_po_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_goods_issue(p_warehouse_id uuid, p_project_label text, p_voucher_no text, p_received_by_name text, p_approved_by_name text, p_items jsonb)
 RETURNS public.goods_issues
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_issue goods_issues%ROWTYPE;
  v_item jsonb;
  v_item_no int := 1;
BEGIN
  IF NOT has_receipt_access() THEN
    RAISE EXCEPTION 'not authorized to record goods issues';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM warehouses WHERE id = p_warehouse_id AND tenant_id = get_my_tenant_id()) THEN
    RAISE EXCEPTION 'warehouse not found';
  END IF;

  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'a goods issue needs at least one line item';
  END IF;

  INSERT INTO goods_issues (tenant_id, warehouse_id, project_label, voucher_no, warehouse_officer_id, received_by_name, approved_by_name)
  VALUES (get_my_tenant_id(), p_warehouse_id, p_project_label, p_voucher_no, auth.uid(), p_received_by_name, p_approved_by_name)
  RETURNING * INTO v_issue;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO goods_issue_items (
      goods_issue_id, item_no, material_catalog_id, material_description,
      cost_center_id, unit, requested_qty, delivered_qty, remarks
    )
    VALUES (
      v_issue.id, v_item_no,
      NULLIF(v_item->>'material_catalog_id', '')::uuid,
      v_item->>'material_description',
      NULLIF(v_item->>'cost_center_id', '')::uuid,
      v_item->>'unit',
      NULLIF(v_item->>'requested_qty', '')::numeric,
      (v_item->>'delivered_qty')::numeric,
      v_item->>'remarks'
    );
    v_item_no := v_item_no + 1;
  END LOOP;

  RETURN v_issue;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.record_line_item_receipt(p_line_item_id uuid, p_received_qty numeric, p_note text DEFAULT NULL::text)
 RETURNS public.line_item_receipts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request requests%ROWTYPE;
  v_line    request_line_items%ROWTYPE;
  v_already numeric;
  v_row     line_item_receipts%ROWTYPE;
BEGIN
  IF p_received_qty IS NULL OR p_received_qty <= 0 THEN
    RAISE EXCEPTION 'received quantity must be greater than zero';
  END IF;

  SELECT * INTO v_line FROM request_line_items WHERE id = p_line_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'line item not found';
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_line.request_id;
  IF v_request.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this request';
  END IF;
  IF v_request.status != 'closed' THEN
    RAISE EXCEPTION 'goods can only be received against a closed request (PO already generated)';
  END IF;
  IF NOT has_receipt_access() THEN
    RAISE EXCEPTION 'not authorized to record receipts';
  END IF;

  SELECT COALESCE(SUM(received_qty), 0) INTO v_already
  FROM line_item_receipts WHERE line_item_id = p_line_item_id;

  IF v_already + p_received_qty > v_line.quantity * 2 THEN
    RAISE EXCEPTION 'received quantity (%) is more than double what was ordered (%) -- check for a data entry error',
      v_already + p_received_qty, v_line.quantity;
  END IF;

  INSERT INTO line_item_receipts (line_item_id, received_qty, received_by, note)
  VALUES (p_line_item_id, p_received_qty, auth.uid(), p_note)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.record_line_item_receipt(p_line_item_id uuid, p_received_qty numeric, p_warehouse_id uuid, p_voucher_no text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS public.line_item_receipts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.line_item_receipts;
BEGIN
  v_row := public.record_line_item_receipt(p_line_item_id, p_received_qty, p_note);

  UPDATE line_item_receipts
  SET warehouse_id = p_warehouse_id, voucher_no = p_voucher_no
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.record_po_pdf(p_purchase_order_id uuid, p_storage_path text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update purchase_orders po
  set pdf_storage_path = p_storage_path,
      pdf_generated_at = now()
  from requests r
  where po.id = p_purchase_order_id
    and po.request_id = r.id
    and r.tenant_id = get_my_tenant_id();

  if not found then
    raise exception 'Purchase order not found or not accessible';
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_ticket_approval(p_ticket_id uuid, p_decision text, p_notes text DEFAULT NULL::text)
 RETURNS public.it_tickets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;
  if not is_it_support() then
    raise exception 'not authorized to approve tickets';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status != 'pending' then
    raise exception 'ticket is not pending approval';
  end if;

  update it_tickets
  set approval_status = p_decision,
      approved_by = auth.uid(),
      approved_at = now(),
      approval_notes = p_notes,
      status = case when p_decision = 'rejected' then 'closed' else status end,
      resolution_notes = case when p_decision = 'rejected'
        then coalesce(resolution_notes, 'Rejected at approval: ' || coalesce(p_notes, 'no reason given'))
        else resolution_notes end,
      closed_at = case when p_decision = 'rejected' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_ticket.tenant_id,
    v_ticket.requester_id,
    'ticket_approval_decision',
    'Ticket ' || v_ticket.ticket_number || ' ' || p_decision,
    format('Your ticket "%s" was %s.', v_ticket.subject, p_decision)
  );

  return v_ticket;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reject_all_material_request_items(p_batch_id uuid, p_message text)
 RETURNS SETOF public.material_request_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item_id uuid;
begin
  for v_item_id in
    select id from material_request_items
    where batch_id = p_batch_id and tenant_id = get_my_tenant_id() and status = 'pending'
  loop
    return next reject_material_request_item(v_item_id, p_message);
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reject_material_request_item(p_item_id uuid, p_message text)
 RETURNS public.material_request_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item material_request_items%rowtype;
  v_batch material_request_batches%rowtype;
begin
  if not has_po_access() then
    raise exception 'not authorized to reject material requests';
  end if;

  if p_message is null or trim(p_message) = '' then
    raise exception 'a message is required to reject a material request item';
  end if;

  select * into v_item from material_request_items
  where id = p_item_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'material request item not found';
  end if;

  if v_item.status <> 'pending' then
    raise exception 'this item has already been decided';
  end if;

  update material_request_items
  set status = 'rejected', rejection_message = trim(p_message), decided_by = auth.uid(), decided_at = now()
  where id = p_item_id
  returning * into v_item;

  select * into v_batch from material_request_batches where id = v_item.batch_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_item.tenant_id, v_batch.requester_id, 'material_request_rejected',
    'Material request rejected',
    format('"%s" was rejected: %s', v_item.name, trim(p_message))
  );

  return v_item;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reject_payroll_run(p_run_id uuid, p_reason text)
 RETURNS public.hr_payroll_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_payroll_approver() THEN
    RAISE EXCEPTION 'not authorized to reject payroll';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a rejection reason is required';
  END IF;

  -- Sent back to draft (not a separate 'rejected' limbo) so HR can fix
  -- and resubmit through the same path -- rejected_* columns keep the
  -- audit trail of the fact it happened.
  UPDATE hr_payroll_runs
  SET status = 'draft', rejected_by = auth.uid(), rejected_at = now(), rejection_reason = p_reason,
      submitted_at = NULL
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'pending_approval'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not pending approval';
  END IF;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.remove_group_member(p_group_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage group membership';
  end if;
  delete from user_group_members
  where group_id = p_group_id and user_id = p_user_id
    and group_id in (select id from user_groups where tenant_id = get_my_tenant_id());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.remove_support_team_member(p_team_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage team membership';
  end if;
  delete from support_team_members
  where team_id = p_team_id and user_id = p_user_id
    and team_id in (select id from support_teams where tenant_id = get_my_tenant_id());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_or_create_vendor_account(p_tenant_id uuid, p_vendor_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_account_id uuid;
  v_next_num   int;
  v_code       text;
begin
  if p_vendor_name is null or trim(p_vendor_name) = '' then
    return null;
  end if;

  select id into v_account_id
  from accounts
  where tenant_id = p_tenant_id
    and account_type in ('vendor', 'both')
    and lower(trim(name)) = lower(trim(p_vendor_name))
  limit 1;

  if found then
    return v_account_id;
  end if;

  select coalesce(max(nullif(regexp_replace(account_code, '^VEN-', ''), account_code)::int), 0) + 1
  into v_next_num
  from accounts
  where tenant_id = p_tenant_id
    and account_code like 'VEN-%';

  v_code := 'VEN-' || lpad(v_next_num::text, 4, '0');

  insert into accounts (tenant_id, account_code, name, account_type, is_active)
  values (p_tenant_id, v_code, trim(p_vendor_name), 'vendor', true)
  returning id into v_account_id;

  return v_account_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.return_asset(p_assignment_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS public.asset_assignments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_assignment public.asset_assignments%rowtype;
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to return assets';
  end if;
  select * into v_assignment from asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'assignment not found';
  end if;
  if v_assignment.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this assignment';
  end if;
  if v_assignment.returned_at is not null then
    raise exception 'assignment already returned';
  end if;

  update asset_assignments
  set returned_at = now(),
      notes = coalesce(p_notes, notes)
  where id = p_assignment_id
  returning * into v_assignment;

  update assets set status = 'in_stock', updated_at = now()
  where id = v_assignment.asset_id
  returning * into v_asset;

  return v_assignment;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.revoke_invitation(p_invitation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_invitation invitations%rowtype;
  v_caller_is_platform_admin boolean;
  v_caller_tenant_id uuid;
begin
  select * into v_invitation
  from invitations
  where id = p_invitation_id;

  if not found then
    raise exception 'Invitation not found';
  end if;

  select is_platform_admin, tenant_id
  into v_caller_is_platform_admin, v_caller_tenant_id
  from app_users
  where id = auth.uid();

  if not (
    v_caller_is_platform_admin
    or (
      v_invitation.role_bundle = 'member'
      and v_invitation.tenant_id = v_caller_tenant_id
      and exists (
        select 1 from staff_roles
        where user_id = auth.uid()
          and tenant_id = v_invitation.tenant_id
          and role = 'admin'
      )
    )
  ) then
    raise exception 'Not authorized to revoke this invitation';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Only pending invitations can be revoked (this one is %)', v_invitation.status;
  end if;

  update invitations set status = 'revoked' where id = p_invitation_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.revoke_receipt_access(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT is_finance_team_member('finance') THEN
    RAISE EXCEPTION 'not authorized to revoke material receipt access';
  END IF;

  DELETE FROM material_receipt_assignments
  WHERE tenant_id = get_my_tenant_id() AND user_id = p_user_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.seed_tenant_defaults(p_tenant_id uuid, p_industry_template text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_dept_cost_control uuid;
  v_dept_procurement uuid;
  v_dept_finance uuid;
  v_dept_pmo uuid;
  v_dept_it uuid;
  v_dept_hr uuid;
  v_dept_law uuid;
  v_dept_bd uuid;
  v_stage_cce uuid;
  v_stage_ccm uuid;
  v_stage_offer uuid;
  v_stage_chief uuid;
  v_stage_finance uuid;
  v_stage_pm uuid;
  v_stage_dgm uuid;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can seed tenant defaults';
  end if;

  -- Idempotency guards -- do nothing if this tenant already has either.
  if exists (select 1 from departments where tenant_id = p_tenant_id)
     or exists (select 1 from workflow_stages where tenant_id = p_tenant_id) then
    return;
  end if;

  -- ── Departments ──────────────────────────────────────────────────
  insert into departments (tenant_id, name) values (p_tenant_id, 'Cost Control')
    returning id into v_dept_cost_control;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Procurement & Logistics')
    returning id into v_dept_procurement;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Finance & Financial Reporting')
    returning id into v_dept_finance;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Project Management Office')
    returning id into v_dept_pmo;
  insert into departments (tenant_id, name) values (p_tenant_id, 'IT Support')
    returning id into v_dept_it;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Human Resources')
    returning id into v_dept_hr;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Law & Compliance')
    returning id into v_dept_law;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Business Development')
    returning id into v_dept_bd;

  if p_industry_template = 'construction' then
    insert into departments (tenant_id, name) values (p_tenant_id, 'Machine Operations');
    insert into departments (tenant_id, name) values (p_tenant_id, 'Sustainability & Business Excellence');
  end if;

  -- ── Workflow stages (same pipeline for every template) ──────────
  -- Cost Control Engineer -> Cost Control Manager -> Procurement Offer
  -- Entry -> Control Chief/Manager -> threshold check ->
  --   below: Finance -> PO
  --   above: Project Manager -> Deputy GM -> Finance -> PO
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Engineer', 1, 'Cost Control Engineer')
    returning id into v_stage_cce;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Manager', 2, 'Cost Control Manager')
    returning id into v_stage_ccm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Procurement: Offer Entry', 3, 'Procurement/Logistics Expert')
    returning id into v_stage_offer;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount)
    values (p_tenant_id, 'Control Chief/Manager', 4, 'Procurement & Logistics Chief', 5000000.00)
    returning id into v_stage_chief;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Finance', 5, 'Finance Officer')
    returning id into v_stage_finance;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Project Manager', 6, 'Project Manager')
    returning id into v_stage_pm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Deputy General Manager', 7, 'Deputy General Manager')
    returning id into v_stage_dgm;

  update workflow_stages set next_stage_low_id = v_stage_ccm where id = v_stage_cce;
  update workflow_stages set next_stage_low_id = v_stage_offer where id = v_stage_ccm;
  update workflow_stages set next_stage_low_id = v_stage_chief where id = v_stage_offer;
  update workflow_stages
    set next_stage_low_id = v_stage_finance, next_stage_high_id = v_stage_pm
    where id = v_stage_chief;
  update workflow_stages set next_stage_low_id = v_stage_dgm where id = v_stage_pm;
  update workflow_stages set next_stage_low_id = v_stage_finance where id = v_stage_dgm;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_account_category_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_asset_tag()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if NEW.asset_tag is null then
    NEW.asset_tag := next_asset_tag(NEW.tenant_id);
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_cash_bank_transaction_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_cost_center_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  NEW.tenant_id := get_my_tenant_id();

  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'could not determine tenant_id for current user';
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_department_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_expenditure_slip_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_invoice_request_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_initial_stage_id uuid;
  v_department_id     uuid;
  v_is_platform_admin boolean;
begin
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  select department_id, coalesce(is_platform_admin, false)
    into v_department_id, v_is_platform_admin
  from app_users
  where id = auth.uid();

  if v_department_id is null and not v_is_platform_admin then
    raise exception 'your account has no department assigned -- ask an admin to set one before submitting an invoice';
  end if;

  NEW.department_id := v_department_id;

  select id into v_initial_stage_id
  from workflow_stages
  where tenant_id = NEW.tenant_id and is_active and applies_to = 'invoices'
  order by sequence_order asc
  limit 1;

  if v_initial_stage_id is null then
    raise exception 'no active invoice workflow stages configured for this tenant';
  end if;

  NEW.current_stage_id := v_initial_stage_id;

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_material_lookup_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_material_request_batch_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  if NEW.requester_id is null then
    NEW.requester_id := auth.uid();
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_material_request_item_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  select tenant_id into NEW.tenant_id from material_request_batches where id = NEW.batch_id;
  if NEW.tenant_id is null then
    raise exception 'batch not found or has no tenant';
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_organization_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_petty_cash_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  new.tenant_id := get_my_tenant_id();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_problem_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if NEW.problem_number is null then
    NEW.problem_number := next_problem_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_receivable_invoice_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_request_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_initial_stage_id uuid;
  v_department_id     uuid;
  v_is_platform_admin boolean;
begin
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  select department_id, coalesce(is_platform_admin, false)
    into v_department_id, v_is_platform_admin
  from app_users
  where id = auth.uid();

  if v_department_id is null and not v_is_platform_admin then
    raise exception 'your account has no department assigned -- ask an admin to set one before submitting a request';
  end if;

  NEW.department_id := v_department_id;

  select id into v_initial_stage_id
  from workflow_stages
  where tenant_id = NEW.tenant_id and is_active and applies_to = 'requests'
  order by sequence_order asc
  limit 1;

  if v_initial_stage_id is null then
    raise exception 'no active workflow stages configured for this tenant';
  end if;

  NEW.current_stage_id := v_initial_stage_id;

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_request_mr_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if NEW.mr_number is null then
    NEW.mr_number := next_mr_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_supplier_invoice_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_ticket_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if NEW.ticket_number is null then
    NEW.ticket_number := next_ticket_number(NEW.tenant_id);
  end if;
  if NEW.category = 'Access' then
    NEW.requires_approval := true;
    NEW.approval_status := 'pending';
  end if;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_warehouse_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  NEW.created_by := COALESCE(NEW.created_by, auth.uid());
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.share_purchase_order(p_purchase_order_id uuid)
 RETURNS public.purchase_orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_po purchase_orders%ROWTYPE;
  v_request requests%ROWTYPE;
  v_offer_submitter uuid;
BEGIN
  SELECT po.* INTO v_po
  FROM purchase_orders po
  JOIN requests r ON r.id = po.request_id
  WHERE po.id = p_purchase_order_id
    AND r.tenant_id = get_my_tenant_id()
  FOR UPDATE OF po;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'purchase order not found';
  END IF;

  IF NOT can_manage_po_handoff(p_purchase_order_id) THEN
    RAISE EXCEPTION 'not authorized to share this purchase order';
  END IF;

  IF v_po.shared_with_supplier THEN
    RETURN v_po;
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_po.request_id;

  UPDATE purchase_orders
  SET shared_with_supplier = true
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_po;

  SELECT submitted_by INTO v_offer_submitter
  FROM request_offers
  WHERE request_id = v_po.request_id AND is_selected
  LIMIT 1;

  IF v_offer_submitter IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    VALUES (
      v_request.tenant_id,
      v_offer_submitter,
      'po_shared',
      'PO shared with supplier',
      format('PO %s shared with %s. You can proceed.', v_po.po_number, v_po.vendor_name),
      v_request.id,
      v_po.id
    );
  END IF;

  RETURN v_po;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.start_impersonation(p_tenant_id uuid)
 RETURNS public.impersonation_sessions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_session impersonation_sessions;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can start impersonation';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'No such tenant';
  end if;

  -- Close any stale/dangling session for this admin first.
  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_sessions (platform_admin_id, tenant_id)
  values (auth.uid(), p_tenant_id)
  returning * into v_session;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_tenant_id, 'start');

  return v_session;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.submit_offers_for_approval(p_request_id uuid)
 RETURNS public.requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request     requests%rowtype;
  v_stage       workflow_stages%rowtype;
  v_next_stage  workflow_stages%rowtype;
  v_offer_count int;
begin
  select * into v_request from requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'open' then
    raise exception 'request is not open (status: %)', v_request.status;
  end if;

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;
  if not v_stage.requires_offer_entry then
    raise exception 'this request is not at an offer-entry stage';
  end if;
  if not can_act_on_stage(v_stage.id) then
    raise exception 'not authorized to submit offers on this request';
  end if;

  select count(*) into v_offer_count from request_offers where request_id = p_request_id;
  if v_offer_count < 2 then
    raise exception 'at least 2 competing offers are required before sending to Budget Controller (currently %)', v_offer_count;
  end if;

  if v_stage.next_stage_low_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  update requests
  set current_stage_id = v_stage.next_stage_low_id, updated_at = now()
  where id = p_request_id
  returning * into v_request;

  select * into v_next_stage from workflow_stages where id = v_stage.next_stage_low_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select distinct
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Offers submitted -- approval needed',
    format('%s competing offers were submitted for request "%s" and are awaiting your review.',
           v_offer_count, v_request.item_description),
    p_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage.id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage.id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage.id)
  ) recipients;

  return v_request;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.submit_payroll_run(p_run_id uuid)
 RETURNS public.hr_payroll_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to submit payroll';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM hr_payroll_items WHERE payroll_run_id = p_run_id) THEN
    RAISE EXCEPTION 'cannot submit a payroll run with no line items';
  END IF;

  UPDATE hr_payroll_runs
  SET status = 'pending_approval', submitted_at = now()
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'draft'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not in draft';
  END IF;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.submit_request_with_line_items(p_item_description text, p_quantity integer, p_cost_center_id uuid, p_delivery_date date, p_subcontractor text, p_line_items jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_request_id uuid;
  v_item jsonb;
BEGIN
  IF p_line_items IS NULL OR jsonb_array_length(p_line_items) = 0 THEN
    RAISE EXCEPTION 'at least one line item is required';
  END IF;

  -- tenant_id, requester_id, department_id, status, current_stage_id are all
  -- set server-side by trg_set_request_defaults, same as a direct insert.
  INSERT INTO requests (item_description, quantity, cost_center_id, delivery_date, subcontractor)
  VALUES (p_item_description, p_quantity, p_cost_center_id, p_delivery_date, p_subcontractor)
  RETURNING id INTO v_request_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items)
  LOOP
    IF NULLIF(v_item->>'material_service', '') IS NULL THEN
      RAISE EXCEPTION 'each line item requires material_service';
    END IF;

    INSERT INTO request_line_items (
      request_id, material_service, cost_code, group_code, place_of_use,
      quantity, unit_price, currency
    )
    VALUES (
      v_request_id,
      v_item->>'material_service',
      NULLIF(v_item->>'cost_code', ''),
      NULLIF(v_item->>'group_code', ''),
      NULLIF(v_item->>'place_of_use', ''),
      (v_item->>'quantity')::numeric,
      NULLIF(v_item->>'unit_price', '')::numeric,
      COALESCE(NULLIF(v_item->>'currency', ''), 'UGX')
    );
  END LOOP;

  RETURN v_request_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.supplier_invoice_outstanding(p_invoice_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select si.amount_incl_vat
    - coalesce((select sum(cbt.amount) from cash_bank_transactions cbt
                where cbt.reference_type = 'supplier_invoice' and cbt.reference_id = si.id), 0)
    - coalesce((select sum(apa.applied_amount) from advance_payment_applications apa
                where apa.reference_type = 'supplier_invoice' and apa.reference_id = si.id), 0)
  from supplier_invoices si
  where si.id = p_invoice_id;
$function$
;

CREATE OR REPLACE FUNCTION public.supplier_invoice_payable_now(p_invoice_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT GREATEST(0,
    LEAST(
      supplier_invoice_receipt_cap(p_invoice_id) - (si.amount_incl_vat - supplier_invoice_outstanding(p_invoice_id)),
      supplier_invoice_outstanding(p_invoice_id)
    )
  )
  FROM supplier_invoices si WHERE si.id = p_invoice_id;
$function$
;

CREATE OR REPLACE FUNCTION public.supplier_invoice_receipt_cap(p_invoice_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_invoice supplier_invoices%ROWTYPE;
  v_ordered_value numeric;
  v_received_value numeric;
  v_ordered_qty numeric;
  v_received_qty numeric;
BEGIN
  SELECT * INTO v_invoice FROM supplier_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  SELECT
    COALESCE(SUM(rli.quantity * rli.unit_price), 0),
    COALESCE(SUM(LEAST(rec.received_qty, rli.quantity) * rli.unit_price), 0),
    COALESCE(SUM(rli.quantity), 0),
    COALESCE(SUM(LEAST(rec.received_qty, rli.quantity)), 0)
  INTO v_ordered_value, v_received_value, v_ordered_qty, v_received_qty
  FROM request_line_items rli
  JOIN requests r ON r.id = rli.request_id
  LEFT JOIN (
    SELECT line_item_id, SUM(received_qty) AS received_qty
    FROM line_item_receipts GROUP BY line_item_id
  ) rec ON rec.line_item_id = rli.id
  JOIN purchase_orders po ON po.request_id = r.id
  WHERE po.id = v_invoice.purchase_order_id;

  IF v_ordered_value > 0 THEN
    RETURN LEAST(v_invoice.amount_incl_vat, v_invoice.amount_incl_vat * (v_received_value / v_ordered_value));
  ELSIF v_ordered_qty > 0 THEN
    RETURN LEAST(v_invoice.amount_incl_vat, v_invoice.amount_incl_vat * (v_received_qty / v_ordered_qty));
  ELSE
    RETURN 0; -- no line items / nothing ordered -- nothing payable yet
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.try_complete_po(p_purchase_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_po      purchase_orders%rowtype;
  v_invoice supplier_invoices%rowtype;
  v_request requests%rowtype;
begin
  select * into v_po from purchase_orders where id = p_purchase_order_id;
  if not found or v_po.completed_at is not null or v_po.delivered_at is null then
    return; -- nothing to do: unknown PO, already settled, or not yet delivered
  end if;

  select * into v_invoice from supplier_invoices where purchase_order_id = p_purchase_order_id;
  if not found then
    return; -- no invoice recorded against this PO yet
  end if;

  if supplier_invoice_outstanding(v_invoice.id) > 0 then
    return; -- still owing
  end if;

  update purchase_orders set completed_at = now() where id = p_purchase_order_id;

  select * into v_request from requests where id = v_po.request_id;
  insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
  values (
    v_request.tenant_id,
    v_request.requester_id,
    'po_completed',
    'Purchase order settled',
    format('PO %s (%s) has been paid in full and is now complete.', v_po.po_number, v_po.vendor_name),
    v_request.id,
    v_po.id
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.unlink_ticket_from_problem(p_problem_id uuid, p_ticket_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to unlink tickets from problems';
  end if;
  delete from problem_tickets
  where problem_id = p_problem_id and ticket_id = p_ticket_id and tenant_id = get_my_tenant_id();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_app_user(p_user_id uuid, p_department_id uuid DEFAULT NULL::uuid, p_role_title text DEFAULT NULL::text, p_is_platform_admin boolean DEFAULT NULL::boolean)
 RETURNS public.app_users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user public.app_users%rowtype;
  v_caller public.app_users%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage accounts';
  end if;
  select * into v_caller from app_users where id = auth.uid();
  select * into v_user from app_users where id = p_user_id for update;
  if not found or v_user.tenant_id != get_my_tenant_id() then
    raise exception 'user not found';
  end if;
  if p_is_platform_admin is not null and not v_caller.is_platform_admin then
    raise exception 'only a platform admin can change platform admin status';
  end if;

  update app_users
  set department_id = coalesce(p_department_id, department_id),
      role_title = coalesce(p_role_title, role_title),
      is_platform_admin = coalesce(p_is_platform_admin, is_platform_admin)
  where id = p_user_id
  returning * into v_user;

  return v_user;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_asset(p_asset_id uuid, p_name text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_serial_number text DEFAULT NULL::text, p_vendor text DEFAULT NULL::text, p_purchase_cost numeric DEFAULT NULL::numeric, p_status text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS public.assets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update assets';
  end if;
  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  -- 'assigned' status is only set via assign_asset/return_asset, not here
  if p_status is not null and p_status not in ('in_stock','maintenance','retired') then
    raise exception 'invalid status for direct update: %', p_status;
  end if;
  if p_status is not null and v_asset.status = 'assigned' then
    raise exception 'asset is currently assigned; return it before changing status';
  end if;

  update assets
  set name = coalesce(p_name, name),
      category = coalesce(p_category, category),
      serial_number = coalesce(p_serial_number, serial_number),
      vendor = coalesce(p_vendor, vendor),
      purchase_cost = coalesce(p_purchase_cost, purchase_cost),
      status = coalesce(p_status, status),
      notes = coalesce(p_notes, notes),
      updated_at = now()
  where id = p_asset_id
  returning * into v_asset;

  return v_asset;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_faq(p_faq_id uuid, p_question text DEFAULT NULL::text, p_answer text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_sort_order integer DEFAULT NULL::integer, p_is_published boolean DEFAULT NULL::boolean)
 RETURNS public.faqs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_faq public.faqs%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update FAQ entries';
  end if;
  select * into v_faq from faqs where id = p_faq_id for update;
  if not found or v_faq.tenant_id != get_my_tenant_id() then
    raise exception 'FAQ not found';
  end if;

  update faqs
  set question = coalesce(p_question, question),
      answer = coalesce(p_answer, answer),
      category = coalesce(p_category, category),
      sort_order = coalesce(p_sort_order, sort_order),
      is_published = coalesce(p_is_published, is_published),
      updated_at = now()
  where id = p_faq_id
  returning * into v_faq;

  return v_faq;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_kb_article(p_article_id uuid, p_title text DEFAULT NULL::text, p_content text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_is_published boolean DEFAULT NULL::boolean)
 RETURNS public.kb_articles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_article public.kb_articles%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update knowledge base articles';
  end if;
  select * into v_article from kb_articles where id = p_article_id for update;
  if not found or v_article.tenant_id != get_my_tenant_id() then
    raise exception 'article not found';
  end if;

  update kb_articles
  set title = coalesce(p_title, title),
      content = coalesce(p_content, content),
      category = coalesce(p_category, category),
      is_published = coalesce(p_is_published, is_published),
      updated_at = now()
  where id = p_article_id
  returning * into v_article;

  return v_article;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_license(p_license_id uuid, p_license_key text DEFAULT NULL::text, p_seats_total integer DEFAULT NULL::integer, p_vendor text DEFAULT NULL::text, p_expiry_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS public.licenses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_license public.licenses%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update licenses';
  end if;
  select * into v_license from licenses where id = p_license_id for update;
  if not found then
    raise exception 'license not found';
  end if;
  if v_license.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this license';
  end if;

  update licenses
  set license_key = coalesce(p_license_key, license_key),
      seats_total = coalesce(p_seats_total, seats_total),
      vendor = coalesce(p_vendor, vendor),
      expiry_date = coalesce(p_expiry_date, expiry_date),
      notes = coalesce(p_notes, notes),
      updated_at = now()
  where id = p_license_id
  returning * into v_license;

  return v_license;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_payroll_item(p_item_id uuid, p_allowances numeric, p_deductions numeric, p_note text DEFAULT NULL::text)
 RETURNS public.hr_payroll_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_payroll_items%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to edit payroll';
  END IF;

  UPDATE hr_payroll_items i
  SET allowances = p_allowances, deductions = p_deductions, note = p_note
  FROM hr_payroll_runs r
  WHERE i.id = p_item_id
    AND r.id = i.payroll_run_id
    AND r.tenant_id = get_my_tenant_id()
    AND r.status = 'draft'
  RETURNING i.* INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll item not found, or run is no longer in draft';
  END IF;

  RETURN v_row;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_priority_level(p_code text, p_label text DEFAULT NULL::text, p_color text DEFAULT NULL::text)
 RETURNS public.priority_levels
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.priority_levels%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage priority levels';
  end if;
  update priority_levels
  set label = coalesce(p_label, label), color = coalesce(p_color, color)
  where code = p_code and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'priority level not found';
  end if;
  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_problem(p_problem_id uuid, p_status text DEFAULT NULL::text, p_root_cause text DEFAULT NULL::text, p_assigned_to uuid DEFAULT NULL::uuid, p_title text DEFAULT NULL::text, p_description text DEFAULT NULL::text)
 RETURNS public.problems
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_problem public.problems%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update problems';
  end if;
  select * into v_problem from problems where id = p_problem_id for update;
  if not found then
    raise exception 'problem not found';
  end if;
  if v_problem.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this problem';
  end if;
  if p_status is not null and p_status not in ('open','investigating','resolved','closed') then
    raise exception 'invalid status: %', p_status;
  end if;

  update problems
  set status = coalesce(p_status, status),
      root_cause = coalesce(p_root_cause, root_cause),
      assigned_to = coalesce(p_assigned_to, assigned_to),
      title = coalesce(p_title, title),
      description = coalesce(p_description, description),
      resolved_at = case when p_status = 'resolved' and resolved_at is null then now() else resolved_at end,
      closed_at = case when p_status = 'closed' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_problem_id
  returning * into v_problem;

  return v_problem;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_support_team(p_id uuid, p_name text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS public.support_teams
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage support teams';
  end if;
  update support_teams
  set name = coalesce(p_name, name), description = coalesce(p_description, description), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'support team not found';
  end if;
  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_ticket_category(p_id uuid, p_name text DEFAULT NULL::text, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS public.ticket_categories
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  update ticket_categories
  set name = coalesce(p_name, name), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'ticket category not found';
  end if;
  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_ticket_status(p_ticket_id uuid, p_status text, p_resolution_notes text DEFAULT NULL::text)
 RETURNS public.it_tickets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if p_status not in ('open','in_progress','resolved','closed') then
    raise exception 'invalid status: %', p_status;
  end if;
  if not is_it_support() then
    raise exception 'not authorized to update ticket status';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status = 'pending' and p_status = 'in_progress' then
    raise exception 'ticket is awaiting approval and cannot be actioned yet';
  end if;

  update it_tickets
  set status = p_status,
      resolution_notes = coalesce(p_resolution_notes, resolution_notes),
      resolved_at = case when p_status = 'resolved' and resolved_at is null then now() else resolved_at end,
      closed_at = case when p_status = 'closed' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_ticket.tenant_id,
    v_ticket.requester_id,
    'ticket_status_changed',
    'Ticket ' || v_ticket.ticket_number || ' updated',
    format('Your ticket "%s" is now %s.', v_ticket.subject, p_status)
  );

  return v_ticket;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.upsert_sla_policy(p_priority text, p_target_hours integer, p_description text DEFAULT NULL::text)
 RETURNS public.sla_policies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.sla_policies%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage SLA policies';
  end if;
  if p_priority not in ('low','medium','high','urgent') then
    raise exception 'invalid priority: %', p_priority;
  end if;

  insert into sla_policies (tenant_id, priority, target_hours, description)
  values (get_my_tenant_id(), p_priority, p_target_hours, p_description)
  on conflict (tenant_id, priority)
  do update set target_hours = excluded.target_hours, description = excluded.description, updated_at = now()
  returning * into v_row;

  return v_row;
end;
$function$
;

create or replace view "public"."v_account_ledger" as  SELECT supplier_invoices.tenant_id,
    supplier_invoices.vendor_account_id AS account_id,
    'supplier_invoice'::text AS source_type,
    supplier_invoices.id AS source_id,
    supplier_invoices.invoice_number AS reference_no,
    supplier_invoices.invoice_date AS transaction_date,
    supplier_invoices.amount_incl_vat AS debit,
    (0)::numeric AS credit,
    supplier_invoices.currency
   FROM public.supplier_invoices
  WHERE (supplier_invoices.vendor_account_id IS NOT NULL)
UNION ALL
 SELECT receivable_invoices.tenant_id,
    receivable_invoices.client_account_id AS account_id,
    'receivable_invoice'::text AS source_type,
    receivable_invoices.id AS source_id,
    receivable_invoices.invoice_number AS reference_no,
    receivable_invoices.invoice_date AS transaction_date,
    receivable_invoices.amount_incl_vat AS debit,
    (0)::numeric AS credit,
    receivable_invoices.currency
   FROM public.receivable_invoices
  WHERE (receivable_invoices.client_account_id IS NOT NULL)
UNION ALL
 SELECT cbt.tenant_id,
        CASE
            WHEN (cbt.reference_type = 'supplier_invoice'::text) THEN si.vendor_account_id
            WHEN (cbt.reference_type = 'receivable_invoice'::text) THEN ri.client_account_id
            ELSE NULL::uuid
        END AS account_id,
    'cash_bank_transaction'::text AS source_type,
    cbt.id AS source_id,
    cbt.description AS reference_no,
    cbt.transaction_date,
    (0)::numeric AS debit,
    cbt.amount AS credit,
    cbt.currency
   FROM ((public.cash_bank_transactions cbt
     LEFT JOIN public.supplier_invoices si ON (((cbt.reference_type = 'supplier_invoice'::text) AND (cbt.reference_id = si.id))))
     LEFT JOIN public.receivable_invoices ri ON (((cbt.reference_type = 'receivable_invoice'::text) AND (cbt.reference_id = ri.id))))
  WHERE (cbt.reference_type = ANY (ARRAY['supplier_invoice'::text, 'receivable_invoice'::text]));


create or replace view "public"."v_advance_payments" as  SELECT ap.id,
    ap.tenant_id,
    ap.account_id,
    a.account_code,
    a.name AS account_name,
    ap.direction,
    ap.amount,
    ap.currency,
    ap.payment_date,
    ap.payment_method,
    ap.description,
    COALESCE(applied.total_applied, (0)::numeric) AS total_applied,
    (ap.amount - COALESCE(applied.total_applied, (0)::numeric)) AS remaining_amount
   FROM ((public.advance_payments ap
     JOIN public.accounts a ON ((a.id = ap.account_id)))
     LEFT JOIN ( SELECT advance_payment_applications.advance_payment_id,
            sum(advance_payment_applications.applied_amount) AS total_applied
           FROM public.advance_payment_applications
          GROUP BY advance_payment_applications.advance_payment_id) applied ON ((applied.advance_payment_id = ap.id)));


create or replace view "public"."v_cost_transactions_inquiry" as  SELECT supplier_invoices.tenant_id,
    supplier_invoices.cost_center_id,
    'supplier_invoice'::text AS source_type,
    supplier_invoices.id AS source_id,
    supplier_invoices.invoice_number AS reference_no,
    supplier_invoices.invoice_date AS transaction_date,
    supplier_invoices.amount_incl_vat AS amount,
    supplier_invoices.currency
   FROM public.supplier_invoices
  WHERE (supplier_invoices.cost_center_id IS NOT NULL)
UNION ALL
 SELECT expenditure_slips.tenant_id,
    expenditure_slips.cost_center_id,
    'expenditure_slip'::text AS source_type,
    expenditure_slips.id AS source_id,
    expenditure_slips.slip_number AS reference_no,
    expenditure_slips.slip_date AS transaction_date,
    expenditure_slips.amount,
    expenditure_slips.currency
   FROM public.expenditure_slips
UNION ALL
 SELECT r.tenant_id,
    r.cost_center_id,
    'purchase_order'::text AS source_type,
    po.id AS source_id,
    po.po_number AS reference_no,
    (po.generated_at)::date AS transaction_date,
    po.amount,
    'UGX'::text AS currency
   FROM (public.purchase_orders po
     JOIN public.requests r ON ((r.id = po.request_id)))
  WHERE (r.cost_center_id IS NOT NULL);


create or replace view "public"."v_durations" as  SELECT ri.tenant_id,
    'receivable_invoice'::text AS source_type,
    ri.id AS source_id,
    ri.invoice_number,
    ri.invoice_date,
    ri.amount_incl_vat AS outstanding_amount,
    ri.currency,
    ri.status,
    (CURRENT_DATE - ri.invoice_date) AS days_outstanding
   FROM public.receivable_invoices ri
  WHERE (ri.status = 'open'::text)
UNION ALL
 SELECT si.tenant_id,
    'supplier_invoice'::text AS source_type,
    si.id AS source_id,
    si.invoice_number,
    si.invoice_date,
    (si.amount_incl_vat - COALESCE(paid.total_paid, (0)::numeric)) AS outstanding_amount,
    si.currency,
    'open'::text AS status,
    (CURRENT_DATE - si.invoice_date) AS days_outstanding
   FROM (public.supplier_invoices si
     LEFT JOIN ( SELECT cash_bank_transactions.reference_id,
            sum(cash_bank_transactions.amount) AS total_paid
           FROM public.cash_bank_transactions
          WHERE (cash_bank_transactions.reference_type = 'supplier_invoice'::text)
          GROUP BY cash_bank_transactions.reference_id) paid ON ((paid.reference_id = si.id)))
  WHERE ((si.amount_incl_vat - COALESCE(paid.total_paid, (0)::numeric)) > (0)::numeric);


create or replace view "public"."v_payment_plan" as  SELECT si.tenant_id,
    'supplier_invoice'::text AS source_type,
    si.id AS source_id,
    si.invoice_number,
    si.invoice_date,
    si.due_date,
    si.currency,
    (si.amount_incl_vat - COALESCE(paid.total_paid, (0)::numeric)) AS outstanding_amount
   FROM (public.supplier_invoices si
     LEFT JOIN ( SELECT cash_bank_transactions.reference_id,
            sum(cash_bank_transactions.amount) AS total_paid
           FROM public.cash_bank_transactions
          WHERE (cash_bank_transactions.reference_type = 'supplier_invoice'::text)
          GROUP BY cash_bank_transactions.reference_id) paid ON ((paid.reference_id = si.id)))
  WHERE ((si.due_date IS NOT NULL) AND ((si.amount_incl_vat - COALESCE(paid.total_paid, (0)::numeric)) > (0)::numeric))
UNION ALL
 SELECT ri.tenant_id,
    'receivable_invoice'::text AS source_type,
    ri.id AS source_id,
    ri.invoice_number,
    ri.invoice_date,
    ri.due_date,
    ri.currency,
    ri.amount_incl_vat AS outstanding_amount
   FROM public.receivable_invoices ri
  WHERE ((ri.due_date IS NOT NULL) AND (ri.status = 'open'::text));


create or replace view "public"."v_request_tracking" as  SELECT r.id AS request_id,
    r.mr_number,
    r.created_at AS mr_date,
    r.item_description AS mr_title,
    r.subcontractor,
    r.status,
    r.delivery_date,
    r.organization_id,
    org.company_code,
    org.site_name,
    r.requester_id,
    ru.name AS mr_originator,
    li.cost_code,
    li.place_of_use,
    ws.name AS pending_authority,
    po.id AS purchase_order_id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name AS company,
    po.amount AS po_total,
    po.currency,
    po.generated_by AS po_requester_id,
    gu.name AS po_requester_name,
    po.generated_at AS po_date,
    po.delivered_at,
    po.completed_at AS closing_date
   FROM ((((((public.requests r
     LEFT JOIN public.organizations org ON ((org.id = r.organization_id)))
     LEFT JOIN public.app_users ru ON ((ru.id = r.requester_id)))
     LEFT JOIN LATERAL ( SELECT request_line_items.cost_code,
            request_line_items.place_of_use
           FROM public.request_line_items
          WHERE (request_line_items.request_id = r.id)
          ORDER BY request_line_items.created_at
         LIMIT 1) li ON (true))
     LEFT JOIN public.workflow_stages ws ON ((ws.id = r.current_stage_id)))
     LEFT JOIN public.purchase_orders po ON ((po.request_id = r.id)))
     LEFT JOIN public.app_users gu ON ((gu.id = po.generated_by)));


create or replace view "public"."v_trial_balance" as  SELECT a.tenant_id,
    a.id AS account_id,
    a.account_code,
    a.name AS account_name,
    ac.name AS category_name,
    l.currency,
    sum(l.debit) AS total_debit,
    sum(l.credit) AS total_credit,
    (sum(l.debit) - sum(l.credit)) AS balance
   FROM ((public.accounts a
     LEFT JOIN public.account_categories ac ON ((ac.id = a.category_id)))
     LEFT JOIN public.v_account_ledger l ON ((l.account_id = a.id)))
  GROUP BY a.tenant_id, a.id, a.account_code, a.name, ac.name, l.currency;


create or replace view "public"."v_vat_report" as  SELECT supplier_invoices.tenant_id,
    supplier_invoices.organization_id,
    'supplier_invoice'::text AS source_type,
    supplier_invoices.id AS source_id,
    supplier_invoices.invoice_number,
    supplier_invoices.invoice_date,
    supplier_invoices.vat_amount,
    supplier_invoices.amount_incl_vat,
    supplier_invoices.currency
   FROM public.supplier_invoices
UNION ALL
 SELECT receivable_invoices.tenant_id,
    receivable_invoices.organization_id,
    'receivable_invoice'::text AS source_type,
    receivable_invoices.id AS source_id,
    receivable_invoices.invoice_number,
    receivable_invoices.invoice_date,
    receivable_invoices.vat_amount,
    receivable_invoices.amount_incl_vat,
    receivable_invoices.currency
   FROM public.receivable_invoices;


create or replace view "public"."v_vendor_evaluation" as  WITH po_agg AS (
         SELECT po.vendor_account_id,
            count(DISTINCT po.id) AS total_pos,
            sum(po.amount) AS total_po_value,
            count(DISTINCT po.id) FILTER (WHERE (po.delivered_at IS NOT NULL)) AS delivered_pos,
            avg((EXTRACT(epoch FROM (po.delivered_at - po.generated_at)) / 86400.0)) FILTER (WHERE (po.delivered_at IS NOT NULL)) AS avg_days_to_deliver,
            count(DISTINCT po.id) FILTER (WHERE ((po.delivered_at IS NOT NULL) AND (r.delivery_date IS NOT NULL) AND ((po.delivered_at)::date <= r.delivery_date))) AS on_time_pos,
            count(DISTINCT po.id) FILTER (WHERE ((po.delivered_at IS NOT NULL) AND (r.delivery_date IS NOT NULL))) AS pos_with_target_date
           FROM (public.purchase_orders po
             JOIN public.requests r ON ((r.id = po.request_id)))
          WHERE (po.vendor_account_id IS NOT NULL)
          GROUP BY po.vendor_account_id
        ), line_agg AS (
         SELECT po.vendor_account_id,
            count(*) FILTER (WHERE (lirs.receipt_status = 'full'::text)) AS full_lines,
            count(*) FILTER (WHERE (lirs.receipt_status = 'partial'::text)) AS partial_lines,
            count(*) FILTER (WHERE (lirs.receipt_status = 'over'::text)) AS over_lines,
            count(*) FILTER (WHERE (lirs.receipt_status <> 'none'::text)) AS received_lines,
            count(*) AS total_lines
           FROM ((public.purchase_orders po
             JOIN public.requests r ON ((r.id = po.request_id)))
             JOIN public.line_item_receipt_status lirs ON ((lirs.request_id = r.id)))
          WHERE (po.vendor_account_id IS NOT NULL)
          GROUP BY po.vendor_account_id
        )
 SELECT a.id AS vendor_account_id,
    a.tenant_id,
    a.account_code,
    a.name AS vendor_name,
    a.contact_name,
    a.contact_phone,
    a.contact_email,
    a.is_active,
    COALESCE(po_agg.total_pos, (0)::bigint) AS total_pos,
    COALESCE(po_agg.total_po_value, (0)::numeric) AS total_po_value,
    COALESCE(po_agg.delivered_pos, (0)::bigint) AS delivered_pos,
    round(po_agg.avg_days_to_deliver, 1) AS avg_days_to_deliver,
        CASE
            WHEN (COALESCE(po_agg.pos_with_target_date, (0)::bigint) > 0) THEN round(((100.0 * (po_agg.on_time_pos)::numeric) / (po_agg.pos_with_target_date)::numeric), 1)
            ELSE NULL::numeric
        END AS on_time_delivery_pct,
        CASE
            WHEN (COALESCE(line_agg.received_lines, (0)::bigint) > 0) THEN round(((100.0 * (line_agg.full_lines)::numeric) / (line_agg.received_lines)::numeric), 1)
            ELSE NULL::numeric
        END AS fulfillment_accuracy_pct,
        CASE
            WHEN (COALESCE(line_agg.received_lines, (0)::bigint) > 0) THEN round(((100.0 * (line_agg.over_lines)::numeric) / (line_agg.received_lines)::numeric), 1)
            ELSE NULL::numeric
        END AS over_delivery_pct,
        CASE
            WHEN (COALESCE(line_agg.received_lines, (0)::bigint) > 0) THEN round(((100.0 * (line_agg.partial_lines)::numeric) / (line_agg.received_lines)::numeric), 1)
            ELSE NULL::numeric
        END AS under_delivery_pct
   FROM ((public.accounts a
     LEFT JOIN po_agg ON ((po_agg.vendor_account_id = a.id)))
     LEFT JOIN line_agg ON ((line_agg.vendor_account_id = a.id)))
  WHERE (a.account_type = ANY (ARRAY['vendor'::text, 'both'::text]));



  create policy "app_users_select_tenant"
  on "public"."app_users"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "tenants_select_own"
  on "public"."tenants"
  as permissive
  for select
  to public
using ((id = public.get_my_tenant_id()));



  create policy "workflow_stages_select_tenant"
  on "public"."workflow_stages"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "access_requests_select"
  on "public"."access_requests"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND ((requested_by = ( SELECT auth.uid() AS uid)) OR public.is_it_support())));



  create policy "account_categories_delete"
  on "public"."account_categories"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "account_categories_insert"
  on "public"."account_categories"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "account_categories_select"
  on "public"."account_categories"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "account_categories_update"
  on "public"."account_categories"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "accounts_delete"
  on "public"."accounts"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "accounts_insert"
  on "public"."accounts"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "accounts_select"
  on "public"."accounts"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "accounts_update"
  on "public"."accounts"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "advance_payment_applications_delete"
  on "public"."advance_payment_applications"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (EXISTS ( SELECT 1
   FROM public.advance_payments ap
  WHERE ((ap.id = advance_payment_applications.advance_payment_id) AND (ap.tenant_id = public.get_my_tenant_id()))))));



  create policy "advance_payment_applications_insert"
  on "public"."advance_payment_applications"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (EXISTS ( SELECT 1
   FROM public.advance_payments ap
  WHERE ((ap.id = advance_payment_applications.advance_payment_id) AND (ap.tenant_id = public.get_my_tenant_id()))))));



  create policy "advance_payment_applications_select"
  on "public"."advance_payment_applications"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (EXISTS ( SELECT 1
   FROM public.advance_payments ap
  WHERE ((ap.id = advance_payment_applications.advance_payment_id) AND (ap.tenant_id = public.get_my_tenant_id()))))));



  create policy "advance_payments_delete"
  on "public"."advance_payments"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "advance_payments_insert"
  on "public"."advance_payments"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "advance_payments_select"
  on "public"."advance_payments"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "advance_payments_update"
  on "public"."advance_payments"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "approval_actions_select_tenant"
  on "public"."approval_actions"
  as permissive
  for select
  to public
using (((EXISTS ( SELECT 1
   FROM public.requests r
  WHERE ((r.id = approval_actions.request_id) AND (r.tenant_id = public.get_my_tenant_id())))) OR (EXISTS ( SELECT 1
   FROM public.invoice_requests ir
  WHERE ((ir.id = approval_actions.invoice_request_id) AND (ir.tenant_id = public.get_my_tenant_id()))))));



  create policy "approval_delegations_insert_own"
  on "public"."approval_delegations"
  as permissive
  for insert
  to public
with check (((delegator_user_id = ( SELECT auth.uid() AS uid)) AND (tenant_id = public.get_my_tenant_id()) AND (delegate_user_id IS DISTINCT FROM ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.app_users au
  WHERE ((au.id = approval_delegations.delegate_user_id) AND (au.tenant_id = public.get_my_tenant_id())))) AND (((workflow_stage_id IS NULL) AND (EXISTS ( SELECT 1
   FROM public.approval_assignments aa
  WHERE (aa.user_id = ( SELECT auth.uid() AS uid))))) OR ((workflow_stage_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.approval_assignments aa
  WHERE ((aa.user_id = ( SELECT auth.uid() AS uid)) AND (aa.workflow_stage_id = approval_delegations.workflow_stage_id))))))));



  create policy "asset_assignments_select"
  on "public"."asset_assignments"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_it_support()));



  create policy "asset_requests_select"
  on "public"."asset_requests"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND ((requested_by = ( SELECT auth.uid() AS uid)) OR public.is_it_support())));



  create policy "assets_select"
  on "public"."assets"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_it_support()));



  create policy "bd_activities_select"
  on "public"."bd_activities"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_activities_write"
  on "public"."bd_activities"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_client_categories_select"
  on "public"."bd_client_categories"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_client_categories_write"
  on "public"."bd_client_categories"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_clients_select"
  on "public"."bd_clients"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_clients_write"
  on "public"."bd_clients"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_contacts_select"
  on "public"."bd_contacts"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_contacts_write"
  on "public"."bd_contacts"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_sources_select"
  on "public"."bd_lead_sources"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_sources_write"
  on "public"."bd_lead_sources"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_statuses_select"
  on "public"."bd_lead_statuses"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_statuses_write"
  on "public"."bd_lead_statuses"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_leads_select"
  on "public"."bd_leads"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_leads_write"
  on "public"."bd_leads"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunities_select"
  on "public"."bd_opportunities"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunities_write"
  on "public"."bd_opportunities"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunity_stages_select"
  on "public"."bd_opportunity_stages"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunity_stages_write"
  on "public"."bd_opportunity_stages"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_statuses_select"
  on "public"."bd_proposal_statuses"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_statuses_write"
  on "public"."bd_proposal_statuses"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_templates_select"
  on "public"."bd_proposal_templates"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_templates_write"
  on "public"."bd_proposal_templates"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_types_select"
  on "public"."bd_proposal_types"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_types_write"
  on "public"."bd_proposal_types"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposals_select"
  on "public"."bd_proposals"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposals_write"
  on "public"."bd_proposals"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tender_types_select"
  on "public"."bd_tender_types"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tender_types_write"
  on "public"."bd_tender_types"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tenders_select"
  on "public"."bd_tenders"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tenders_write"
  on "public"."bd_tenders"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "cash_bank_transactions_delete"
  on "public"."cash_bank_transactions"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "cash_bank_transactions_insert"
  on "public"."cash_bank_transactions"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "cash_bank_transactions_select"
  on "public"."cash_bank_transactions"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "cash_bank_transactions_update"
  on "public"."cash_bank_transactions"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "cost_centers_insert_finance"
  on "public"."cost_centers"
  as permissive
  for insert
  to public
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "cost_centers_select_tenant"
  on "public"."cost_centers"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "cost_centers_update_finance"
  on "public"."cost_centers"
  as permissive
  for update
  to public
using ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())))
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "departments_delete"
  on "public"."departments"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "departments_insert"
  on "public"."departments"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "departments_select_tenant"
  on "public"."departments"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "departments_update"
  on "public"."departments"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "expenditure_slips_delete"
  on "public"."expenditure_slips"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "expenditure_slips_insert"
  on "public"."expenditure_slips"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "expenditure_slips_select"
  on "public"."expenditure_slips"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "expenditure_slips_update"
  on "public"."expenditure_slips"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "external_material_groups_insert"
  on "public"."external_material_groups"
  as permissive
  for insert
  to public
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "external_material_groups_select"
  on "public"."external_material_groups"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "external_material_groups_update"
  on "public"."external_material_groups"
  as permissive
  for update
  to public
using ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())))
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "faqs_select"
  on "public"."faqs"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (is_published OR public.is_it_support())));



  create policy "finance_team_members_delete_admin"
  on "public"."finance_team_members"
  as permissive
  for delete
  to public
using (public.is_platform_admin());



  create policy "finance_team_members_insert_admin"
  on "public"."finance_team_members"
  as permissive
  for insert
  to public
with check (public.is_platform_admin());



  create policy "finance_team_members_select_own_or_admin"
  on "public"."finance_team_members"
  as permissive
  for select
  to public
using (((user_id = ( SELECT auth.uid() AS uid)) OR public.is_platform_admin()));



  create policy "finance_team_members_update_admin"
  on "public"."finance_team_members"
  as permissive
  for update
  to public
using (public.is_platform_admin())
with check (public.is_platform_admin());



  create policy "fuel_logs_select"
  on "public"."fuel_logs"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "fuel_logs_write"
  on "public"."fuel_logs"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "goods_issue_items_select"
  on "public"."goods_issue_items"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.goods_issues gi
  WHERE ((gi.id = goods_issue_items.goods_issue_id) AND (gi.tenant_id = public.get_my_tenant_id())))));



  create policy "goods_issues_select"
  on "public"."goods_issues"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_appraisals_select"
  on "public"."hr_appraisals"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_appraisals.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid))))))));



  create policy "hr_appraisals_write"
  on "public"."hr_appraisals"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_attendance_insert"
  on "public"."hr_attendance"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_attendance.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid))))))));



  create policy "hr_attendance_select"
  on "public"."hr_attendance"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_attendance.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid))))))));



  create policy "hr_attendance_update"
  on "public"."hr_attendance"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_employee_compensation_select"
  on "public"."hr_employee_compensation"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_employees_delete"
  on "public"."hr_employees"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_employees_insert"
  on "public"."hr_employees"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_employees_select"
  on "public"."hr_employees"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_employees_update"
  on "public"."hr_employees"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_job_applications_delete"
  on "public"."hr_job_applications"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_job_applications_insert"
  on "public"."hr_job_applications"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_job_applications_select"
  on "public"."hr_job_applications"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_job_applications_update"
  on "public"."hr_job_applications"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_job_postings_delete"
  on "public"."hr_job_postings"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_job_postings_insert"
  on "public"."hr_job_postings"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_job_postings_select"
  on "public"."hr_job_postings"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_job_postings_update"
  on "public"."hr_job_postings"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_leave_requests_insert"
  on "public"."hr_leave_requests"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_leave_requests.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid)))))));



  create policy "hr_leave_requests_select"
  on "public"."hr_leave_requests"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_leave_requests.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid))))))));



  create policy "hr_leave_requests_update"
  on "public"."hr_leave_requests"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]) OR ((status = 'pending'::text) AND (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_leave_requests.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid)))))))));



  create policy "hr_leave_types_delete"
  on "public"."hr_leave_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_leave_types_insert"
  on "public"."hr_leave_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_leave_types_select"
  on "public"."hr_leave_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_leave_types_update"
  on "public"."hr_leave_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_payroll_items_select"
  on "public"."hr_payroll_items"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.hr_payroll_runs pr
  WHERE ((pr.id = hr_payroll_items.payroll_run_id) AND (pr.tenant_id = public.get_my_tenant_id())))));



  create policy "hr_payroll_runs_select"
  on "public"."hr_payroll_runs"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_positions_delete"
  on "public"."hr_positions"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_positions_insert"
  on "public"."hr_positions"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_positions_select"
  on "public"."hr_positions"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_positions_update"
  on "public"."hr_positions"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text])));



  create policy "hr_team_members_select"
  on "public"."hr_team_members"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_trainings_select"
  on "public"."hr_trainings"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "hr_trainings_write"
  on "public"."hr_trainings"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "impersonation_logs_select_platform_admin"
  on "public"."impersonation_logs"
  as permissive
  for select
  to public
using (public.is_platform_admin());



  create policy "invitations_insert_platform_admin"
  on "public"."invitations"
  as permissive
  for insert
  to public
with check (public.is_platform_admin());



  create policy "invitations_insert_tenant_admin"
  on "public"."invitations"
  as permissive
  for insert
  to public
with check (((role_bundle = 'member'::text) AND (tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.staff_roles
  WHERE ((staff_roles.user_id = ( SELECT auth.uid() AS uid)) AND (staff_roles.tenant_id = invitations.tenant_id) AND (staff_roles.role = 'admin'::text))))));



  create policy "invitations_select_platform_admin"
  on "public"."invitations"
  as permissive
  for select
  to public
using (public.is_platform_admin());



  create policy "invitations_select_tenant_admin"
  on "public"."invitations"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.staff_roles
  WHERE ((staff_roles.user_id = ( SELECT auth.uid() AS uid)) AND (staff_roles.tenant_id = invitations.tenant_id) AND (staff_roles.role = 'admin'::text))))));



  create policy "invoice_requests_insert_own"
  on "public"."invoice_requests"
  as permissive
  for insert
  to public
with check (((requester_id = ( SELECT auth.uid() AS uid)) AND (tenant_id = public.get_my_tenant_id())));



  create policy "invoice_requests_select_own_or_actionable"
  on "public"."invoice_requests"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND ((requester_id = ( SELECT auth.uid() AS uid)) OR public.can_act_on_stage(current_stage_id))));



  create policy "it_tickets_insert"
  on "public"."it_tickets"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND (requester_id = ( SELECT auth.uid() AS uid))));



  create policy "it_tickets_select"
  on "public"."it_tickets"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND ((requester_id = ( SELECT auth.uid() AS uid)) OR (assignee_id = ( SELECT auth.uid() AS uid)) OR public.is_it_support())));



  create policy "kb_articles_select"
  on "public"."kb_articles"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (is_published OR public.is_it_support())));



  create policy "law_hearings_select"
  on "public"."law_case_hearings"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "law_hearings_write"
  on "public"."law_case_hearings"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_case_types_delete"
  on "public"."law_case_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])));



  create policy "law_case_types_insert"
  on "public"."law_case_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])));



  create policy "law_case_types_select"
  on "public"."law_case_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "law_case_types_update"
  on "public"."law_case_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])));



  create policy "law_cases_delete"
  on "public"."law_cases"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_cases_insert"
  on "public"."law_cases"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_cases_select"
  on "public"."law_cases"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "law_cases_update"
  on "public"."law_cases"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_compliance_insert"
  on "public"."law_compliance_register"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_compliance_select"
  on "public"."law_compliance_register"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "law_compliance_update"
  on "public"."law_compliance_register"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]) OR (owner_id = ( SELECT auth.uid() AS uid)))));



  create policy "law_contract_types_delete"
  on "public"."law_contract_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])));



  create policy "law_contract_types_insert"
  on "public"."law_contract_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])));



  create policy "law_contract_types_select"
  on "public"."law_contract_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "law_contract_types_update"
  on "public"."law_contract_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text])));



  create policy "law_contracts_delete"
  on "public"."law_contracts"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_contracts_insert"
  on "public"."law_contracts"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_contracts_select"
  on "public"."law_contracts"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "law_contracts_update"
  on "public"."law_contracts"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_filings_select"
  on "public"."law_regulatory_filings"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "law_filings_write"
  on "public"."law_regulatory_filings"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "licenses_select"
  on "public"."licenses"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_it_support()));



  create policy "line_item_receipts_select"
  on "public"."line_item_receipts"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM (public.request_line_items rli
     JOIN public.requests r ON ((r.id = rli.request_id)))
  WHERE ((rli.id = line_item_receipts.line_item_id) AND (r.tenant_id = public.get_my_tenant_id())))));



  create policy "machine_assignments_select"
  on "public"."machine_assignments"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "machine_assignments_write"
  on "public"."machine_assignments"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "machine_types_select"
  on "public"."machine_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "machine_types_write"
  on "public"."machine_types"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



  create policy "machines_select"
  on "public"."machines"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "machines_write"
  on "public"."machines"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "maintenance_requests_select"
  on "public"."maintenance_requests"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "maintenance_requests_write"
  on "public"."maintenance_requests"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "maintenance_types_select"
  on "public"."maintenance_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "maintenance_types_write"
  on "public"."maintenance_types"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



  create policy "material_catalog_select"
  on "public"."material_catalog"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "material_catalog_update"
  on "public"."material_catalog"
  as permissive
  for update
  to public
using ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())))
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "material_groups_insert"
  on "public"."material_groups"
  as permissive
  for insert
  to public
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "material_groups_select"
  on "public"."material_groups"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "material_groups_update"
  on "public"."material_groups"
  as permissive
  for update
  to public
using ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())))
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "material_receipt_assignments_select"
  on "public"."material_receipt_assignments"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "material_request_batches_insert"
  on "public"."material_request_batches"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND (requester_id = ( SELECT auth.uid() AS uid))));



  create policy "material_request_batches_select"
  on "public"."material_request_batches"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND ((requester_id = ( SELECT auth.uid() AS uid)) OR public.has_po_access())));



  create policy "material_request_items_insert"
  on "public"."material_request_items"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.material_request_batches b
  WHERE ((b.id = material_request_items.batch_id) AND (b.requester_id = ( SELECT auth.uid() AS uid)))))));



  create policy "material_request_items_select"
  on "public"."material_request_items"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_po_access() OR (EXISTS ( SELECT 1
   FROM public.material_request_batches b
  WHERE ((b.id = material_request_items.batch_id) AND (b.requester_id = ( SELECT auth.uid() AS uid))))))));



  create policy "material_types_insert"
  on "public"."material_types"
  as permissive
  for insert
  to public
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "material_types_select"
  on "public"."material_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "material_types_update"
  on "public"."material_types"
  as permissive
  for update
  to public
using ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())))
with check ((public.has_po_access() AND (tenant_id = public.get_my_tenant_id())));



  create policy "finance team can view oif sequences"
  on "public"."oif_sequences"
  as permissive
  for select
  to public
using (public.is_finance_team_member());



  create policy "operation_logs_select"
  on "public"."operation_logs"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "operation_logs_write"
  on "public"."operation_logs"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "organizations_delete"
  on "public"."organizations"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "organizations_insert"
  on "public"."organizations"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "organizations_select"
  on "public"."organizations"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.is_finance_team_member(NULL::text) OR public.has_po_access())));



  create policy "organizations_update"
  on "public"."organizations"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "payroll_approvers_select"
  on "public"."payroll_approvers"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "petty_cash_floats_delete"
  on "public"."petty_cash_floats"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "petty_cash_floats_insert"
  on "public"."petty_cash_floats"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "petty_cash_floats_select"
  on "public"."petty_cash_floats"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "petty_cash_floats_update"
  on "public"."petty_cash_floats"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "petty_cash_replenishments_delete"
  on "public"."petty_cash_replenishments"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "petty_cash_replenishments_insert"
  on "public"."petty_cash_replenishments"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "petty_cash_replenishments_select"
  on "public"."petty_cash_replenishments"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "petty_cash_replenishments_update"
  on "public"."petty_cash_replenishments"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "pmo_milestones_select"
  on "public"."pmo_milestones"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_milestones_write"
  on "public"."pmo_milestones"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_project_categories_select"
  on "public"."pmo_project_categories"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_project_categories_write"
  on "public"."pmo_project_categories"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_projects_select"
  on "public"."pmo_projects"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_projects_write"
  on "public"."pmo_projects"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_resource_allocations_select"
  on "public"."pmo_resource_allocations"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_resource_allocations_write"
  on "public"."pmo_resource_allocations"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_task_types_select"
  on "public"."pmo_task_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_task_types_write"
  on "public"."pmo_task_types"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_tasks_select"
  on "public"."pmo_tasks"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_tasks_write"
  on "public"."pmo_tasks"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))));



  create policy "po_edits_insert_finance"
  on "public"."po_edits"
  as permissive
  for insert
  to public
with check ((public.has_po_access() AND (EXISTS ( SELECT 1
   FROM (public.purchase_orders po
     JOIN public.requests r ON ((r.id = po.request_id)))
  WHERE ((po.id = po_edits.purchase_order_id) AND (r.tenant_id = public.get_my_tenant_id()))))));



  create policy "po_edits_select_finance"
  on "public"."po_edits"
  as permissive
  for select
  to public
using ((public.has_po_access() AND (EXISTS ( SELECT 1
   FROM (public.purchase_orders po
     JOIN public.requests r ON ((r.id = po.request_id)))
  WHERE ((po.id = po_edits.purchase_order_id) AND (r.tenant_id = public.get_my_tenant_id()))))));



  create policy "priority_levels_select"
  on "public"."priority_levels"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "problem_tickets_select"
  on "public"."problem_tickets"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_it_support()));



  create policy "problems_select"
  on "public"."problems"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_it_support()));



  create policy "purchase_orders_select_finance"
  on "public"."purchase_orders"
  as permissive
  for select
  to public
using ((public.has_po_access() AND (EXISTS ( SELECT 1
   FROM public.requests r
  WHERE ((r.id = purchase_orders.request_id) AND (r.tenant_id = public.get_my_tenant_id()))))));



  create policy "purchase_orders_update_handoff"
  on "public"."purchase_orders"
  as permissive
  for update
  to public
using ((public.has_po_access() AND (EXISTS ( SELECT 1
   FROM public.requests r
  WHERE ((r.id = purchase_orders.request_id) AND (r.tenant_id = public.get_my_tenant_id()))))))
with check ((public.has_po_access() AND (EXISTS ( SELECT 1
   FROM public.requests r
  WHERE ((r.id = purchase_orders.request_id) AND (r.tenant_id = public.get_my_tenant_id()))))));



  create policy "receivable_invoices_delete"
  on "public"."receivable_invoices"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "receivable_invoices_insert"
  on "public"."receivable_invoices"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "receivable_invoices_select"
  on "public"."receivable_invoices"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "receivable_invoices_update"
  on "public"."receivable_invoices"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "request_line_items_insert"
  on "public"."request_line_items"
  as permissive
  for insert
  to public
with check ((EXISTS ( SELECT 1
   FROM public.requests r
  WHERE ((r.id = request_line_items.request_id) AND (r.requester_id = ( SELECT auth.uid() AS uid))))));



  create policy "request_line_items_select"
  on "public"."request_line_items"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.requests r
  WHERE ((r.id = request_line_items.request_id) AND (r.tenant_id = public.get_my_tenant_id())))));



  create policy "request_offers_insert_authorized"
  on "public"."request_offers"
  as permissive
  for insert
  to public
with check (((submitted_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM (public.requests r
     JOIN public.workflow_stages ws ON ((ws.id = r.current_stage_id)))
  WHERE ((r.id = request_offers.request_id) AND (r.tenant_id = public.get_my_tenant_id()) AND (r.status = 'open'::text) AND ws.requires_offer_entry AND public.can_act_on_stage(r.current_stage_id))))));



  create policy "request_offers_select_via_request"
  on "public"."request_offers"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.requests r
  WHERE ((r.id = request_offers.request_id) AND (r.tenant_id = public.get_my_tenant_id()) AND ((r.requester_id = ( SELECT auth.uid() AS uid)) OR public.can_act_on_stage(r.current_stage_id))))));



  create policy "requests_insert_own"
  on "public"."requests"
  as permissive
  for insert
  to public
with check (((requester_id = ( SELECT auth.uid() AS uid)) AND (tenant_id = public.get_my_tenant_id())));



  create policy "requests_select_own_or_actionable"
  on "public"."requests"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND ((requester_id = ( SELECT auth.uid() AS uid)) OR public.can_act_on_stage(current_stage_id) OR public.has_po_access())));



  create policy "sap_payments_insert_finance"
  on "public"."sap_payments"
  as permissive
  for insert
  to public
with check (public.has_po_access());



  create policy "sap_payments_select_tenant"
  on "public"."sap_payments"
  as permissive
  for select
  to public
using ((tenant_id = ( SELECT app_users.tenant_id
   FROM public.app_users
  WHERE (app_users.id = ( SELECT auth.uid() AS uid)))));



  create policy "sla_policies_select"
  on "public"."sla_policies"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "staff_roles_delete"
  on "public"."staff_roles"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.app_users
  WHERE ((app_users.id = ( SELECT auth.uid() AS uid)) AND app_users.is_platform_admin)))));



  create policy "staff_roles_insert"
  on "public"."staff_roles"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.app_users
  WHERE ((app_users.id = ( SELECT auth.uid() AS uid)) AND app_users.is_platform_admin)))));



  create policy "staff_roles_update"
  on "public"."staff_roles"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.app_users
  WHERE ((app_users.id = ( SELECT auth.uid() AS uid)) AND app_users.is_platform_admin)))))
with check (((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.app_users
  WHERE ((app_users.id = ( SELECT auth.uid() AS uid)) AND app_users.is_platform_admin)))));



  create policy "tenant_read_staff_roles"
  on "public"."staff_roles"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "stock_balances_select"
  on "public"."stock_balances"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "stock_movements_select"
  on "public"."stock_movements"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "supplier_invoices_delete"
  on "public"."supplier_invoices"
  as permissive
  for delete
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "supplier_invoices_insert"
  on "public"."supplier_invoices"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "supplier_invoices_select"
  on "public"."supplier_invoices"
  as permissive
  for select
  to public
using ((public.is_finance_team_member(NULL::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "supplier_invoices_update"
  on "public"."supplier_invoices"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "support_team_members_select"
  on "public"."support_team_members"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.support_teams st
  WHERE ((st.id = support_team_members.team_id) AND (st.tenant_id = public.get_my_tenant_id())))));



  create policy "support_teams_select"
  on "public"."support_teams"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_audits_select"
  on "public"."sustainability_audits"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_audits_write"
  on "public"."sustainability_audits"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_certs_select"
  on "public"."sustainability_certifications"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_certs_write"
  on "public"."sustainability_certifications"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_init_cat_select"
  on "public"."sustainability_initiative_categories"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_init_cat_write"
  on "public"."sustainability_initiative_categories"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_initiatives_select"
  on "public"."sustainability_initiatives"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_initiatives_write"
  on "public"."sustainability_initiatives"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_metric_types_select"
  on "public"."sustainability_metric_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_metric_types_write"
  on "public"."sustainability_metric_types"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_metrics_select"
  on "public"."sustainability_metrics"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_metrics_write"
  on "public"."sustainability_metrics"
  as permissive
  for all
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "tenants_select_platform_admin"
  on "public"."tenants"
  as permissive
  for select
  to public
using (public.is_platform_admin());



  create policy "ticket_categories_select"
  on "public"."ticket_categories"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "user_group_members_select"
  on "public"."user_group_members"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.user_groups g
  WHERE ((g.id = user_group_members.group_id) AND (g.tenant_id = public.get_my_tenant_id()) AND public.is_it_support()))));



  create policy "user_groups_select"
  on "public"."user_groups"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_it_support()));



  create policy "warehouses_insert"
  on "public"."warehouses"
  as permissive
  for insert
  to public
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));



  create policy "warehouses_select"
  on "public"."warehouses"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "warehouses_update"
  on "public"."warehouses"
  as permissive
  for update
  to public
using ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())))
with check ((public.is_finance_team_member('finance'::text) AND (tenant_id = public.get_my_tenant_id())));


CREATE TRIGGER trg_set_account_category_defaults BEFORE INSERT ON public.account_categories FOR EACH ROW EXECUTE FUNCTION public.set_account_category_defaults();

CREATE TRIGGER accounts_touch_updated_at BEFORE UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER trg_check_po_completion_on_advance_application AFTER INSERT ON public.advance_payment_applications FOR EACH ROW EXECUTE FUNCTION public.check_po_completion_on_advance_application();

CREATE TRIGGER protect_delegation_immutable_fields BEFORE UPDATE ON public.approval_delegations FOR EACH ROW EXECUTE FUNCTION public.protect_delegation_immutable_fields();

CREATE TRIGGER trg_set_asset_tag BEFORE INSERT ON public.assets FOR EACH ROW EXECUTE FUNCTION public.set_asset_tag();

CREATE TRIGGER trg_bd_clients_upd BEFORE UPDATE ON public.bd_clients FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_bd_lead_no BEFORE INSERT ON public.bd_leads FOR EACH ROW EXECUTE FUNCTION public.generate_bd_lead_no();

CREATE TRIGGER trg_bd_leads_upd BEFORE UPDATE ON public.bd_leads FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_bd_opportunities_upd BEFORE UPDATE ON public.bd_opportunities FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_bd_opportunity_no BEFORE INSERT ON public.bd_opportunities FOR EACH ROW EXECUTE FUNCTION public.generate_bd_opportunity_no();

CREATE TRIGGER trg_bd_proposal_templates_upd BEFORE UPDATE ON public.bd_proposal_templates FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_bd_proposal_no BEFORE INSERT ON public.bd_proposals FOR EACH ROW EXECUTE FUNCTION public.generate_bd_proposal_no();

CREATE TRIGGER trg_bd_proposals_upd BEFORE UPDATE ON public.bd_proposals FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_bd_tender_no BEFORE INSERT ON public.bd_tenders FOR EACH ROW EXECUTE FUNCTION public.generate_bd_tender_no();

CREATE TRIGGER trg_bd_tenders_upd BEFORE UPDATE ON public.bd_tenders FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER set_cash_bank_transaction_defaults_trigger BEFORE INSERT ON public.cash_bank_transactions FOR EACH ROW EXECUTE FUNCTION public.set_cash_bank_transaction_defaults();

CREATE TRIGGER trg_check_payment_against_receipt BEFORE INSERT ON public.cash_bank_transactions FOR EACH ROW EXECUTE FUNCTION public.check_payment_against_receipt();

CREATE TRIGGER trg_check_payroll_disbursement BEFORE INSERT ON public.cash_bank_transactions FOR EACH ROW EXECUTE FUNCTION public.check_payroll_disbursement();

CREATE TRIGGER trg_check_po_completion_on_cash_bank AFTER INSERT ON public.cash_bank_transactions FOR EACH ROW EXECUTE FUNCTION public.check_po_completion_on_cash_bank();

CREATE TRIGGER trg_set_cost_center_defaults BEFORE INSERT ON public.cost_centers FOR EACH ROW EXECUTE FUNCTION public.set_cost_center_defaults();

CREATE TRIGGER trg_set_department_defaults BEFORE INSERT ON public.departments FOR EACH ROW EXECUTE FUNCTION public.set_department_defaults();

CREATE TRIGGER set_expenditure_slip_defaults_trigger BEFORE INSERT ON public.expenditure_slips FOR EACH ROW EXECUTE FUNCTION public.set_expenditure_slip_defaults();

CREATE TRIGGER touch_expenditure_slip_updated_at_trigger BEFORE UPDATE ON public.expenditure_slips FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER trg_set_external_material_groups_defaults BEFORE INSERT ON public.external_material_groups FOR EACH ROW EXECUTE FUNCTION public.set_material_lookup_defaults();

CREATE TRIGGER trg_post_issue_items_to_stock AFTER INSERT ON public.goods_issue_items FOR EACH ROW EXECUTE FUNCTION public.post_issue_items_to_stock();

CREATE TRIGGER trg_hr_appraisals_upd BEFORE UPDATE ON public.hr_appraisals FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_hr_emp_no BEFORE INSERT ON public.hr_employees FOR EACH ROW EXECUTE FUNCTION public.generate_hr_employee_no();

CREATE TRIGGER trg_hr_emp_upd BEFORE UPDATE ON public.hr_employees FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_hr_leave_no BEFORE INSERT ON public.hr_leave_requests FOR EACH ROW EXECUTE FUNCTION public.generate_hr_leave_no();

CREATE TRIGGER trg_hr_leave_upd BEFORE UPDATE ON public.hr_leave_requests FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_hr_trainings_upd BEFORE UPDATE ON public.hr_trainings FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER invoice_request_defaults BEFORE INSERT ON public.invoice_requests FOR EACH ROW EXECUTE FUNCTION public.set_invoice_request_defaults();

CREATE TRIGGER it_tickets_set_number BEFORE INSERT ON public.it_tickets FOR EACH ROW EXECUTE FUNCTION public.set_ticket_number();

CREATE TRIGGER trg_law_case_no BEFORE INSERT ON public.law_cases FOR EACH ROW EXECUTE FUNCTION public.generate_law_case_no();

CREATE TRIGGER trg_law_cases_upd BEFORE UPDATE ON public.law_cases FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_law_compliance_no BEFORE INSERT ON public.law_compliance_register FOR EACH ROW EXECUTE FUNCTION public.generate_law_compliance_no();

CREATE TRIGGER trg_law_contract_no BEFORE INSERT ON public.law_contracts FOR EACH ROW EXECUTE FUNCTION public.generate_law_contract_no();

CREATE TRIGGER trg_law_contracts_upd BEFORE UPDATE ON public.law_contracts FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_post_receipt_to_stock AFTER INSERT ON public.line_item_receipts FOR EACH ROW EXECUTE FUNCTION public.post_receipt_to_stock();

CREATE TRIGGER trg_machine_assignments_upd BEFORE UPDATE ON public.machine_assignments FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_machine_no BEFORE INSERT ON public.machines FOR EACH ROW EXECUTE FUNCTION public.generate_machine_no();

CREATE TRIGGER trg_machines_upd BEFORE UPDATE ON public.machines FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_maintenance_requests_upd BEFORE UPDATE ON public.maintenance_requests FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_set_material_groups_defaults BEFORE INSERT ON public.material_groups FOR EACH ROW EXECUTE FUNCTION public.set_material_lookup_defaults();

CREATE TRIGGER trg_set_material_request_batch_defaults BEFORE INSERT ON public.material_request_batches FOR EACH ROW EXECUTE FUNCTION public.set_material_request_batch_defaults();

CREATE TRIGGER trg_set_material_request_item_defaults BEFORE INSERT ON public.material_request_items FOR EACH ROW EXECUTE FUNCTION public.set_material_request_item_defaults();

CREATE TRIGGER trg_set_material_types_defaults BEFORE INSERT ON public.material_types FOR EACH ROW EXECUTE FUNCTION public.set_material_lookup_defaults();

CREATE TRIGGER trg_set_organization_defaults BEFORE INSERT ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.set_organization_defaults();

CREATE TRIGGER set_petty_cash_float_defaults_trigger BEFORE INSERT ON public.petty_cash_floats FOR EACH ROW EXECUTE FUNCTION public.set_petty_cash_defaults();

CREATE TRIGGER touch_petty_cash_float_updated_at_trigger BEFORE UPDATE ON public.petty_cash_floats FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER set_petty_cash_replenishment_defaults_trigger BEFORE INSERT ON public.petty_cash_replenishments FOR EACH ROW EXECUTE FUNCTION public.set_petty_cash_defaults();

CREATE TRIGGER trg_pmo_milestones_upd BEFORE UPDATE ON public.pmo_milestones FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_pmo_project_no BEFORE INSERT ON public.pmo_projects FOR EACH ROW EXECUTE FUNCTION public.generate_pmo_project_no();

CREATE TRIGGER trg_pmo_projects_upd BEFORE UPDATE ON public.pmo_projects FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_pmo_resource_allocations_upd BEFORE UPDATE ON public.pmo_resource_allocations FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_pmo_tasks_upd BEFORE UPDATE ON public.pmo_tasks FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER trg_set_problem_number BEFORE INSERT ON public.problems FOR EACH ROW EXECUTE FUNCTION public.set_problem_number();

CREATE TRIGGER trg_protect_po_immutable_fields BEFORE UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.protect_po_immutable_fields();

CREATE TRIGGER lock_receivable_invoice_organization BEFORE UPDATE ON public.receivable_invoices FOR EACH ROW EXECUTE FUNCTION public.prevent_invoice_organization_change();

CREATE TRIGGER set_receivable_invoice_defaults_trigger BEFORE INSERT ON public.receivable_invoices FOR EACH ROW EXECUTE FUNCTION public.set_receivable_invoice_defaults();

CREATE TRIGGER set_receivable_invoice_oif BEFORE INSERT ON public.receivable_invoices FOR EACH ROW EXECUTE FUNCTION public.assign_receivable_invoice_oif();

CREATE TRIGGER touch_receivable_invoice_updated_at_trigger BEFORE UPDATE ON public.receivable_invoices FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER trg_link_vendor_account_on_offer BEFORE INSERT ON public.request_offers FOR EACH ROW EXECUTE FUNCTION public.link_vendor_account_on_offer();

CREATE TRIGGER trg_set_request_defaults BEFORE INSERT ON public.requests FOR EACH ROW EXECUTE FUNCTION public.set_request_defaults();

CREATE TRIGGER trg_set_request_mr_number BEFORE INSERT ON public.requests FOR EACH ROW EXECUTE FUNCTION public.set_request_mr_number();

CREATE TRIGGER trg_set_sap_payment_defaults BEFORE INSERT ON public.sap_payments FOR EACH ROW EXECUTE FUNCTION public.set_sap_payment_defaults();

CREATE TRIGGER trg_apply_stock_movement AFTER INSERT ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION public.apply_stock_movement();

CREATE TRIGGER lock_supplier_invoice_organization BEFORE UPDATE ON public.supplier_invoices FOR EACH ROW EXECUTE FUNCTION public.prevent_invoice_organization_change();

CREATE TRIGGER set_supplier_invoice_defaults_trigger BEFORE INSERT ON public.supplier_invoices FOR EACH ROW EXECUTE FUNCTION public.set_supplier_invoice_defaults();

CREATE TRIGGER set_supplier_invoice_oif BEFORE INSERT ON public.supplier_invoices FOR EACH ROW EXECUTE FUNCTION public.assign_supplier_invoice_oif();

CREATE TRIGGER touch_supplier_invoice_updated_at_trigger BEFORE UPDATE ON public.supplier_invoices FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER trg_sustain_initiatives_upd BEFORE UPDATE ON public.sustainability_initiatives FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_generic();

CREATE TRIGGER set_warehouse_defaults_trigger BEFORE INSERT ON public.warehouses FOR EACH ROW EXECUTE FUNCTION public.set_warehouse_defaults();

drop policy "po_documents_tenant_insert" on "storage"."objects";

drop policy "po_documents_tenant_select" on "storage"."objects";

drop policy "po_documents_tenant_update" on "storage"."objects";


  create policy "po_documents_tenant_insert"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'po-documents'::text) AND ((storage.foldername(name))[1] = (public.get_my_tenant_id())::text)));



  create policy "po_documents_tenant_select"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'po-documents'::text) AND ((storage.foldername(name))[1] = (public.get_my_tenant_id())::text)));



  create policy "po_documents_tenant_update"
  on "storage"."objects"
  as permissive
  for update
  to authenticated
using (((bucket_id = 'po-documents'::text) AND ((storage.foldername(name))[1] = (public.get_my_tenant_id())::text)));



