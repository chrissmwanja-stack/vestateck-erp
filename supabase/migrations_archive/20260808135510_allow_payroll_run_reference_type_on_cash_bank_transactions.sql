-- Allow the Finance-side PayrollDisbursement screen to record payroll
-- disbursements through the normal cash_bank_transactions path.
ALTER TABLE cash_bank_transactions
  DROP CONSTRAINT cash_bank_transactions_reference_type_check;

ALTER TABLE cash_bank_transactions
  ADD CONSTRAINT cash_bank_transactions_reference_type_check
  CHECK (reference_type = ANY (ARRAY['supplier_invoice'::text, 'expenditure_slip'::text, 'receivable_invoice'::text, 'payroll_run'::text]));
