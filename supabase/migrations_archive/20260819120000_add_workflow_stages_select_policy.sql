-- workflow_stages has had RLS enabled since 0001_init_core_schema.sql but has
-- never had a single policy defined on it in any migration since (verified
-- across all six remote_schema.sql dumps and every hand-written migration).
-- With RLS on and zero policies, Postgres default-denies all access to the
-- anon/authenticated roles PostgREST uses -- this isn't "wide open," it's
-- "nobody can read it at all" through supabase-js.
--
-- That's a live bug, not just a theoretical gap: three screens query this
-- table directly rather than through a SECURITY DEFINER RPC --
--   - DelegationManager.tsx  (.from("workflow_stages")... and an embedded
--     approval_assignments -> workflow_stages(id, name) select)
--   - MyRequests.tsx         ("current_stage:workflow_stages!...(name)")
--   - InvoiceSubmissionForm.tsx (embedded workflow_stages(name) select)
-- All three silently get null/empty for the stage name today. CompanyDetail.tsx
-- avoids the problem by calling get_tenant_workflow_stages() (SECURITY
-- DEFINER, bypasses RLS) instead -- that's the pattern this fixes for the
-- direct-query call sites.
--
-- workflow_stages is non-sensitive, tenant-scoped lookup/config data (stage
-- names, sequence order, approver role, threshold amounts) -- every
-- authenticated member of a tenant is expected to be able to see the stages
-- of their own tenant's workflow, so a plain tenant_id scope (matching the
-- convention used by sla_policies_select, priority_levels_select,
-- ticket_categories_select, etc.) is the right level, no extra role check
-- needed.

create policy workflow_stages_select on public.workflow_stages
  for select using (tenant_id = public.get_my_tenant_id());