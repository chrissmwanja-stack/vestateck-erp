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

drop policy "app_users_select_tenant" on "public"."app_users";

drop policy "approval_actions_select_tenant" on "public"."approval_actions";

drop policy "approval_assignments_admin_delete" on "public"."approval_assignments";

drop policy "approval_assignments_admin_insert" on "public"."approval_assignments";

drop policy "approval_assignments_admin_select" on "public"."approval_assignments";

drop policy "approval_assignments_admin_update" on "public"."approval_assignments";

drop policy "approval_delegations_insert_own" on "public"."approval_delegations";

drop policy "asset_assignments_select" on "public"."asset_assignments";

drop policy "asset_requests_select" on "public"."asset_requests";

drop policy "assets_select" on "public"."assets";

drop policy "bd_activities_select" on "public"."bd_activities";

drop policy "bd_activities_write_delete" on "public"."bd_activities";

drop policy "bd_activities_write_insert" on "public"."bd_activities";

drop policy "bd_activities_write_update" on "public"."bd_activities";

drop policy "bd_client_categories_select" on "public"."bd_client_categories";

drop policy "bd_client_categories_write_delete" on "public"."bd_client_categories";

drop policy "bd_client_categories_write_insert" on "public"."bd_client_categories";

drop policy "bd_client_categories_write_update" on "public"."bd_client_categories";

drop policy "bd_clients_select" on "public"."bd_clients";

drop policy "bd_clients_write_delete" on "public"."bd_clients";

drop policy "bd_clients_write_insert" on "public"."bd_clients";

drop policy "bd_clients_write_update" on "public"."bd_clients";

drop policy "bd_contacts_select" on "public"."bd_contacts";

drop policy "bd_contacts_write_delete" on "public"."bd_contacts";

drop policy "bd_contacts_write_insert" on "public"."bd_contacts";

drop policy "bd_contacts_write_update" on "public"."bd_contacts";

drop policy "bd_lead_sources_select" on "public"."bd_lead_sources";

drop policy "bd_lead_sources_write_delete" on "public"."bd_lead_sources";

drop policy "bd_lead_sources_write_insert" on "public"."bd_lead_sources";

drop policy "bd_lead_sources_write_update" on "public"."bd_lead_sources";

drop policy "bd_lead_statuses_select" on "public"."bd_lead_statuses";

drop policy "bd_lead_statuses_write_delete" on "public"."bd_lead_statuses";

drop policy "bd_lead_statuses_write_insert" on "public"."bd_lead_statuses";

drop policy "bd_lead_statuses_write_update" on "public"."bd_lead_statuses";

drop policy "bd_leads_select" on "public"."bd_leads";

drop policy "bd_leads_write_delete" on "public"."bd_leads";

drop policy "bd_leads_write_insert" on "public"."bd_leads";

drop policy "bd_leads_write_update" on "public"."bd_leads";

drop policy "bd_opportunities_select" on "public"."bd_opportunities";

drop policy "bd_opportunities_write_delete" on "public"."bd_opportunities";

drop policy "bd_opportunities_write_insert" on "public"."bd_opportunities";

drop policy "bd_opportunities_write_update" on "public"."bd_opportunities";

drop policy "bd_opportunity_stages_select" on "public"."bd_opportunity_stages";

drop policy "bd_opportunity_stages_write_delete" on "public"."bd_opportunity_stages";

drop policy "bd_opportunity_stages_write_insert" on "public"."bd_opportunity_stages";

drop policy "bd_opportunity_stages_write_update" on "public"."bd_opportunity_stages";

drop policy "bd_proposal_statuses_select" on "public"."bd_proposal_statuses";

drop policy "bd_proposal_statuses_write_delete" on "public"."bd_proposal_statuses";

drop policy "bd_proposal_statuses_write_insert" on "public"."bd_proposal_statuses";

drop policy "bd_proposal_statuses_write_update" on "public"."bd_proposal_statuses";

drop policy "bd_proposal_templates_select" on "public"."bd_proposal_templates";

drop policy "bd_proposal_templates_write_delete" on "public"."bd_proposal_templates";

drop policy "bd_proposal_templates_write_insert" on "public"."bd_proposal_templates";

drop policy "bd_proposal_templates_write_update" on "public"."bd_proposal_templates";

drop policy "bd_proposal_types_select" on "public"."bd_proposal_types";

drop policy "bd_proposal_types_write_delete" on "public"."bd_proposal_types";

drop policy "bd_proposal_types_write_insert" on "public"."bd_proposal_types";

drop policy "bd_proposal_types_write_update" on "public"."bd_proposal_types";

drop policy "bd_proposals_select" on "public"."bd_proposals";

drop policy "bd_proposals_write_delete" on "public"."bd_proposals";

drop policy "bd_proposals_write_insert" on "public"."bd_proposals";

drop policy "bd_proposals_write_update" on "public"."bd_proposals";

drop policy "bd_tender_types_select" on "public"."bd_tender_types";

drop policy "bd_tender_types_write_delete" on "public"."bd_tender_types";

drop policy "bd_tender_types_write_insert" on "public"."bd_tender_types";

drop policy "bd_tender_types_write_update" on "public"."bd_tender_types";

drop policy "bd_tenders_select" on "public"."bd_tenders";

drop policy "bd_tenders_write_delete" on "public"."bd_tenders";

drop policy "bd_tenders_write_insert" on "public"."bd_tenders";

drop policy "bd_tenders_write_update" on "public"."bd_tenders";

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

drop policy "fuel_logs_write_delete" on "public"."fuel_logs";

drop policy "fuel_logs_write_insert" on "public"."fuel_logs";

drop policy "fuel_logs_write_update" on "public"."fuel_logs";

drop policy "goods_issue_items_select" on "public"."goods_issue_items";

drop policy "goods_issues_select" on "public"."goods_issues";

drop policy "hr_appraisals_select" on "public"."hr_appraisals";

drop policy "hr_appraisals_write_delete" on "public"."hr_appraisals";

drop policy "hr_appraisals_write_insert" on "public"."hr_appraisals";

drop policy "hr_appraisals_write_update" on "public"."hr_appraisals";

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

drop policy "hr_trainings_write_delete" on "public"."hr_trainings";

drop policy "hr_trainings_write_insert" on "public"."hr_trainings";

drop policy "hr_trainings_write_update" on "public"."hr_trainings";

drop policy "impersonation_logs_select_platform_admin" on "public"."impersonation_logs";

drop policy "invitations_insert" on "public"."invitations";

drop policy "invitations_select" on "public"."invitations";

drop policy "invoice_requests_insert_own" on "public"."invoice_requests";

drop policy "invoice_requests_select_own_or_actionable" on "public"."invoice_requests";

drop policy "it_tickets_insert" on "public"."it_tickets";

drop policy "it_tickets_select" on "public"."it_tickets";

drop policy "kb_articles_select" on "public"."kb_articles";

drop policy "law_hearings_select" on "public"."law_case_hearings";

drop policy "law_hearings_write_delete" on "public"."law_case_hearings";

drop policy "law_hearings_write_insert" on "public"."law_case_hearings";

drop policy "law_hearings_write_update" on "public"."law_case_hearings";

drop policy "law_case_types_delete" on "public"."law_case_types";

drop policy "law_case_types_insert" on "public"."law_case_types";

drop policy "law_case_types_select" on "public"."law_case_types";

drop policy "law_case_types_update" on "public"."law_case_types";

drop policy "law_cases_delete" on "public"."law_cases";

drop policy "law_cases_insert" on "public"."law_cases";

drop policy "law_cases_select" on "public"."law_cases";

drop policy "law_cases_update" on "public"."law_cases";

drop policy "law_compliance_delete" on "public"."law_compliance_register";

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

drop policy "law_filings_write_delete" on "public"."law_regulatory_filings";

