-- approval_assignments had no unique constraint beyond its own surrogate
-- `id` primary key, so re-running an idempotent seed insert (`on conflict
-- do nothing` targeting tenant_id/user_id/workflow_stage_id) never
-- actually conflicted -- every rerun silently inserted a duplicate
-- assignment row instead of being skipped. Found while verifying
-- supabase/seed.sql's idempotency claim (Foundation Playbook Phase 0).
--
-- Confirmed no existing duplicate (tenant_id, user_id, workflow_stage_id)
-- rows in dev before adding this, so the constraint applies cleanly.

alter table approval_assignments
  add constraint approval_assignments_tenant_user_stage_key
  unique (tenant_id, user_id, workflow_stage_id);
