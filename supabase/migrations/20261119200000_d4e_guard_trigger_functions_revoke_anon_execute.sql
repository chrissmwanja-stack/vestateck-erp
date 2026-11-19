-- D4e follow-up: close anon/PUBLIC EXECUTE on the two bank-adjustment trigger
-- guard functions.
--
-- bank_adjustments_mutation_guard() and bank_reconciliation_adjustment_guard()
-- (20261119064626, the latter replaced by 20261119190000) are SECURITY DEFINER
-- trigger functions. Postgres and Supabase's default privileges give EXECUTE on
-- every new function to PUBLIC, and therefore to anon, so
-- test_production_invariants.sql (section 3) rejects them as
-- "SECURITY DEFINER and executable by anon".
-- 20261119150000 revoked the four bank-adjustment RPCs but not these two.
--
-- Not an open hole: a function returning `trigger` cannot be called directly
-- ("trigger functions can only be called as triggers"). This closes the grant
-- layer anyway (MIGRATION_POLICY.md: definer functions are not anon-callable).
--
-- Safe for the triggers: EXECUTE on a trigger function is checked when the
-- trigger is created (by the migration owner), not each time it fires, so
-- revoking from PUBLIC/anon/authenticated does not affect writes by signed-in
-- users. No role needs to call these functions directly, so authenticated is
-- not re-granted.
--
-- Fix forward (rule 9): 20261119064626 and 20261119190000 are not edited.
-- Idempotent; safe to replay.

revoke all on function public.bank_adjustments_mutation_guard()
  from public, anon, authenticated;
revoke all on function public.bank_reconciliation_adjustment_guard()
  from public, anon, authenticated;