drop policy "law_filings_write_insert" on "public"."law_regulatory_filings";

drop policy "law_filings_write_update" on "public"."law_regulatory_filings";

drop policy "licenses_select" on "public"."licenses";

drop policy "line_item_receipts_select" on "public"."line_item_receipts";

drop policy "machine_assignments_select" on "public"."machine_assignments";

drop policy "machine_assignments_write_delete" on "public"."machine_assignments";

drop policy "machine_assignments_write_insert" on "public"."machine_assignments";

drop policy "machine_assignments_write_update" on "public"."machine_assignments";

drop policy "machine_types_select" on "public"."machine_types";

drop policy "machine_types_write_delete" on "public"."machine_types";

drop policy "machine_types_write_insert" on "public"."machine_types";

drop policy "machine_types_write_update" on "public"."machine_types";

drop policy "machines_select" on "public"."machines";

drop policy "machines_write_delete" on "public"."machines";

drop policy "machines_write_insert" on "public"."machines";

drop policy "machines_write_update" on "public"."machines";

drop policy "maintenance_requests_select" on "public"."maintenance_requests";

drop policy "maintenance_requests_write_delete" on "public"."maintenance_requests";

drop policy "maintenance_requests_write_insert" on "public"."maintenance_requests";

drop policy "maintenance_requests_write_update" on "public"."maintenance_requests";

drop policy "maintenance_types_select" on "public"."maintenance_types";

drop policy "maintenance_types_write_delete" on "public"."maintenance_types";

drop policy "maintenance_types_write_insert" on "public"."maintenance_types";

drop policy "maintenance_types_write_update" on "public"."maintenance_types";

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

drop policy "operation_logs_write_delete" on "public"."operation_logs";

drop policy "operation_logs_write_insert" on "public"."operation_logs";

drop policy "operation_logs_write_update" on "public"."operation_logs";

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

drop policy "platform_settings_select_admin" on "public"."platform_settings";

drop policy "platform_settings_update_admin" on "public"."platform_settings";

drop policy "pmo_milestones_select" on "public"."pmo_milestones";

drop policy "pmo_milestones_write_delete" on "public"."pmo_milestones";

drop policy "pmo_milestones_write_insert" on "public"."pmo_milestones";

drop policy "pmo_milestones_write_update" on "public"."pmo_milestones";

drop policy "pmo_project_categories_select" on "public"."pmo_project_categories";

drop policy "pmo_project_categories_write_delete" on "public"."pmo_project_categories";

drop policy "pmo_project_categories_write_insert" on "public"."pmo_project_categories";

drop policy "pmo_project_categories_write_update" on "public"."pmo_project_categories";

drop policy "pmo_projects_select" on "public"."pmo_projects";

drop policy "pmo_projects_write_delete" on "public"."pmo_projects";

drop policy "pmo_projects_write_insert" on "public"."pmo_projects";

drop policy "pmo_projects_write_update" on "public"."pmo_projects";

drop policy "pmo_resource_allocations_select" on "public"."pmo_resource_allocations";

drop policy "pmo_resource_allocations_write_delete" on "public"."pmo_resource_allocations";

drop policy "pmo_resource_allocations_write_insert" on "public"."pmo_resource_allocations";

drop policy "pmo_resource_allocations_write_update" on "public"."pmo_resource_allocations";

drop policy "pmo_task_types_select" on "public"."pmo_task_types";

drop policy "pmo_task_types_write_delete" on "public"."pmo_task_types";

drop policy "pmo_task_types_write_insert" on "public"."pmo_task_types";

drop policy "pmo_task_types_write_update" on "public"."pmo_task_types";

drop policy "pmo_tasks_select" on "public"."pmo_tasks";

drop policy "pmo_tasks_write_delete" on "public"."pmo_tasks";

drop policy "pmo_tasks_write_insert" on "public"."pmo_tasks";

drop policy "pmo_tasks_write_update" on "public"."pmo_tasks";

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

drop policy "sustain_audits_write_delete" on "public"."sustainability_audits";

drop policy "sustain_audits_write_insert" on "public"."sustainability_audits";

drop policy "sustain_audits_write_update" on "public"."sustainability_audits";

drop policy "sustain_certs_select" on "public"."sustainability_certifications";

drop policy "sustain_certs_write_delete" on "public"."sustainability_certifications";

drop policy "sustain_certs_write_insert" on "public"."sustainability_certifications";

drop policy "sustain_certs_write_update" on "public"."sustainability_certifications";

drop policy "sustain_init_cat_select" on "public"."sustainability_initiative_categories";

drop policy "sustain_init_cat_write_delete" on "public"."sustainability_initiative_categories";

drop policy "sustain_init_cat_write_insert" on "public"."sustainability_initiative_categories";

drop policy "sustain_init_cat_write_update" on "public"."sustainability_initiative_categories";

drop policy "sustain_initiatives_select" on "public"."sustainability_initiatives";

drop policy "sustain_initiatives_write_delete" on "public"."sustainability_initiatives";

drop policy "sustain_initiatives_write_insert" on "public"."sustainability_initiatives";

drop policy "sustain_initiatives_write_update" on "public"."sustainability_initiatives";

drop policy "sustain_metric_types_select" on "public"."sustainability_metric_types";

drop policy "sustain_metric_types_write_delete" on "public"."sustainability_metric_types";

drop policy "sustain_metric_types_write_insert" on "public"."sustainability_metric_types";

drop policy "sustain_metric_types_write_update" on "public"."sustainability_metric_types";

drop policy "sustain_metrics_select" on "public"."sustainability_metrics";

drop policy "sustain_metrics_write_delete" on "public"."sustainability_metrics";

drop policy "sustain_metrics_write_insert" on "public"."sustainability_metrics";

drop policy "sustain_metrics_write_update" on "public"."sustainability_metrics";

drop policy "tenant_modules_delete_platform_admin" on "public"."tenant_modules";

drop policy "tenant_modules_insert_platform_admin" on "public"."tenant_modules";

drop policy "tenant_modules_select" on "public"."tenant_modules";

drop policy "tenants_select" on "public"."tenants";

drop policy "ticket_categories_select" on "public"."ticket_categories";

drop policy "user_group_members_select" on "public"."user_group_members";

drop policy "user_groups_select" on "public"."user_groups";

drop policy "warehouses_insert" on "public"."warehouses";

drop policy "warehouses_select" on "public"."warehouses";

drop policy "warehouses_update" on "public"."warehouses";

drop policy "workflow_stages_admin_delete" on "public"."workflow_stages";

drop policy "workflow_stages_admin_insert" on "public"."workflow_stages";

drop policy "workflow_stages_admin_update" on "public"."workflow_stages";

drop policy "workflow_stages_select_tenant" on "public"."workflow_stages";

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

alter table "public"."bd_activities" drop constraint "bd_activities_tenant_id_fkey";

alter table "public"."bd_client_categories" drop constraint "bd_client_categories_tenant_id_fkey";

alter table "public"."bd_clients" drop constraint "bd_clients_category_id_fkey";

alter table "public"."bd_clients" drop constraint "bd_clients_created_by_fkey";

alter table "public"."bd_clients" drop constraint "bd_clients_tenant_id_fkey";

alter table "public"."bd_contacts" drop constraint "bd_contacts_client_id_fkey";

alter table "public"."bd_contacts" drop constraint "bd_contacts_tenant_id_fkey";

alter table "public"."bd_lead_sources" drop constraint "bd_lead_sources_tenant_id_fkey";

alter table "public"."bd_lead_statuses" drop constraint "bd_lead_statuses_tenant_id_fkey";

alter table "public"."bd_leads" drop constraint "bd_leads_converted_opportunity_fk";

alter table "public"."bd_leads" drop constraint "bd_leads_created_by_fkey";

alter table "public"."bd_leads" drop constraint "bd_leads_source_id_fkey";

