-- Fix: tenant_read_only_guard was missing on the insurance brokerage tables.
--
-- 20261010100000_insurance_brokerage_core created ins_insurers, ins_clients,
-- ins_product_lines, ins_policies, ins_claims and ins_claim_events with RLS but
-- did not attach the read-only guard, so a read-only (suspended or expired)
-- tenant could still write to them. check_live_security_drift.sql caught it.
--
-- apply_tenant_read_only_guard() attaches the guard to every public table with a
-- tenant_id column (apart from its built-in exclusions) and is idempotent, so
-- this also covers any table added since the last run.
--
-- Left as a separate migration, not an edit of 20261010100000, because that
-- migration is already applied. Its version sorts after 20261010100000 so a
-- fresh reset creates the tables first and guards them second.
--
-- Rule for new tenant tables: end the migration with
--   select public.apply_tenant_read_only_guard();

select public.apply_tenant_read_only_guard();
