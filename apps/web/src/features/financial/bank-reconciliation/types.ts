export interface StatementLine {
  id: string;
  statement_date: string;
  description: string | null;
  reference: string | null;
  amount: number;
  currency: string;
}

export interface CashBankTxn {
  id: string;
  transaction_date: string;
  transaction_type: 'payment' | 'receipt';
  amount: number;
  currency: string;
  description: string | null;
  reference_type: string;
}

export interface SettlementRow {
  id: string;
  settlement_no: string | null;
  direction: 'in' | 'out';
  amount: number;
  currency: string;
  settlement_date: string;
  reference: string | null;
  notes: string | null;
  // True when the settlement records an allocation only: the bank movement and
  // its GL entry belong to a cash/bank transaction (procurement payments).
  subledger_only: boolean;
  funding_transaction_id: string | null;
}

// One side of a posted commission transfer that has no reconciliation row yet.
// A transfer touches two banks, so the same transfer can appear on either
// account's screen (as money out of client money, or money into operating).
export interface TransferSideRow {
  id: string;
  transfer_no: string;
  side: 'from' | 'to';
  signed: number;
  currency: string;
  transfer_date: string;
  notes: string | null;
}

export interface CommissionTransferRow {
  id: string;
  transfer_no: string;
  from_bank_account_id: string;
  to_bank_account_id: string;
  transfer_date: string;
  amount: number;
  currency: string;
  notes: string | null;
}

export interface BankAccountRow {
  id: string;
  name: string;
  currency: string;
}

export interface DoubleEntryRow {
  statement_line_id: string;
}

export interface PositionRow {
  line_order: number;
  component: string;
  label: string;
  amount: number | null;
}

export interface VarianceRow {
  reconciliation_id: string;
  match_type: string;
  variance: number;
  matched_at: string;
  statement_date: string;
  statement_description: string | null;
  statement_amount: number;
  transaction_date: string;
  transaction_description: string | null;
  transaction_amount: number;
  transaction_type: string;
  source?: string | null;
}

export type BookSource = 'cash' | 'settlement' | 'transfer';
export interface BookSelection {
  source: BookSource;
  id: string;
}

// A suggested match for one statement line (fin_bank_suggested_matches).
// Suggestions are questions, not decisions: nothing is written until the
// reader confirms one.
export interface SuggestedMatch {
  statement_line_id: string;
  statement_date: string;
  reference: string | null;
  line_amount: number;
  currency: string;
  suggestion_rank: number;
  source: 'settlement' | 'cash_bank' | 'transfer_from' | 'transfer_to';
  candidate_id: string;
  candidate_ref: string | null;
  candidate_date: string | null;
  candidate_amount: number | null;
  day_gap: number | null;
  // Insurance cash must be reconciled by a third Finance user; the server
  // enforces it and this flag lets the screen say so before the attempt.
  needs_third_user: boolean;
}

// One line of the "was this reviewed?" report.
export interface ReviewMetric {
  metric: string;
  value: number;
}