alter table "public"."bd_leads" drop constraint "bd_leads_tenant_id_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_client_id_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_created_by_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_lead_id_fkey";

alter table "public"."bd_opportunities" drop constraint "bd_opportunities_tenant_id_stage_fkey";

alter table "public"."bd_opportunity_stages" drop constraint "bd_opportunity_stages_tenant_id_fkey";

alter table "public"."bd_proposal_statuses" drop constraint "bd_proposal_statuses_tenant_id_fkey";

alter table "public"."bd_proposal_templates" drop constraint "bd_proposal_templates_tenant_id_fkey";

alter table "public"."bd_proposal_types" drop constraint "bd_proposal_types_tenant_id_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_client_id_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_created_by_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_decided_by_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_opportunity_id_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_tenant_id_status_fkey";

alter table "public"."bd_proposals" drop constraint "bd_proposals_type_id_fkey";

alter table "public"."bd_tender_types" drop constraint "bd_tender_types_tenant_id_fkey";

alter table "public"."bd_tenders" drop constraint "bd_tenders_client_id_fkey";

alter table "public"."bd_tenders" drop constraint "bd_tenders_created_by_fkey";

alter table "public"."bd_tenders" drop constraint "bd_tenders_tenant_id_fkey";

alter table "public"."bd_tenders" drop constraint "bd_tenders_type_id_fkey";

alter table "public"."cash_bank_transactions" drop constraint "cash_bank_transactions_recorded_by_fkey";

alter table "public"."cash_bank_transactions" drop constraint "cash_bank_transactions_tenant_id_fkey";

alter table "public"."cost_centers" drop constraint "cost_centers_tenant_id_fkey";

alter table "public"."departments" drop constraint "departments_parent_department_id_fkey";

alter table "public"."departments" drop constraint "departments_tenant_id_fkey";

alter table "public"."doc_sequences" drop constraint "doc_sequences_tenant_id_fkey";

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

alter table "public"."fuel_logs" drop constraint "fuel_logs_tenant_id_fkey";

alter table "public"."goods_issue_items" drop constraint "goods_issue_items_cost_center_id_fkey";

alter table "public"."goods_issue_items" drop constraint "goods_issue_items_goods_issue_id_fkey";

alter table "public"."goods_issue_items" drop constraint "goods_issue_items_material_catalog_id_fkey";

alter table "public"."goods_issues" drop constraint "goods_issues_tenant_id_fkey";

alter table "public"."goods_issues" drop constraint "goods_issues_warehouse_id_fkey";

alter table "public"."goods_issues" drop constraint "goods_issues_warehouse_officer_id_fkey";

alter table "public"."hr_appraisals" drop constraint "hr_appraisals_created_by_fkey";

alter table "public"."hr_appraisals" drop constraint "hr_appraisals_employee_id_fkey";

alter table "public"."hr_appraisals" drop constraint "hr_appraisals_tenant_id_fkey";

alter table "public"."hr_attendance" drop constraint "hr_attendance_employee_id_fkey";

alter table "public"."hr_attendance" drop constraint "hr_attendance_tenant_id_fkey";

alter table "public"."hr_employee_compensation" drop constraint "hr_employee_compensation_created_by_fkey";

alter table "public"."hr_employee_compensation" drop constraint "hr_employee_compensation_employee_id_fkey";

alter table "public"."hr_employee_compensation" drop constraint "hr_employee_compensation_tenant_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_department_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_manager_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_position_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_tenant_id_fkey";

alter table "public"."hr_employees" drop constraint "hr_employees_user_id_fkey";

alter table "public"."hr_job_applications" drop constraint "hr_job_applications_job_posting_id_fkey";

alter table "public"."hr_job_applications" drop constraint "hr_job_applications_tenant_id_fkey";

alter table "public"."hr_job_postings" drop constraint "hr_job_postings_department_id_fkey";

alter table "public"."hr_job_postings" drop constraint "hr_job_postings_position_id_fkey";

alter table "public"."hr_job_postings" drop constraint "hr_job_postings_tenant_id_fkey";

alter table "public"."hr_leave_requests" drop constraint "hr_leave_requests_approver_id_fkey";

alter table "public"."hr_leave_requests" drop constraint "hr_leave_requests_employee_id_fkey";

alter table "public"."hr_leave_requests" drop constraint "hr_leave_requests_leave_type_id_fkey";

alter table "public"."hr_leave_requests" drop constraint "hr_leave_requests_tenant_id_fkey";

alter table "public"."hr_leave_types" drop constraint "hr_leave_types_tenant_id_fkey";

alter table "public"."hr_payroll_items" drop constraint "hr_payroll_items_employee_id_fkey";

alter table "public"."hr_payroll_items" drop constraint "hr_payroll_items_payroll_run_id_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_approved_by_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_prepared_by_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_rejected_by_fkey";

alter table "public"."hr_payroll_runs" drop constraint "hr_payroll_runs_tenant_id_fkey";

alter table "public"."hr_positions" drop constraint "hr_positions_tenant_id_fkey";

alter table "public"."hr_team_members" drop constraint "hr_team_members_tenant_id_fkey";

alter table "public"."hr_team_members" drop constraint "hr_team_members_user_id_fkey";

alter table "public"."hr_trainings" drop constraint "hr_trainings_created_by_fkey";

alter table "public"."hr_trainings" drop constraint "hr_trainings_tenant_id_fkey";

alter table "public"."impersonation_logs" drop constraint "impersonation_logs_tenant_id_fkey";

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

alter table "public"."law_case_hearings" drop constraint "law_case_hearings_tenant_id_fkey";

alter table "public"."law_case_types" drop constraint "law_case_types_tenant_id_fkey";

alter table "public"."law_cases" drop constraint "law_cases_created_by_fkey";

alter table "public"."law_cases" drop constraint "law_cases_tenant_id_fkey";

alter table "public"."law_cases" drop constraint "law_cases_type_id_fkey";

alter table "public"."law_compliance_register" drop constraint "law_compliance_register_created_by_fkey";

alter table "public"."law_compliance_register" drop constraint "law_compliance_register_owner_id_fkey";

alter table "public"."law_compliance_register" drop constraint "law_compliance_register_tenant_id_fkey";

alter table "public"."law_contract_types" drop constraint "law_contract_types_tenant_id_fkey";

alter table "public"."law_contracts" drop constraint "law_contracts_created_by_fkey";

alter table "public"."law_contracts" drop constraint "law_contracts_tenant_id_fkey";

alter table "public"."law_contracts" drop constraint "law_contracts_type_id_fkey";

alter table "public"."law_regulatory_filings" drop constraint "law_regulatory_filings_created_by_fkey";

alter table "public"."law_regulatory_filings" drop constraint "law_regulatory_filings_tenant_id_fkey";

alter table "public"."licenses" drop constraint "licenses_asset_id_fkey";

alter table "public"."licenses" drop constraint "licenses_tenant_id_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_approved_by_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_line_item_id_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_received_by_fkey";

alter table "public"."line_item_receipts" drop constraint "line_item_receipts_warehouse_id_fkey";

alter table "public"."machine_assignments" drop constraint "machine_assignments_machine_id_fkey";

alter table "public"."machine_assignments" drop constraint "machine_assignments_tenant_id_fkey";

alter table "public"."machine_types" drop constraint "machine_types_tenant_id_fkey";

alter table "public"."machines" drop constraint "machines_tenant_id_fkey";

alter table "public"."machines" drop constraint "machines_type_id_fkey";

alter table "public"."maintenance_requests" drop constraint "maintenance_requests_machine_id_fkey";

alter table "public"."maintenance_requests" drop constraint "maintenance_requests_requested_by_fkey";

alter table "public"."maintenance_requests" drop constraint "maintenance_requests_tenant_id_fkey";

