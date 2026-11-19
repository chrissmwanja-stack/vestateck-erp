-- Fix: approve_bank_adjustment (20261119064626_d4e_bank_adjustments.sql) posts
-- journal entries with source_type 'bank_adjustment' (approval) and
-- 'bank_adjustment_reversal' (reversal), but journal_entries_source_type_check
-- never listed them, so every approval was rejected with
--   new row for relation "journal_entries" violates check constraint
--   "journal_entries_source_type_check"
-- Found by test_fin_bank_adjustments.sql, the first time it ran in CI.
--
-- The constraint has no incremental form, so the full list is repeated
-- verbatim from 20261117260000_ins_client_broker_fees.sql (the newest list)
-- with the two D4e values appended; a partial list would silently break every
-- other module. Fix forward (rule 9): 20261119064626 is not edited.
-- Idempotent; safe to replay. Existing rows already satisfy the wider list.
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries
  add constraint journal_entries_source_type_check check (
    source_type = any (array[
      'supplier_invoice'::text, 'receivable_invoice'::text,
      'cash_bank_transaction'::text, 'opening_balance'::text, 'manual'::text,
      'payroll_run'::text, 'machine_fuel_log'::text,
      'machine_maintenance_request'::text, 'fin_settlement'::text,
      'fin_settlement_void'::text, 'fin_credit_note'::text,
      'fin_credit_note_void'::text, 'ins_policy_bind'::text,
      'ins_commission_recognition'::text, 'ins_commission_recognition_reversal'::text,
      'ins_commission_transfer'::text, 'ins_commission_transfer_void'::text,
      'ins_claim_accrual'::text, 'ins_policy_cancellation'::text,
      'ins_cancellation_cash'::text, 'fx_revaluation'::text,
      'fx_revaluation_void'::text, 'ins_policy_endorsement'::text,
      'ins_import_opening'::text, 'ins_agent_commission_accrual'::text,
      'ins_agent_commission_payment'::text, 'ins_agent_commission_reversal'::text,
      'ins_wht_remittance'::text, 'ins_fee_withholding'::text, 'bank_adjustment'::text,
      'bank_adjustment_reversal'::text
    ]));
