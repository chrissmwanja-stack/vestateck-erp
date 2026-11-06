-- Re-assert security_invoker on 15 reporting views.
--
-- Production already has security_invoker=true on all of these (verified
-- 2026-11-06), so on production this migration changes nothing. It exists
-- for every database BUILT FROM THE MIGRATION FILES (CI replay, local
-- `supabase start`, a staging project, a disaster-recovery rebuild):
--
--   * the squashed baseline and a few later migrations create these views
--     WITH (security_invoker = true), but
--   * the grandfathered *_remote_schema.sql dumps (MIGRATION_POLICY rule 6)
--     recreate every one of them with `create or replace view ... as` and no
--     WITH clause, and CREATE OR REPLACE VIEW without a WITH clause resets the
--     view's options. None of the seven dumps contains security_invoker.
--
-- The result was that a replayed database had these views as SECURITY
-- DEFINER, running with the view owner's rights and ignoring the caller's RLS,
-- unlike production. test_production_invariants.sql caught it in CI.
--
-- ALTER VIEW ... SET is idempotent and does not touch the view definition.
-- Runs after the last dump (20260910133254), and none of these views is
-- recreated after that.

alter view if exists public.hr_employee_current_compensation set (security_invoker = true);
alter view if exists public.line_item_receipt_status         set (security_invoker = true);
alter view if exists public.petty_cash_float_balances        set (security_invoker = true);
alter view if exists public.v_advance_payments               set (security_invoker = true);
alter view if exists public.v_bank_statement_unmatched       set (security_invoker = true);
alter view if exists public.v_cash_bank_unmatched            set (security_invoker = true);
alter view if exists public.v_cost_transactions_inquiry      set (security_invoker = true);
alter view if exists public.v_durations                      set (security_invoker = true);
alter view if exists public.v_paye_nssf_remittance           set (security_invoker = true);
alter view if exists public.v_payment_plan                   set (security_invoker = true);
alter view if exists public.v_request_tracking               set (security_invoker = true);
alter view if exists public.v_trial_balance                  set (security_invoker = true);
alter view if exists public.v_vat_report                     set (security_invoker = true);
alter view if exists public.v_vendor_evaluation              set (security_invoker = true);
alter view if exists public.v_wht_report                     set (security_invoker = true);