alter table "public"."maintenance_types" drop constraint "maintenance_types_tenant_id_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_external_material_group_id_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_material_group_id_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_material_type_id_fkey";

alter table "public"."material_catalog" drop constraint "material_catalog_tenant_id_fkey";

alter table "public"."material_groups" drop constraint "material_groups_tenant_id_fkey";

alter table "public"."material_receipt_assignments" drop constraint "material_receipt_assignments_assigned_by_fkey";

alter table "public"."material_receipt_assignments" drop constraint "material_receipt_assignments_tenant_id_fkey";

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

alter table "public"."operation_logs" drop constraint "operation_logs_tenant_id_fkey";

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

alter table "public"."pmo_milestones" drop constraint "pmo_milestones_tenant_id_fkey";

alter table "public"."pmo_project_categories" drop constraint "pmo_project_categories_tenant_id_fkey";

alter table "public"."pmo_projects" drop constraint "pmo_projects_category_id_fkey";

alter table "public"."pmo_projects" drop constraint "pmo_projects_manager_id_fkey";

alter table "public"."pmo_projects" drop constraint "pmo_projects_tenant_id_fkey";

alter table "public"."pmo_resource_allocations" drop constraint "pmo_resource_allocations_employee_id_fkey";

alter table "public"."pmo_resource_allocations" drop constraint "pmo_resource_allocations_project_id_fkey";

alter table "public"."pmo_resource_allocations" drop constraint "pmo_resource_allocations_tenant_id_fkey";

alter table "public"."pmo_task_types" drop constraint "pmo_task_types_tenant_id_fkey";

alter table "public"."pmo_tasks" drop constraint "pmo_tasks_assignee_id_fkey";

alter table "public"."pmo_tasks" drop constraint "pmo_tasks_project_id_fkey";

alter table "public"."pmo_tasks" drop constraint "pmo_tasks_tenant_id_fkey";

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

alter table "public"."sap_payments" drop constraint "sap_payments_tenant_id_fkey";

alter table "public"."sla_policies" drop constraint "sla_policies_tenant_id_fkey";

alter table "public"."staff_roles" drop constraint "staff_roles_tenant_id_fkey";

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

alter table "public"."sustainability_audits" drop constraint "sustainability_audits_tenant_id_fkey";

alter table "public"."sustainability_certifications" drop constraint "sustainability_certifications_created_by_fkey";

alter table "public"."sustainability_certifications" drop constraint "sustainability_certifications_tenant_id_fkey";

alter table "public"."sustainability_initiative_categories" drop constraint "sustainability_initiative_categories_tenant_id_fkey";

alter table "public"."sustainability_initiatives" drop constraint "sustainability_initiatives_category_id_fkey";

alter table "public"."sustainability_initiatives" drop constraint "sustainability_initiatives_created_by_fkey";

alter table "public"."sustainability_initiatives" drop constraint "sustainability_initiatives_tenant_id_fkey";

alter table "public"."sustainability_metric_types" drop constraint "sustainability_metric_types_tenant_id_fkey";

alter table "public"."sustainability_metrics" drop constraint "sustainability_metrics_created_by_fkey";

alter table "public"."sustainability_metrics" drop constraint "sustainability_metrics_metric_type_id_fkey";

alter table "public"."sustainability_metrics" drop constraint "sustainability_metrics_tenant_id_fkey";

alter table "public"."tenant_modules" drop constraint "tenant_modules_enabled_by_fkey";

alter table "public"."tenant_modules" drop constraint "tenant_modules_tenant_id_fkey";

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

alter table "public"."bd_activities" add constraint "bd_activities_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_activities" validate constraint "bd_activities_tenant_id_fkey";

alter table "public"."bd_client_categories" add constraint "bd_client_categories_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_client_categories" validate constraint "bd_client_categories_tenant_id_fkey";

alter table "public"."bd_clients" add constraint "bd_clients_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.bd_client_categories(id) ON DELETE SET NULL not valid;

alter table "public"."bd_clients" validate constraint "bd_clients_category_id_fkey";

alter table "public"."bd_clients" add constraint "bd_clients_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_clients" validate constraint "bd_clients_created_by_fkey";

alter table "public"."bd_clients" add constraint "bd_clients_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_clients" validate constraint "bd_clients_tenant_id_fkey";

alter table "public"."bd_contacts" add constraint "bd_contacts_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE CASCADE not valid;

alter table "public"."bd_contacts" validate constraint "bd_contacts_client_id_fkey";

alter table "public"."bd_contacts" add constraint "bd_contacts_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_contacts" validate constraint "bd_contacts_tenant_id_fkey";

alter table "public"."bd_lead_sources" add constraint "bd_lead_sources_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_lead_sources" validate constraint "bd_lead_sources_tenant_id_fkey";

alter table "public"."bd_lead_statuses" add constraint "bd_lead_statuses_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_lead_statuses" validate constraint "bd_lead_statuses_tenant_id_fkey";

alter table "public"."bd_leads" add constraint "bd_leads_converted_opportunity_fk" FOREIGN KEY (converted_opportunity_id) REFERENCES public.bd_opportunities(id) ON DELETE SET NULL not valid;

alter table "public"."bd_leads" validate constraint "bd_leads_converted_opportunity_fk";

alter table "public"."bd_leads" add constraint "bd_leads_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_leads" validate constraint "bd_leads_created_by_fkey";

alter table "public"."bd_leads" add constraint "bd_leads_source_id_fkey" FOREIGN KEY (source_id) REFERENCES public.bd_lead_sources(id) ON DELETE SET NULL not valid;

alter table "public"."bd_leads" validate constraint "bd_leads_source_id_fkey";

alter table "public"."bd_leads" add constraint "bd_leads_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_leads" validate constraint "bd_leads_tenant_id_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE SET NULL not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_client_id_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_created_by_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_lead_id_fkey" FOREIGN KEY (lead_id) REFERENCES public.bd_leads(id) ON DELETE SET NULL not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_lead_id_fkey";

alter table "public"."bd_opportunities" add constraint "bd_opportunities_tenant_id_stage_fkey" FOREIGN KEY (tenant_id, stage) REFERENCES public.bd_opportunity_stages(tenant_id, stage) not valid;

alter table "public"."bd_opportunities" validate constraint "bd_opportunities_tenant_id_stage_fkey";

alter table "public"."bd_opportunity_stages" add constraint "bd_opportunity_stages_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_opportunity_stages" validate constraint "bd_opportunity_stages_tenant_id_fkey";

alter table "public"."bd_proposal_statuses" add constraint "bd_proposal_statuses_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_proposal_statuses" validate constraint "bd_proposal_statuses_tenant_id_fkey";

alter table "public"."bd_proposal_templates" add constraint "bd_proposal_templates_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_proposal_templates" validate constraint "bd_proposal_templates_tenant_id_fkey";

alter table "public"."bd_proposal_types" add constraint "bd_proposal_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_proposal_types" validate constraint "bd_proposal_types_tenant_id_fkey";

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

alter table "public"."bd_tender_types" add constraint "bd_tender_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_tender_types" validate constraint "bd_tender_types_tenant_id_fkey";

alter table "public"."bd_tenders" add constraint "bd_tenders_client_id_fkey" FOREIGN KEY (client_id) REFERENCES public.bd_clients(id) ON DELETE SET NULL not valid;

alter table "public"."bd_tenders" validate constraint "bd_tenders_client_id_fkey";

alter table "public"."bd_tenders" add constraint "bd_tenders_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."bd_tenders" validate constraint "bd_tenders_created_by_fkey";

alter table "public"."bd_tenders" add constraint "bd_tenders_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."bd_tenders" validate constraint "bd_tenders_tenant_id_fkey";

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

alter table "public"."doc_sequences" add constraint "doc_sequences_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."doc_sequences" validate constraint "doc_sequences_tenant_id_fkey";

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

