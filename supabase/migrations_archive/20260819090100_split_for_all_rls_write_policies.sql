-- Split 38 FOR ALL "_write" policies into INSERT/UPDATE/DELETE only.
-- The _select policies are untouched. In every case here, the write
-- policy's implicit SELECT grant (from FOR ALL) was identical to or a
-- strict subset of the paired _select policy, so this is a pure
-- performance fix (removes a redundant permissive-policy evaluation on
-- every SELECT) with zero behavior change. Also brings these policies
-- into compliance with MIGRATION_POLICY.md rule 4.

-- bd_activities
DROP POLICY IF EXISTS bd_activities_write ON public.bd_activities;
CREATE POLICY bd_activities_write_insert ON public.bd_activities FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_activities_write_update ON public.bd_activities FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_activities_write_delete ON public.bd_activities FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_client_categories
DROP POLICY IF EXISTS bd_client_categories_write ON public.bd_client_categories;
CREATE POLICY bd_client_categories_write_insert ON public.bd_client_categories FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_client_categories_write_update ON public.bd_client_categories FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_client_categories_write_delete ON public.bd_client_categories FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_clients
DROP POLICY IF EXISTS bd_clients_write ON public.bd_clients;
CREATE POLICY bd_clients_write_insert ON public.bd_clients FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_clients_write_update ON public.bd_clients FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_clients_write_delete ON public.bd_clients FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_contacts
DROP POLICY IF EXISTS bd_contacts_write ON public.bd_contacts;
CREATE POLICY bd_contacts_write_insert ON public.bd_contacts FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_contacts_write_update ON public.bd_contacts FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_contacts_write_delete ON public.bd_contacts FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_lead_sources
DROP POLICY IF EXISTS bd_lead_sources_write ON public.bd_lead_sources;
CREATE POLICY bd_lead_sources_write_insert ON public.bd_lead_sources FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_lead_sources_write_update ON public.bd_lead_sources FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_lead_sources_write_delete ON public.bd_lead_sources FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_lead_statuses
DROP POLICY IF EXISTS bd_lead_statuses_write ON public.bd_lead_statuses;
CREATE POLICY bd_lead_statuses_write_insert ON public.bd_lead_statuses FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_lead_statuses_write_update ON public.bd_lead_statuses FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_lead_statuses_write_delete ON public.bd_lead_statuses FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_leads
DROP POLICY IF EXISTS bd_leads_write ON public.bd_leads;
CREATE POLICY bd_leads_write_insert ON public.bd_leads FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_leads_write_update ON public.bd_leads FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_leads_write_delete ON public.bd_leads FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_opportunities
DROP POLICY IF EXISTS bd_opportunities_write ON public.bd_opportunities;
CREATE POLICY bd_opportunities_write_insert ON public.bd_opportunities FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_opportunities_write_update ON public.bd_opportunities FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_opportunities_write_delete ON public.bd_opportunities FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_opportunity_stages
DROP POLICY IF EXISTS bd_opportunity_stages_write ON public.bd_opportunity_stages;
CREATE POLICY bd_opportunity_stages_write_insert ON public.bd_opportunity_stages FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_opportunity_stages_write_update ON public.bd_opportunity_stages FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_opportunity_stages_write_delete ON public.bd_opportunity_stages FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_proposal_statuses
DROP POLICY IF EXISTS bd_proposal_statuses_write ON public.bd_proposal_statuses;
CREATE POLICY bd_proposal_statuses_write_insert ON public.bd_proposal_statuses FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposal_statuses_write_update ON public.bd_proposal_statuses FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposal_statuses_write_delete ON public.bd_proposal_statuses FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_proposal_templates
DROP POLICY IF EXISTS bd_proposal_templates_write ON public.bd_proposal_templates;
CREATE POLICY bd_proposal_templates_write_insert ON public.bd_proposal_templates FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposal_templates_write_update ON public.bd_proposal_templates FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposal_templates_write_delete ON public.bd_proposal_templates FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_proposal_types
DROP POLICY IF EXISTS bd_proposal_types_write ON public.bd_proposal_types;
CREATE POLICY bd_proposal_types_write_insert ON public.bd_proposal_types FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposal_types_write_update ON public.bd_proposal_types FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposal_types_write_delete ON public.bd_proposal_types FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_proposals
DROP POLICY IF EXISTS bd_proposals_write ON public.bd_proposals;
CREATE POLICY bd_proposals_write_insert ON public.bd_proposals FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposals_write_update ON public.bd_proposals FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_proposals_write_delete ON public.bd_proposals FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_tender_types
DROP POLICY IF EXISTS bd_tender_types_write ON public.bd_tender_types;
CREATE POLICY bd_tender_types_write_insert ON public.bd_tender_types FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_tender_types_write_update ON public.bd_tender_types FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_tender_types_write_delete ON public.bd_tender_types FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- bd_tenders
DROP POLICY IF EXISTS bd_tenders_write ON public.bd_tenders;
CREATE POLICY bd_tenders_write_insert ON public.bd_tenders FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_tenders_write_update ON public.bd_tenders FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev())) WITH CHECK (((tenant_id = get_my_tenant_id()) AND is_business_dev()));
CREATE POLICY bd_tenders_write_delete ON public.bd_tenders FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND is_business_dev()));

