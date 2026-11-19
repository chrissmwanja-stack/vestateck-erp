-- D4e follow-up: close anon EXECUTE on the four bank-adjustment RPCs.
--
-- 20261119064626_d4e_bank_adjustments.sql granted EXECUTE on these functions
-- to `authenticated` but never revoked it from PUBLIC or `anon`. Postgres (and
-- Supabase's default privileges) give EXECUTE to those roles on every new
-- function, so an unauthenticated caller could invoke them. The SECURITY
-- DEFINER exposure audit in foundation-checks flags this as ANON-EXPOSED.
--
-- Not an open hole: every body starts with get_my_tenant_id() /
-- effective_user_id() and raises 42501 unless is_finance_team_member('finance')
-- passes, so an anonymous call is refused inside the function. This closes the
-- grant layer as well (MIGRATION_POLICY.md: definer RPCs are not anon-callable).
--
-- Fix forward (rule 9): 20261119064626 is already applied and is not edited.
-- Idempotent; safe to replay. Signed-in finance users are unaffected because
-- `authenticated` keeps EXECUTE.

revoke all on function public.create_bank_adjustment(uuid, uuid, text, uuid)
  from public, anon;
revoke all on function public.request_bank_adjustment_reversal(uuid, text)
  from public, anon;
revoke all on function public.approve_bank_adjustment(uuid)
  from public, anon;
revoke all on function public.reject_bank_adjustment(uuid, text)
  from public, anon;

grant execute on function public.create_bank_adjustment(uuid, uuid, text, uuid)
  to authenticated;
grant execute on function public.request_bank_adjustment_reversal(uuid, text)
  to authenticated;
grant execute on function public.approve_bank_adjustment(uuid)
  to authenticated;
grant execute on function public.reject_bank_adjustment(uuid, text)
  to authenticated;