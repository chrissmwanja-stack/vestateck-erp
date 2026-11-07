-- Two small performance fixes from the 2026-11-07 advisor run on production
-- (xownbroirovedkmqyybc). Neither changes what any user can read or write.
--
-- 1. Duplicate indexes. Seven tables carry two identical btree indexes on the
--    same column: one named idx_<table>_<col> from the squashed baseline and one
--    named <table>_<col>_idx from 20260925134000_add_missing_fk_indexes.sql (also
--    re-created by 20261002060000 with IF NOT EXISTS). None backs a constraint.
--    The baseline-named copy is dropped; the <table>_<col>_idx name is kept
--    because the later migrations reference it, so re-running them is a no-op.
--
-- 2. regulatory_approval_assignments_select called auth.uid() directly, which
--    Postgres re-evaluates for every row. Wrapping it as (select auth.uid()) lets
--    the planner evaluate it once per query. The rest of the predicate is unchanged.
--
-- Idempotent: safe to run twice.

-- 1. duplicate indexes ------------------------------------------------------
drop index if exists public.idx_approval_actions_request;
drop index if exists public.idx_bd_opportunities_client;
drop index if exists public.idx_bd_tenders_client;
drop index if exists public.idx_fuel_logs_machine;
drop index if exists public.idx_hr_employees_department;
drop index if exists public.idx_maintenance_requests_machine;
drop index if exists public.idx_pmo_projects_category;

-- Make sure the kept copy exists even on a database that never had it.
create index if not exists approval_actions_request_id_idx on public.approval_actions (request_id);
create index if not exists bd_opportunities_client_id_idx on public.bd_opportunities (client_id);
create index if not exists bd_tenders_client_id_idx on public.bd_tenders (client_id);
create index if not exists fuel_logs_machine_id_idx on public.fuel_logs (machine_id);
create index if not exists hr_employees_department_id_idx on public.hr_employees (department_id);
create index if not exists maintenance_requests_machine_id_idx on public.maintenance_requests (machine_id);
create index if not exists pmo_projects_category_id_idx on public.pmo_projects (category_id);

-- 2. regulatory_approval_assignments_select ---------------------------------
drop policy if exists regulatory_approval_assignments_select on public.regulatory_approval_assignments;
create policy regulatory_approval_assignments_select on public.regulatory_approval_assignments
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or user_id = (select auth.uid()) or is_finance_team_member(null::text)
         or has_module_role('insurance', array['admin', 'manager']))
  );