-- fuel_logs
DROP POLICY IF EXISTS fuel_logs_write ON public.fuel_logs;
CREATE POLICY fuel_logs_write_insert ON public.fuel_logs FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY fuel_logs_write_update ON public.fuel_logs FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY fuel_logs_write_delete ON public.fuel_logs FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));

-- hr_appraisals
DROP POLICY IF EXISTS hr_appraisals_write ON public.hr_appraisals;
CREATE POLICY hr_appraisals_write_insert ON public.hr_appraisals FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY hr_appraisals_write_update ON public.hr_appraisals FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY hr_appraisals_write_delete ON public.hr_appraisals FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));

-- hr_trainings
DROP POLICY IF EXISTS hr_trainings_write ON public.hr_trainings;
CREATE POLICY hr_trainings_write_insert ON public.hr_trainings FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY hr_trainings_write_update ON public.hr_trainings FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY hr_trainings_write_delete ON public.hr_trainings FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])));

-- law_case_hearings
DROP POLICY IF EXISTS law_hearings_write ON public.law_case_hearings;
CREATE POLICY law_hearings_write_insert ON public.law_case_hearings FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY law_hearings_write_update ON public.law_case_hearings FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY law_hearings_write_delete ON public.law_case_hearings FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));

-- law_regulatory_filings
DROP POLICY IF EXISTS law_filings_write ON public.law_regulatory_filings;
CREATE POLICY law_filings_write_insert ON public.law_regulatory_filings FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY law_filings_write_update ON public.law_regulatory_filings FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY law_filings_write_delete ON public.law_regulatory_filings FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text])));

-- machine_assignments
DROP POLICY IF EXISTS machine_assignments_write ON public.machine_assignments;
CREATE POLICY machine_assignments_write_insert ON public.machine_assignments FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY machine_assignments_write_update ON public.machine_assignments FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY machine_assignments_write_delete ON public.machine_assignments FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));

-- machine_types
DROP POLICY IF EXISTS machine_types_write ON public.machine_types;
CREATE POLICY machine_types_write_insert ON public.machine_types FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text])));
CREATE POLICY machine_types_write_update ON public.machine_types FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text])));
CREATE POLICY machine_types_write_delete ON public.machine_types FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text])));

-- machines
DROP POLICY IF EXISTS machines_write ON public.machines;
CREATE POLICY machines_write_insert ON public.machines FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY machines_write_update ON public.machines FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY machines_write_delete ON public.machines FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));

-- maintenance_requests
DROP POLICY IF EXISTS maintenance_requests_write ON public.maintenance_requests;
CREATE POLICY maintenance_requests_write_insert ON public.maintenance_requests FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY maintenance_requests_write_update ON public.maintenance_requests FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY maintenance_requests_write_delete ON public.maintenance_requests FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));

-- maintenance_types
DROP POLICY IF EXISTS maintenance_types_write ON public.maintenance_types;
CREATE POLICY maintenance_types_write_insert ON public.maintenance_types FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text])));
CREATE POLICY maintenance_types_write_update ON public.maintenance_types FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text])));
CREATE POLICY maintenance_types_write_delete ON public.maintenance_types FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text])));

-- operation_logs
DROP POLICY IF EXISTS operation_logs_write ON public.operation_logs;
CREATE POLICY operation_logs_write_insert ON public.operation_logs FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY operation_logs_write_update ON public.operation_logs FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY operation_logs_write_delete ON public.operation_logs FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('machine_operation'::text, ARRAY['admin'::text, 'manager'::text])));

-- pmo_milestones
DROP POLICY IF EXISTS pmo_milestones_write ON public.pmo_milestones;
CREATE POLICY pmo_milestones_write_insert ON public.pmo_milestones FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY pmo_milestones_write_update ON public.pmo_milestones FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY pmo_milestones_write_delete ON public.pmo_milestones FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));