alter table "public"."fuel_logs" add constraint "fuel_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."fuel_logs" validate constraint "fuel_logs_tenant_id_fkey";

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

alter table "public"."hr_appraisals" add constraint "hr_appraisals_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_appraisals" validate constraint "hr_appraisals_tenant_id_fkey";

alter table "public"."hr_attendance" add constraint "hr_attendance_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."hr_attendance" validate constraint "hr_attendance_employee_id_fkey";

alter table "public"."hr_attendance" add constraint "hr_attendance_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_attendance" validate constraint "hr_attendance_tenant_id_fkey";

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

alter table "public"."hr_employees" add constraint "hr_employees_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_employees" validate constraint "hr_employees_tenant_id_fkey";

alter table "public"."hr_employees" add constraint "hr_employees_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."hr_employees" validate constraint "hr_employees_user_id_fkey";

alter table "public"."hr_job_applications" add constraint "hr_job_applications_job_posting_id_fkey" FOREIGN KEY (job_posting_id) REFERENCES public.hr_job_postings(id) ON DELETE SET NULL not valid;

alter table "public"."hr_job_applications" validate constraint "hr_job_applications_job_posting_id_fkey";

alter table "public"."hr_job_applications" add constraint "hr_job_applications_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_job_applications" validate constraint "hr_job_applications_tenant_id_fkey";

alter table "public"."hr_job_postings" add constraint "hr_job_postings_department_id_fkey" FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE SET NULL not valid;

alter table "public"."hr_job_postings" validate constraint "hr_job_postings_department_id_fkey";

alter table "public"."hr_job_postings" add constraint "hr_job_postings_position_id_fkey" FOREIGN KEY (position_id) REFERENCES public.hr_positions(id) ON DELETE SET NULL not valid;

alter table "public"."hr_job_postings" validate constraint "hr_job_postings_position_id_fkey";

alter table "public"."hr_job_postings" add constraint "hr_job_postings_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_job_postings" validate constraint "hr_job_postings_tenant_id_fkey";

alter table "public"."hr_leave_requests" add constraint "hr_leave_requests_approver_id_fkey" FOREIGN KEY (approver_id) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_leave_requests" validate constraint "hr_leave_requests_approver_id_fkey";

alter table "public"."hr_leave_requests" add constraint "hr_leave_requests_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."hr_leave_requests" validate constraint "hr_leave_requests_employee_id_fkey";

alter table "public"."hr_leave_requests" add constraint "hr_leave_requests_leave_type_id_fkey" FOREIGN KEY (leave_type_id) REFERENCES public.hr_leave_types(id) ON DELETE RESTRICT not valid;

alter table "public"."hr_leave_requests" validate constraint "hr_leave_requests_leave_type_id_fkey";

alter table "public"."hr_leave_requests" add constraint "hr_leave_requests_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_leave_requests" validate constraint "hr_leave_requests_tenant_id_fkey";

alter table "public"."hr_leave_types" add constraint "hr_leave_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_leave_types" validate constraint "hr_leave_types_tenant_id_fkey";

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

alter table "public"."hr_positions" add constraint "hr_positions_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_positions" validate constraint "hr_positions_tenant_id_fkey";

alter table "public"."hr_team_members" add constraint "hr_team_members_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_team_members" validate constraint "hr_team_members_tenant_id_fkey";

alter table "public"."hr_team_members" add constraint "hr_team_members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_team_members" validate constraint "hr_team_members_user_id_fkey";

alter table "public"."hr_trainings" add constraint "hr_trainings_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."hr_trainings" validate constraint "hr_trainings_created_by_fkey";

alter table "public"."hr_trainings" add constraint "hr_trainings_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."hr_trainings" validate constraint "hr_trainings_tenant_id_fkey";

alter table "public"."impersonation_logs" add constraint "impersonation_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."impersonation_logs" validate constraint "impersonation_logs_tenant_id_fkey";

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

alter table "public"."law_case_hearings" add constraint "law_case_hearings_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."law_case_hearings" validate constraint "law_case_hearings_tenant_id_fkey";

alter table "public"."law_case_types" add constraint "law_case_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."law_case_types" validate constraint "law_case_types_tenant_id_fkey";

alter table "public"."law_cases" add constraint "law_cases_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_cases" validate constraint "law_cases_created_by_fkey";

alter table "public"."law_cases" add constraint "law_cases_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."law_cases" validate constraint "law_cases_tenant_id_fkey";

alter table "public"."law_cases" add constraint "law_cases_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.law_case_types(id) ON DELETE SET NULL not valid;

alter table "public"."law_cases" validate constraint "law_cases_type_id_fkey";

alter table "public"."law_compliance_register" add constraint "law_compliance_register_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_compliance_register" validate constraint "law_compliance_register_created_by_fkey";

alter table "public"."law_compliance_register" add constraint "law_compliance_register_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES public.app_users(id) not valid;

alter table "public"."law_compliance_register" validate constraint "law_compliance_register_owner_id_fkey";

alter table "public"."law_compliance_register" add constraint "law_compliance_register_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."law_compliance_register" validate constraint "law_compliance_register_tenant_id_fkey";

alter table "public"."law_contract_types" add constraint "law_contract_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."law_contract_types" validate constraint "law_contract_types_tenant_id_fkey";

alter table "public"."law_contracts" add constraint "law_contracts_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_contracts" validate constraint "law_contracts_created_by_fkey";

alter table "public"."law_contracts" add constraint "law_contracts_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."law_contracts" validate constraint "law_contracts_tenant_id_fkey";

alter table "public"."law_contracts" add constraint "law_contracts_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.law_contract_types(id) ON DELETE SET NULL not valid;

alter table "public"."law_contracts" validate constraint "law_contracts_type_id_fkey";

alter table "public"."law_regulatory_filings" add constraint "law_regulatory_filings_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."law_regulatory_filings" validate constraint "law_regulatory_filings_created_by_fkey";

alter table "public"."law_regulatory_filings" add constraint "law_regulatory_filings_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."law_regulatory_filings" validate constraint "law_regulatory_filings_tenant_id_fkey";

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

alter table "public"."machine_assignments" add constraint "machine_assignments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."machine_assignments" validate constraint "machine_assignments_tenant_id_fkey";

alter table "public"."machine_types" add constraint "machine_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."machine_types" validate constraint "machine_types_tenant_id_fkey";

alter table "public"."machines" add constraint "machines_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."machines" validate constraint "machines_tenant_id_fkey";

alter table "public"."machines" add constraint "machines_type_id_fkey" FOREIGN KEY (type_id) REFERENCES public.machine_types(id) ON DELETE SET NULL not valid;

alter table "public"."machines" validate constraint "machines_type_id_fkey";

alter table "public"."maintenance_requests" add constraint "maintenance_requests_machine_id_fkey" FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE CASCADE not valid;

alter table "public"."maintenance_requests" validate constraint "maintenance_requests_machine_id_fkey";

alter table "public"."maintenance_requests" add constraint "maintenance_requests_requested_by_fkey" FOREIGN KEY (requested_by) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."maintenance_requests" validate constraint "maintenance_requests_requested_by_fkey";

alter table "public"."maintenance_requests" add constraint "maintenance_requests_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."maintenance_requests" validate constraint "maintenance_requests_tenant_id_fkey";

alter table "public"."maintenance_types" add constraint "maintenance_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."maintenance_types" validate constraint "maintenance_types_tenant_id_fkey";

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

alter table "public"."material_receipt_assignments" add constraint "material_receipt_assignments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."material_receipt_assignments" validate constraint "material_receipt_assignments_tenant_id_fkey";

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

alter table "public"."operation_logs" add constraint "operation_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."operation_logs" validate constraint "operation_logs_tenant_id_fkey";

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

alter table "public"."pmo_milestones" add constraint "pmo_milestones_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_milestones" validate constraint "pmo_milestones_tenant_id_fkey";

