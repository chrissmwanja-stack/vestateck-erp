-- Migration: fix_budget_controller_assignment
-- Depends on: 20260801120000_add_workflow_stage_active_flag
--
-- Background:
-- Stage 037 ("Cost Control Manager: Budget Approval") was an orphaned
-- stage in the approval workflow graph -- nothing routed into it, and
-- it routed nowhere. It is now redundant because the Budget Controller
-- stage (033) IS the Cost Control Manager role. Stage 037 already has
-- historical approval_actions rows, so it is deactivated rather than
-- deleted, preserving the audit trail.
--
-- Stage 033 ("Budget Controller") was incorrectly configured with
-- approver_role = 'Procurement & Logistics Chief' and assigned to the
-- Procurement Lead. It should be the Cost Control Manager, since the
-- Budget Controller in this workflow is the Cost Control Manager, and
-- the person entering the offer (Procurement) must not also approve it.

-- 1. Deactivate the orphaned/duplicate stage 037. Historical
--    approval_actions rows referencing this stage are left untouched.
UPDATE public.workflow_stages
SET
  name = 'Cost Control Manager: Budget Approval (deprecated)',
  is_active = false
WHERE id = '00000000-0000-0000-0000-000000000037';

-- 2. Remove the live assignment on the deprecated stage so it no longer
--    appears in anyone's approval queue.
DELETE FROM public.approval_assignments
WHERE workflow_stage_id = '00000000-0000-0000-0000-000000000037';

-- 3. Correct stage 033's approver role to Cost Control Manager.
UPDATE public.workflow_stages
SET approver_role = 'Cost Control Manager'
WHERE id = '00000000-0000-0000-0000-000000000033';

-- 4. Reassign stage 033 from the Procurement Lead to the Cost Control
--    Manager (same person already assigned to stage 031).
DELETE FROM public.approval_assignments
WHERE workflow_stage_id = '00000000-0000-0000-0000-000000000033'
  AND user_id = '6cb314bb-c39e-40e2-aca9-446e12a1795f'; -- Test Procurement Lead

INSERT INTO public.approval_assignments
  (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
SELECT
  id,                                       -- tenants.id (PK), maps to approval_assignments.tenant_id
  'b93bd287-c359-44cc-a7a6-2dd1578b06ee',  -- Test Cost Controller
  '00000000-0000-0000-0000-000000000033',  -- Budget Controller stage
  'global',
  5000000.00
FROM public.tenants
LIMIT 1;