-- Fix: tenant_read_only_guard was missing on the tables added by
-- 20261106170000..20261106220000 (ins_quotes, ins_policy_approvals,
-- ins_renewal_notices, ins_claim_documents, ins_insurer_statements,
-- ins_insurer_statement_lines). check_live_security_drift.sql caught it.
-- Idempotent; covers any other tenant_id table added since.
-- Rule for new tenant tables: end the migration with
--   select public.apply_tenant_read_only_guard();
select public.apply_tenant_read_only_guard();