alter table "public"."pmo_project_categories" add constraint "pmo_project_categories_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_project_categories" validate constraint "pmo_project_categories_tenant_id_fkey";

alter table "public"."pmo_projects" add constraint "pmo_projects_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.pmo_project_categories(id) ON DELETE SET NULL not valid;

alter table "public"."pmo_projects" validate constraint "pmo_projects_category_id_fkey";

alter table "public"."pmo_projects" add constraint "pmo_projects_manager_id_fkey" FOREIGN KEY (manager_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."pmo_projects" validate constraint "pmo_projects_manager_id_fkey";

alter table "public"."pmo_projects" add constraint "pmo_projects_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_projects" validate constraint "pmo_projects_tenant_id_fkey";

alter table "public"."pmo_resource_allocations" add constraint "pmo_resource_allocations_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES public.hr_employees(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_resource_allocations" validate constraint "pmo_resource_allocations_employee_id_fkey";

alter table "public"."pmo_resource_allocations" add constraint "pmo_resource_allocations_project_id_fkey" FOREIGN KEY (project_id) REFERENCES public.pmo_projects(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_resource_allocations" validate constraint "pmo_resource_allocations_project_id_fkey";

alter table "public"."pmo_resource_allocations" add constraint "pmo_resource_allocations_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_resource_allocations" validate constraint "pmo_resource_allocations_tenant_id_fkey";

alter table "public"."pmo_task_types" add constraint "pmo_task_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_task_types" validate constraint "pmo_task_types_tenant_id_fkey";

alter table "public"."pmo_tasks" add constraint "pmo_tasks_assignee_id_fkey" FOREIGN KEY (assignee_id) REFERENCES public.app_users(id) ON DELETE SET NULL not valid;

alter table "public"."pmo_tasks" validate constraint "pmo_tasks_assignee_id_fkey";

alter table "public"."pmo_tasks" add constraint "pmo_tasks_project_id_fkey" FOREIGN KEY (project_id) REFERENCES public.pmo_projects(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_tasks" validate constraint "pmo_tasks_project_id_fkey";

alter table "public"."pmo_tasks" add constraint "pmo_tasks_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."pmo_tasks" validate constraint "pmo_tasks_tenant_id_fkey";

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

alter table "public"."sap_payments" add constraint "sap_payments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."sap_payments" validate constraint "sap_payments_tenant_id_fkey";

alter table "public"."sla_policies" add constraint "sla_policies_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) not valid;

alter table "public"."sla_policies" validate constraint "sla_policies_tenant_id_fkey";

alter table "public"."staff_roles" add constraint "staff_roles_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."staff_roles" validate constraint "staff_roles_tenant_id_fkey";

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

alter table "public"."sustainability_audits" add constraint "sustainability_audits_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."sustainability_audits" validate constraint "sustainability_audits_tenant_id_fkey";

alter table "public"."sustainability_certifications" add constraint "sustainability_certifications_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."sustainability_certifications" validate constraint "sustainability_certifications_created_by_fkey";

alter table "public"."sustainability_certifications" add constraint "sustainability_certifications_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."sustainability_certifications" validate constraint "sustainability_certifications_tenant_id_fkey";

alter table "public"."sustainability_initiative_categories" add constraint "sustainability_initiative_categories_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."sustainability_initiative_categories" validate constraint "sustainability_initiative_categories_tenant_id_fkey";

alter table "public"."sustainability_initiatives" add constraint "sustainability_initiatives_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.sustainability_initiative_categories(id) ON DELETE SET NULL not valid;

alter table "public"."sustainability_initiatives" validate constraint "sustainability_initiatives_category_id_fkey";

alter table "public"."sustainability_initiatives" add constraint "sustainability_initiatives_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."sustainability_initiatives" validate constraint "sustainability_initiatives_created_by_fkey";

alter table "public"."sustainability_initiatives" add constraint "sustainability_initiatives_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."sustainability_initiatives" validate constraint "sustainability_initiatives_tenant_id_fkey";

alter table "public"."sustainability_metric_types" add constraint "sustainability_metric_types_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."sustainability_metric_types" validate constraint "sustainability_metric_types_tenant_id_fkey";

alter table "public"."sustainability_metrics" add constraint "sustainability_metrics_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.app_users(id) not valid;

alter table "public"."sustainability_metrics" validate constraint "sustainability_metrics_created_by_fkey";

alter table "public"."sustainability_metrics" add constraint "sustainability_metrics_metric_type_id_fkey" FOREIGN KEY (metric_type_id) REFERENCES public.sustainability_metric_types(id) ON DELETE SET NULL not valid;

alter table "public"."sustainability_metrics" validate constraint "sustainability_metrics_metric_type_id_fkey";

alter table "public"."sustainability_metrics" add constraint "sustainability_metrics_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."sustainability_metrics" validate constraint "sustainability_metrics_tenant_id_fkey";

alter table "public"."tenant_modules" add constraint "tenant_modules_enabled_by_fkey" FOREIGN KEY (enabled_by) REFERENCES public.app_users(id) not valid;

alter table "public"."tenant_modules" validate constraint "tenant_modules_enabled_by_fkey";

alter table "public"."tenant_modules" add constraint "tenant_modules_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE not valid;

alter table "public"."tenant_modules" validate constraint "tenant_modules_tenant_id_fkey";

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

CREATE OR REPLACE FUNCTION public.assign_ticket(p_ticket_id uuid, p_assignee_id uuid DEFAULT NULL::uuid)
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
          select 1 from departments d
          where d.id = u.department_id and d.name = 'IT Support'
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

CREATE OR REPLACE FUNCTION public.count_open_items_at_workflow_stage(p_stage_id uuid)
 RETURNS TABLE(open_requests bigint, open_invoices bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant uuid;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized';
  end if;

  v_tenant := get_my_tenant_id();

  if not exists (select 1 from workflow_stages where id = p_stage_id and tenant_id = v_tenant) then
    raise exception 'stage not found in this tenant';
  end if;

  return query
  select
    (select count(*) from requests
     where current_stage_id = p_stage_id and tenant_id = v_tenant and status = 'open'),
    (select count(*) from invoice_requests
     where current_stage_id = p_stage_id and tenant_id = v_tenant and status = 'open');
end;
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

CREATE OR REPLACE FUNCTION public.get_my_access_requests()
 RETURNS SETOF public.access_requests
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from access_requests where requested_by = auth.uid() order by created_at desc;
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

CREATE OR REPLACE FUNCTION public.get_ticket_categories()
 RETURNS SETOF public.ticket_categories
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from ticket_categories where tenant_id = get_my_tenant_id() order by name;
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

  v_delegator_tenant := get_my_tenant_id();
  IF v_delegator_tenant IS NULL THEN
    RAISE EXCEPTION 'delegator profile not found or company access is suspended';
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

CREATE OR REPLACE FUNCTION public.grant_hr_team_member(p_user_id uuid, p_role text DEFAULT 'member'::text)
 RETURNS public.hr_team_members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.hr_team_members%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage the HR team';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into hr_team_members (tenant_id, user_id, role)
  values (get_my_tenant_id(), p_user_id, p_role)
  on conflict (tenant_id, user_id) do update set role = excluded.role
  returning * into v_row;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.grant_payroll_approver(p_user_id uuid)
 RETURNS public.payroll_approvers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into payroll_approvers (tenant_id, user_id, role, is_active)
  values (get_my_tenant_id(), p_user_id, 'approver', true)
  on conflict (tenant_id, user_id) do update set is_active = true
  returning * into v_row;

  return v_row;
end;
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

CREATE OR REPLACE FUNCTION public.set_finance_role(p_user_id uuid, p_role text)
 RETURNS public.finance_team_members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.finance_team_members%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage finance access';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  delete from finance_team_members
  where user_id = p_user_id
    and tenant_id = get_my_tenant_id()
    and role != p_role;

  insert into finance_team_members (tenant_id, user_id, role)
  values (get_my_tenant_id(), p_user_id, p_role)
  on conflict (tenant_id, user_id, role) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from finance_team_members
    where user_id = p_user_id and tenant_id = get_my_tenant_id() and role = p_role;
  end if;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_payroll_approver_active(p_user_id uuid, p_is_active boolean)
 RETURNS public.payroll_approvers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;

  update payroll_approvers
  set is_active = p_is_active
  where user_id = p_user_id and tenant_id = get_my_tenant_id()
  returning * into v_row;

  if not found then
    raise exception 'payroll approver not found';
  end if;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_staff_module_role(p_user_id uuid, p_module text, p_role text)
 RETURNS public.staff_roles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.staff_roles%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage team access';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into staff_roles (tenant_id, user_id, module, role)
  values (get_my_tenant_id(), p_user_id, p_module, p_role)
  on conflict (tenant_id, user_id, module) do update set role = excluded.role
  returning * into v_row;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_tenant_status(p_tenant_id uuid, p_status text)
 RETURNS public.tenants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.tenants;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can change a company''s status';
  end if;

  if p_status not in ('active', 'suspended') then
    raise exception 'status must be active or suspended (pending is set automatically)';
  end if;

  update tenants
  set status = p_status
  where id = p_tenant_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'tenant not found';
  end if;

  return v_row;
end;
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



  create policy "app_users_select_tenant"
  on "public"."app_users"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) OR (id = ( SELECT auth.uid() AS uid))));



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



  create policy "approval_assignments_admin_delete"
  on "public"."approval_assignments"
  as permissive
  for delete
  to authenticated
using (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()));



  create policy "approval_assignments_admin_insert"
  on "public"."approval_assignments"
  as permissive
  for insert
  to authenticated
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()));



  create policy "approval_assignments_admin_select"
  on "public"."approval_assignments"
  as permissive
  for select
  to authenticated
