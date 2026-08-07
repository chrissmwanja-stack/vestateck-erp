-- Migration: add_workflow_stage_active_flag
-- Adds a soft-deactivation flag to workflow_stages so dead/duplicate
-- stages can be retired without breaking FK references from historical
-- approval_actions rows.

ALTER TABLE public.workflow_stages
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;