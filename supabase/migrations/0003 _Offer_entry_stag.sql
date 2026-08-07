-- Migration 0003 — Offer-entry stage flag
-- Matches existing 0001_init_core_schema.sql / 0002_approval_queue_rpc.sql convention
-- Required so ApprovalQueue checks stage config (requires_offer_entry) instead of stage name

-- 1. Add column
ALTER TABLE public.workflow_stages
ADD COLUMN IF NOT EXISTS requires_offer_entry boolean NOT NULL DEFAULT false;

-- 2. Backfill this tenant's Offer Entry stage (id from DB: 32 / 000...032)
--    Use the stage's actual id rather than hard-coding if you prefer dynamic:
UPDATE public.workflow_stages
SET requires_offer_entry = true
WHERE id = '00000000-0000-0000-0000-000000000032';

-- 3. If get_my_approval_queue RPC needs updating (as noted in session summary),
--    ensure the current_stage jsonb/select includes requires_offer_entry.
--    Example update for the RPC definition (run in SQL Editor after adjusting):
--    UPDATE public.get_my_approval_queue ... (or recreate function with new select)

-- Note: also add to packages/shared/src/types.ts:
--   WorkflowStage interface: requires_offer_entry: boolean
--   QueuedRequest.current_stage Pick: include "requires_offer_entry"