using (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()));



  create policy "approval_assignments_admin_update"
  on "public"."approval_assignments"
  as permissive
  for update
  to authenticated
using (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()));



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



  create policy "bd_activities_write_delete"
  on "public"."bd_activities"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_activities_write_insert"
  on "public"."bd_activities"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_activities_write_update"
  on "public"."bd_activities"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_client_categories_select"
  on "public"."bd_client_categories"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_client_categories_write_delete"
  on "public"."bd_client_categories"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_client_categories_write_insert"
  on "public"."bd_client_categories"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_client_categories_write_update"
  on "public"."bd_client_categories"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_clients_select"
  on "public"."bd_clients"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_clients_write_delete"
  on "public"."bd_clients"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_clients_write_insert"
  on "public"."bd_clients"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_clients_write_update"
  on "public"."bd_clients"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_contacts_select"
  on "public"."bd_contacts"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_contacts_write_delete"
  on "public"."bd_contacts"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_contacts_write_insert"
  on "public"."bd_contacts"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_contacts_write_update"
  on "public"."bd_contacts"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_sources_select"
  on "public"."bd_lead_sources"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_sources_write_delete"
  on "public"."bd_lead_sources"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_sources_write_insert"
  on "public"."bd_lead_sources"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_sources_write_update"
  on "public"."bd_lead_sources"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_statuses_select"
  on "public"."bd_lead_statuses"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_statuses_write_delete"
  on "public"."bd_lead_statuses"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_statuses_write_insert"
  on "public"."bd_lead_statuses"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_lead_statuses_write_update"
  on "public"."bd_lead_statuses"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_leads_select"
  on "public"."bd_leads"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_leads_write_delete"
  on "public"."bd_leads"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_leads_write_insert"
  on "public"."bd_leads"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_leads_write_update"
  on "public"."bd_leads"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunities_select"
  on "public"."bd_opportunities"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunities_write_delete"
  on "public"."bd_opportunities"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunities_write_insert"
  on "public"."bd_opportunities"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunities_write_update"
  on "public"."bd_opportunities"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunity_stages_select"
  on "public"."bd_opportunity_stages"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunity_stages_write_delete"
  on "public"."bd_opportunity_stages"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunity_stages_write_insert"
  on "public"."bd_opportunity_stages"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_opportunity_stages_write_update"
  on "public"."bd_opportunity_stages"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_statuses_select"
  on "public"."bd_proposal_statuses"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_statuses_write_delete"
  on "public"."bd_proposal_statuses"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_statuses_write_insert"
  on "public"."bd_proposal_statuses"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_statuses_write_update"
  on "public"."bd_proposal_statuses"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_templates_select"
  on "public"."bd_proposal_templates"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_templates_write_delete"
  on "public"."bd_proposal_templates"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_templates_write_insert"
  on "public"."bd_proposal_templates"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_templates_write_update"
  on "public"."bd_proposal_templates"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_types_select"
  on "public"."bd_proposal_types"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_types_write_delete"
  on "public"."bd_proposal_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_types_write_insert"
  on "public"."bd_proposal_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposal_types_write_update"
  on "public"."bd_proposal_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposals_select"
  on "public"."bd_proposals"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposals_write_delete"
  on "public"."bd_proposals"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposals_write_insert"
  on "public"."bd_proposals"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_proposals_write_update"
  on "public"."bd_proposals"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tender_types_select"
  on "public"."bd_tender_types"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tender_types_write_delete"
  on "public"."bd_tender_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tender_types_write_insert"
  on "public"."bd_tender_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tender_types_write_update"
  on "public"."bd_tender_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tenders_select"
  on "public"."bd_tenders"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tenders_write_delete"
  on "public"."bd_tenders"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tenders_write_insert"
  on "public"."bd_tenders"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



  create policy "bd_tenders_write_update"
  on "public"."bd_tenders"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_business_dev()));



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
using (((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id())));



  create policy "departments_insert"
  on "public"."departments"
  as permissive
  for insert
  to public
with check (((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id())));



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
using (((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id())))
with check (((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id())));



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



  create policy "fuel_logs_write_delete"
  on "public"."fuel_logs"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "fuel_logs_write_insert"
  on "public"."fuel_logs"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "fuel_logs_write_update"
  on "public"."fuel_logs"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



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



  create policy "hr_appraisals_write_delete"
  on "public"."hr_appraisals"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_appraisals_write_insert"
  on "public"."hr_appraisals"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_appraisals_write_update"
  on "public"."hr_appraisals"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



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
using (((tenant_id = public.get_my_tenant_id()) AND (public.is_hr_team_member() OR (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_employee_compensation.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid))))))));



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
using (((EXISTS ( SELECT 1
   FROM public.hr_payroll_runs pr
  WHERE ((pr.id = hr_payroll_items.payroll_run_id) AND (pr.tenant_id = public.get_my_tenant_id())))) AND (public.is_hr_team_member() OR public.is_payroll_approver() OR (EXISTS ( SELECT 1
   FROM public.hr_employees e
  WHERE ((e.id = hr_payroll_items.employee_id) AND (e.user_id = ( SELECT auth.uid() AS uid))))))));



  create policy "hr_payroll_runs_select"
  on "public"."hr_payroll_runs"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.is_hr_team_member() OR public.is_payroll_approver())));



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



  create policy "hr_trainings_write_delete"
  on "public"."hr_trainings"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_trainings_write_insert"
  on "public"."hr_trainings"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "hr_trainings_write_update"
  on "public"."hr_trainings"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "impersonation_logs_select_platform_admin"
  on "public"."impersonation_logs"
  as permissive
  for select
  to public
using (public.is_platform_admin());



  create policy "invitations_insert"
  on "public"."invitations"
  as permissive
  for insert
  to public
