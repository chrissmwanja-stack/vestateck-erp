-- 1. One offer per request, enforced at the DB level regardless of
--    which path writes to request_offers (the now-deleted submit-offer
--    edge function was the only place this was enforced before).
ALTER TABLE public.request_offers
  ADD CONSTRAINT request_offers_one_per_request UNIQUE (request_id);

-- 2. approval_delegations_update_own previously allowed a delegator to
--    change ANY field via a direct client update -- including reviving
--    a revoked delegation back to 'active', extending ends_at, or
--    reassigning workflow_stage_id. Replace it with a policy that only
--    permits the single legitimate client-side mutation: flipping an
--    active delegation to revoked. Everything else (grant, with all its
--    validation) stays behind resolve-delegation.
DROP POLICY IF EXISTS approval_delegations_update_own ON public.approval_delegations;

CREATE POLICY approval_delegations_revoke_own
  ON public.approval_delegations
  FOR UPDATE
  USING (delegator_user_id = auth.uid() AND status = 'active')
  WITH CHECK (
    delegator_user_id = auth.uid()
    AND status = 'revoked'
  );
