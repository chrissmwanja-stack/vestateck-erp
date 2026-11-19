-- Fix: tenant_read_only_guard was missing on the tables added by
-- 20261119064626_d4e_bank_adjustments.sql (bank_adjustments,
-- bank_adjustment_events, bank_adjustment_usual_accounts).
-- check_live_security_drift.sql caught it in db-shadow-replay.
--
-- Fix forward (rule 9): 20261119064626 is already applied and is not edited.
-- Same remedy as 20261109110000. Idempotent; covers any other tenant_id table
-- added since. Safe to apply live: it only attaches the trigger where missing.
select public.apply_tenant_read_only_guard();