with check ((public.is_platform_admin() OR ((role_bundle = 'member'::text) AND (tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.staff_roles
  WHERE ((staff_roles.user_id = ( SELECT auth.uid() AS uid)) AND (staff_roles.tenant_id = invitations.tenant_id) AND (staff_roles.role = 'admin'::text)))))));



  create policy "invitations_select"
  on "public"."invitations"
  as permissive
  for select
  to public
using ((public.is_platform_admin() OR ((tenant_id = public.get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM public.staff_roles
  WHERE ((staff_roles.user_id = ( SELECT auth.uid() AS uid)) AND (staff_roles.tenant_id = invitations.tenant_id) AND (staff_roles.role = 'admin'::text)))))));



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



  create policy "law_hearings_write_delete"
  on "public"."law_case_hearings"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_hearings_write_insert"
  on "public"."law_case_hearings"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_hearings_write_update"
  on "public"."law_case_hearings"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



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



  create policy "law_compliance_delete"
  on "public"."law_compliance_register"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



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



  create policy "law_filings_write_delete"
  on "public"."law_regulatory_filings"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_filings_write_insert"
  on "public"."law_regulatory_filings"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "law_filings_write_update"
  on "public"."law_regulatory_filings"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));



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



  create policy "machine_assignments_write_delete"
  on "public"."machine_assignments"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "machine_assignments_write_insert"
  on "public"."machine_assignments"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "machine_assignments_write_update"
  on "public"."machine_assignments"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "machine_types_select"
  on "public"."machine_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "machine_types_write_delete"
  on "public"."machine_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



  create policy "machine_types_write_insert"
  on "public"."machine_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



  create policy "machine_types_write_update"
  on "public"."machine_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



  create policy "machines_select"
  on "public"."machines"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "machines_write_delete"
  on "public"."machines"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "machines_write_insert"
  on "public"."machines"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "machines_write_update"
  on "public"."machines"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "maintenance_requests_select"
  on "public"."maintenance_requests"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "maintenance_requests_write_delete"
  on "public"."maintenance_requests"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "maintenance_requests_write_insert"
  on "public"."maintenance_requests"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "maintenance_requests_write_update"
  on "public"."maintenance_requests"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "maintenance_types_select"
  on "public"."maintenance_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "maintenance_types_write_delete"
  on "public"."maintenance_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



  create policy "maintenance_types_write_insert"
  on "public"."maintenance_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



  create policy "maintenance_types_write_update"
  on "public"."maintenance_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text])));



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



  create policy "operation_logs_write_delete"
  on "public"."operation_logs"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "operation_logs_write_insert"
  on "public"."operation_logs"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "operation_logs_write_update"
  on "public"."operation_logs"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));



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



  create policy "platform_settings_select_admin"
  on "public"."platform_settings"
  as permissive
  for select
  to public
using (public.is_platform_admin());



  create policy "platform_settings_update_admin"
  on "public"."platform_settings"
  as permissive
  for update
  to public
using (public.is_platform_admin())
with check (public.is_platform_admin());



  create policy "pmo_milestones_select"
  on "public"."pmo_milestones"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_milestones_write_delete"
  on "public"."pmo_milestones"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_milestones_write_insert"
  on "public"."pmo_milestones"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_milestones_write_update"
  on "public"."pmo_milestones"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_project_categories_select"
  on "public"."pmo_project_categories"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_project_categories_write_delete"
  on "public"."pmo_project_categories"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_project_categories_write_insert"
  on "public"."pmo_project_categories"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_project_categories_write_update"
  on "public"."pmo_project_categories"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_projects_select"
  on "public"."pmo_projects"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_projects_write_delete"
  on "public"."pmo_projects"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_projects_write_insert"
  on "public"."pmo_projects"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_projects_write_update"
  on "public"."pmo_projects"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_resource_allocations_select"
  on "public"."pmo_resource_allocations"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_resource_allocations_write_delete"
  on "public"."pmo_resource_allocations"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_resource_allocations_write_insert"
  on "public"."pmo_resource_allocations"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_resource_allocations_write_update"
  on "public"."pmo_resource_allocations"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "pmo_task_types_select"
  on "public"."pmo_task_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_task_types_write_delete"
  on "public"."pmo_task_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_task_types_write_insert"
  on "public"."pmo_task_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_task_types_write_update"
  on "public"."pmo_task_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('pmo'::text, ARRAY['admin'::text])));



  create policy "pmo_tasks_select"
  on "public"."pmo_tasks"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "pmo_tasks_write_delete"
  on "public"."pmo_tasks"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))));



  create policy "pmo_tasks_write_insert"
  on "public"."pmo_tasks"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))));



  create policy "pmo_tasks_write_update"
  on "public"."pmo_tasks"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))))
with check (((tenant_id = public.get_my_tenant_id()) AND (public.has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))));



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



  create policy "sustain_audits_write_delete"
  on "public"."sustainability_audits"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_audits_write_insert"
  on "public"."sustainability_audits"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_audits_write_update"
  on "public"."sustainability_audits"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_certs_select"
  on "public"."sustainability_certifications"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_certs_write_delete"
  on "public"."sustainability_certifications"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_certs_write_insert"
  on "public"."sustainability_certifications"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_certs_write_update"
  on "public"."sustainability_certifications"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_init_cat_select"
  on "public"."sustainability_initiative_categories"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_init_cat_write_delete"
  on "public"."sustainability_initiative_categories"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_init_cat_write_insert"
  on "public"."sustainability_initiative_categories"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_init_cat_write_update"
  on "public"."sustainability_initiative_categories"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_initiatives_select"
  on "public"."sustainability_initiatives"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_initiatives_write_delete"
  on "public"."sustainability_initiatives"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_initiatives_write_insert"
  on "public"."sustainability_initiatives"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_initiatives_write_update"
  on "public"."sustainability_initiatives"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_metric_types_select"
  on "public"."sustainability_metric_types"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_metric_types_write_delete"
  on "public"."sustainability_metric_types"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_metric_types_write_insert"
  on "public"."sustainability_metric_types"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_metric_types_write_update"
  on "public"."sustainability_metric_types"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text])));



  create policy "sustain_metrics_select"
  on "public"."sustainability_metrics"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));



  create policy "sustain_metrics_write_delete"
  on "public"."sustainability_metrics"
  as permissive
  for delete
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_metrics_write_insert"
  on "public"."sustainability_metrics"
  as permissive
  for insert
  to public
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "sustain_metrics_write_update"
  on "public"."sustainability_metrics"
  as permissive
  for update
  to public
using (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])))
with check (((tenant_id = public.get_my_tenant_id()) AND public.has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));



  create policy "tenant_modules_delete_platform_admin"
  on "public"."tenant_modules"
  as permissive
  for delete
  to public
using (public.is_platform_admin());



  create policy "tenant_modules_insert_platform_admin"
  on "public"."tenant_modules"
  as permissive
  for insert
  to public
with check (public.is_platform_admin());



  create policy "tenant_modules_select"
  on "public"."tenant_modules"
  as permissive
  for select
  to public
using (((tenant_id = public.get_my_tenant_id()) OR public.is_platform_admin()));



  create policy "tenants_select"
  on "public"."tenants"
  as permissive
  for select
  to public
using (((id = public.get_my_tenant_id()) OR public.is_platform_admin()));



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



  create policy "workflow_stages_admin_delete"
  on "public"."workflow_stages"
  as permissive
  for delete
  to authenticated
using (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()));



  create policy "workflow_stages_admin_insert"
  on "public"."workflow_stages"
  as permissive
  for insert
  to authenticated
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()));



  create policy "workflow_stages_admin_update"
  on "public"."workflow_stages"
  as permissive
  for update
  to authenticated
using (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()))
with check (((tenant_id = public.get_my_tenant_id()) AND public.is_tenant_admin()));



  create policy "workflow_stages_select_tenant"
  on "public"."workflow_stages"
  as permissive
  for select
  to public
using ((tenant_id = public.get_my_tenant_id()));


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



