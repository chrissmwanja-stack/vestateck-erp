-- These six workflow_stages rows (organic UUIDs) are a leftover parallel
-- chain from before the multi-offer migration seeded a new chain with
-- fixed UUIDs (00000000-...-030 through 037). Verified orphaned:
--   - 0 rows in approval_assignments referencing any of them
--   - 0 rows in approval_delegations referencing any of them
--   - 0 rows in approval_actions referencing any of them
--   - 0 requests (open or otherwise) currently pointing at any of them
-- Notably, the old "Budget Controller" row here still has
-- requires_offer_selection = false with threshold_amount set, which is
-- exactly the landmine that would raise 'no offer on file to evaluate
-- threshold' if a request were ever routed onto it. Removing it removes
-- that footgun along with the rest of the dead chain.
delete from workflow_stages
where id in (
  '7e90643d-bcf9-4c84-bc07-a5f0aff302e4', -- Budget Controller (old)
  '2528f327-fa41-4ed0-9785-2757e52d2632', -- Cost Control Engineer (old)
  'dab3c197-71cc-43d9-9594-be5829463766', -- Cost Control Manager (old)
  '6675dd6a-f06e-4a77-8a42-fd175177a7bc', -- Finance (old)
  '2a3ce0b0-1ba6-479e-aa0b-696306ddcddb', -- General Manager (old)
  'c786e5c2-c64f-49e5-9cd5-80d278dd7f9a'  -- Project Manager (old)
);