-- pmo_project_categories
DROP POLICY IF EXISTS pmo_project_categories_write ON public.pmo_project_categories;
CREATE POLICY pmo_project_categories_write_insert ON public.pmo_project_categories FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text])));
CREATE POLICY pmo_project_categories_write_update ON public.pmo_project_categories FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text])));
CREATE POLICY pmo_project_categories_write_delete ON public.pmo_project_categories FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text])));

-- pmo_projects
DROP POLICY IF EXISTS pmo_projects_write ON public.pmo_projects;
CREATE POLICY pmo_projects_write_insert ON public.pmo_projects FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY pmo_projects_write_update ON public.pmo_projects FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY pmo_projects_write_delete ON public.pmo_projects FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));

-- pmo_resource_allocations
DROP POLICY IF EXISTS pmo_resource_allocations_write ON public.pmo_resource_allocations;
CREATE POLICY pmo_resource_allocations_write_insert ON public.pmo_resource_allocations FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY pmo_resource_allocations_write_update ON public.pmo_resource_allocations FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY pmo_resource_allocations_write_delete ON public.pmo_resource_allocations FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text])));

-- pmo_task_types
DROP POLICY IF EXISTS pmo_task_types_write ON public.pmo_task_types;
CREATE POLICY pmo_task_types_write_insert ON public.pmo_task_types FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text])));
CREATE POLICY pmo_task_types_write_update ON public.pmo_task_types FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text])));
CREATE POLICY pmo_task_types_write_delete ON public.pmo_task_types FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('pmo'::text, ARRAY['admin'::text])));

-- pmo_tasks
DROP POLICY IF EXISTS pmo_tasks_write ON public.pmo_tasks;
CREATE POLICY pmo_tasks_write_insert ON public.pmo_tasks FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND (has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))));
CREATE POLICY pmo_tasks_write_update ON public.pmo_tasks FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND (has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid))))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND (has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))));
CREATE POLICY pmo_tasks_write_delete ON public.pmo_tasks FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND (has_module_role('pmo'::text, ARRAY['admin'::text, 'manager'::text]) OR (assignee_id = ( SELECT auth.uid() AS uid)))));

-- sustainability_audits
DROP POLICY IF EXISTS sustain_audits_write ON public.sustainability_audits;
CREATE POLICY sustain_audits_write_insert ON public.sustainability_audits FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_audits_write_update ON public.sustainability_audits FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_audits_write_delete ON public.sustainability_audits FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));

-- sustainability_certifications
DROP POLICY IF EXISTS sustain_certs_write ON public.sustainability_certifications;
CREATE POLICY sustain_certs_write_insert ON public.sustainability_certifications FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_certs_write_update ON public.sustainability_certifications FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_certs_write_delete ON public.sustainability_certifications FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));

-- sustainability_initiative_categories
DROP POLICY IF EXISTS sustain_init_cat_write ON public.sustainability_initiative_categories;
CREATE POLICY sustain_init_cat_write_insert ON public.sustainability_initiative_categories FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text])));
CREATE POLICY sustain_init_cat_write_update ON public.sustainability_initiative_categories FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text])));
CREATE POLICY sustain_init_cat_write_delete ON public.sustainability_initiative_categories FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text])));

-- sustainability_initiatives
DROP POLICY IF EXISTS sustain_initiatives_write ON public.sustainability_initiatives;
CREATE POLICY sustain_initiatives_write_insert ON public.sustainability_initiatives FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_initiatives_write_update ON public.sustainability_initiatives FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_initiatives_write_delete ON public.sustainability_initiatives FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));

-- sustainability_metric_types
DROP POLICY IF EXISTS sustain_metric_types_write ON public.sustainability_metric_types;
CREATE POLICY sustain_metric_types_write_insert ON public.sustainability_metric_types FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text])));
CREATE POLICY sustain_metric_types_write_update ON public.sustainability_metric_types FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text])));
CREATE POLICY sustain_metric_types_write_delete ON public.sustainability_metric_types FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text])));

-- sustainability_metrics
DROP POLICY IF EXISTS sustain_metrics_write ON public.sustainability_metrics;
CREATE POLICY sustain_metrics_write_insert ON public.sustainability_metrics FOR INSERT WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_metrics_write_update ON public.sustainability_metrics FOR UPDATE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));
CREATE POLICY sustain_metrics_write_delete ON public.sustainability_metrics FOR DELETE USING (((tenant_id = get_my_tenant_id()) AND has_module_role('sustainability'::text, ARRAY['admin'::text, 'manager'::text])));