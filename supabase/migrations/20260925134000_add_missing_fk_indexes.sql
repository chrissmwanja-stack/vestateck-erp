-- Add missing FK indexes — item 6
-- Performance inspection found 21 unindexed foreign keys. This migration adds low-risk indexes
-- for the most critical ones mentioned in audit. Uses CONCURRENTLY-safe pattern via IF NOT EXISTS
-- (CONCURRENTLY not allowed in transaction, so we use regular CREATE INDEX IF NOT EXISTS which is
-- transactional and safe for CI shadow replay; production can later recreate CONCURRENTLY if needed)

-- bd_tender_submissions
create index if not exists bd_tender_submissions_tenant_id_idx on public.bd_tender_submissions (tenant_id);
create index if not exists bd_tender_submissions_submitted_by_idx on public.bd_tender_submissions (submitted_by);

-- gl_posting_rules
create index if not exists gl_posting_rules_gl_account_id_idx on public.gl_posting_rules (gl_account_id);

-- journal_entry_lines already has (tenant_id, gl_account_id) and (journal_entry_id) — add single gl_account_id for FK
create index if not exists journal_entry_lines_gl_account_id_idx on public.journal_entry_lines (gl_account_id);

-- law_contract_decisions
create index if not exists law_contract_decisions_tenant_id_idx on public.law_contract_decisions (tenant_id);
create index if not exists law_contract_decisions_decided_by_idx on public.law_contract_decisions (decided_by);

-- law_filing_events
create index if not exists law_filing_events_tenant_id_idx on public.law_filing_events (tenant_id);
create index if not exists law_filing_events_actor_id_idx on public.law_filing_events (actor_id);

-- pmo_cost_entries
create index if not exists pmo_cost_entries_tenant_id_idx on public.pmo_cost_entries (tenant_id);
create index if not exists pmo_cost_entries_created_by_idx on public.pmo_cost_entries (created_by);

-- pmo_time_entries
create index if not exists pmo_time_entries_tenant_id_idx on public.pmo_time_entries (tenant_id);
create index if not exists pmo_time_entries_task_id_idx on public.pmo_time_entries (task_id);

-- Additional from broader 21 list (inferred from common patterns)
create index if not exists bd_tenders_client_id_idx on public.bd_tenders (client_id);
create index if not exists bd_opportunities_client_id_idx on public.bd_opportunities (client_id);
create index if not exists law_cases_case_type_id_idx on public.law_cases (case_type_id);
create index if not exists pmo_projects_category_id_idx on public.pmo_projects (category_id);
create index if not exists maintenance_requests_machine_id_idx on public.maintenance_requests (machine_id);
create index if not exists fuel_logs_machine_id_idx on public.fuel_logs (machine_id);
create index if not exists hr_employees_department_id_idx on public.hr_employees (department_id);
create index if not exists approval_actions_request_id_idx on public.approval_actions (request_id);
create index if not exists approval_actions_invoice_request_id_idx on public.approval_actions (invoice_request_id) where invoice_request_id is not null;

comment on index public.bd_tender_submissions_tenant_id_idx is 'FK index for tenant isolation, added 20260925134000 per performance audit';
comment on index public.journal_entry_lines_gl_account_id_idx is 'FK index for gl_account_id, added for GL reporting performance';
