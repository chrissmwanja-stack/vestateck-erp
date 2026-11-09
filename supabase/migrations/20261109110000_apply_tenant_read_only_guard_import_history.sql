-- Fix: tenant_read_only_guard was missing on the history tables added by
-- 20261108030000_ins_import_opening_position.sql (ins_import_receipts,
-- ins_import_remittances). check_live_security_drift.sql caught it.
-- Idempotent; covers any other tenant_id table added since.
select public.apply_tenant_read_only_guard();