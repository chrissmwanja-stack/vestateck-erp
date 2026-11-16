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
