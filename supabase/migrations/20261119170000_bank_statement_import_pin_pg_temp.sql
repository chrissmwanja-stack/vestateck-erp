-- Fix: preview_bank_statement_import and import_bank_statement_batch (added by
-- 20261119090000_bank_statement_import_duplicates.sql) are SECURITY DEFINER with
-- `search_path to 'public'`. Every definer function in this repo pins
-- `public, pg_temp` (pg_temp last) so a caller cannot shadow objects through
-- the temp schema; test_acct_config_stabilisation.sql check (6) enforces it.
--
-- Fix forward (rule 9): 20261119090000 is not edited. ALTER FUNCTION ... SET
-- changes only the config and keeps the existing grants (authenticated and
-- service_role only), unlike CREATE OR REPLACE. Idempotent; safe to replay.
alter function public.preview_bank_statement_import(text, jsonb)
  set search_path to 'public', 'pg_temp';
alter function public.import_bank_statement_batch(text, jsonb, boolean)
  set search_path to 'public', 'pg_temp';
