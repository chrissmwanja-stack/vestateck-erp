-- ============================================================================
-- D4e surface hardening: narrow two grants that are wider than the design.
--
-- Correcting the record first: `anon` holds NOTHING on the D4e tables.
-- 20261112090000 revoked all table privileges from anon and set the default
-- privileges to match, so the three tables created by 20261119064626
-- (bank_adjustments, bank_adjustment_events, bank_adjustment_usual_accounts)
-- were born with no anon access. Verified on the live project: relacl lists
-- only authenticated, postgres and service_role.
--
-- What is wider than the design:
--
-- 1. authenticated holds INSERT/UPDATE/DELETE on all three tables with no
--    write policy anywhere, which makes "RPC-only writes" (section 10 of
--    20261119064626) a comment rather than a fact. The consequence is not a
--    leak today, it is a probe: a permission error tells an attacker whether an
--    RLS write policy has appeared, and a future policy written for one table
--    silently grants writes that were never reviewed. All writes already go
--    through create_/approve_/reject_/request_bank_adjustment_reversal (definer
--    functions), and the usual-account list has add/remove RPCs since
--    20261119210000, so no client path needs these.
--
-- 2. authenticated holds MAINTAIN on all three. MAINTAIN (PostgreSQL 17) covers
--    VACUUM, ANALYZE, CLUSTER, REINDEX, REFRESH MATERIALIZED VIEW and LOCK
--    TABLE. No client path issues any of them. 20261112090000 could not revoke
--    it by name (it would not replay on older servers); this repo now requires
--    PostgreSQL 17 (the live project runs 17.6), so the revoke is safe here and
--    is guarded so a replay on an older server is a no-op rather than an error.
--
-- Deliberately unchanged: SELECT stays on all three (the panel and the register
-- read the tables; the RLS policies are SELECT-only and tenant/finance scoped),
-- and the three reporting views stay readable because the screens that read
-- them run as security_invoker and therefore need the caller's SELECT.
--
-- Idempotent. Only REVOKEs: no table, column or row is touched. If a screen
-- turns out to need a write this misses, the fix is a narrow GRANT in a new
-- migration, not a rollback of this one.
-- ============================================================================

revoke insert, update, delete on table public.bank_adjustments               from authenticated;
revoke insert, update, delete on table public.bank_adjustment_events         from authenticated;
revoke insert, update, delete on table public.bank_adjustment_usual_accounts from authenticated;

do $$
begin
  -- MAINTAIN exists from PostgreSQL 17. On anything older this raises
  -- undefined_object, which is caught, so the file replays everywhere.
  begin
    execute 'revoke maintain on table public.bank_adjustments from authenticated';
    execute 'revoke maintain on table public.bank_adjustment_events from authenticated';
    execute 'revoke maintain on table public.bank_adjustment_usual_accounts from authenticated';
  exception
    when undefined_object then
      raise notice 'MAINTAIN not known to this server; skipped (needs PostgreSQL 17)';
  end;
end $$;

-- Keep the intent visible on the objects themselves.
comment on table public.bank_adjustments is
  'Bank adjustments for statement lines with no book entry (D4e). Writes are RPC-only: create_bank_adjustment, approve_bank_adjustment, reject_bank_adjustment, request_bank_adjustment_reversal. authenticated holds SELECT only, since 20261119230000.';
