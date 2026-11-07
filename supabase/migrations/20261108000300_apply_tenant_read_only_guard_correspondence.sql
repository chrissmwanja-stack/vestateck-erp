-- Fix: tenant_read_only_guard was missing on the tables added by
-- 20261107235906_correspondence.sql (ins_claim_correspondence,
-- ins_endorsement_notes). check_live_security_drift.sql caught it.
-- Idempotent; covers any other tenant_id table added since.
-- Rule for new tenant tables: end the migration with
--   select public.apply_tenant_read_only_guard();
select public.apply_tenant_read_only_guard();