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

// ---- Bank adjustments (D4e) -----------------------------------------------
// Shapes returned by the D4e panel queries and RPCs. Kept here so the panel,
// the register and the reports agree on one description.

export type AdjustmentStatus = 'pending' | 'posted' | 'rejected' | 'reversed';
export type AdjustmentKind = 'adjustment' | 'reversal';
export type AdjustmentApprovalMode = 'two_person' | 'one_person_exception' | null;

/** One bank_adjustments row as the panel and register read it. */
export interface AdjustmentRow {
  id: string;
  kind: AdjustmentKind;
  status: AdjustmentStatus;
  amount: number;
  currency: string;
  direction: 'in' | 'out';
  reason: string;
  bank_account: string;
  /** Needed by Rework: the server requires the same line as the rejected row. */
  bank_statement_line_id?: string;
  statement_date?: string;
  created_by: string;
  created_at: string;
  decided_by?: string | null;
  decided_at?: string | null;
  self_approved?: boolean;
  approval_mode?: AdjustmentApprovalMode;
  rejection_reason: string | null;
  reversal_reason: string | null;
  reworked_from?: string | null;
  reverses_adjustment_id?: string | null;
  journal_entry_id?: string | null;
  line: { statement_date: string; description: string | null; reference: string | null } | null;
  counter: { account_code: string; name: string } | null;
  /** Name of the finance user who proposed it (register view only). */
  created_by_name?: string | null;
  /** Name of the finance user who decided it (register view only). */
  approver_name?: string | null;
}

/** One row of bank_adjustment_history(). */
export interface AdjustmentEventRow {
  event: 'created' | 'reworked' | 'approved' | 'rejected' | 'reversal_requested' | 'reversed';
  actor_id: string;
  actor_name: string;
  note: string | null;
  created_at: string;
}

/** One row of bank_adjustment_unusual_account_usage(). */
export interface UnusualAccountRow {
  adjustment_id: string;
  bank_account: string;
  statement_date: string;
  currency: string;
  amount: number;
  direction: 'in' | 'out';
  counter_account_code: string;
  counter_account_name: string;
  reason: string;
  created_by_name: string | null;
  approver_name: string | null;
  approval_date: string | null;
  posting_journal_reference: string | null;
  self_approved: boolean;
}

/** One row of bank_adjustment_list_usual_accounts(). */
export interface UsualAccountRow {
  gl_account_id: string;
  account_code: string;
  account_name: string;
  created_at: string;
}

/** A selectable GL account, with the flags that decide whether it can be the
 *  other side of an adjustment. */
export interface GlAccountOption {
  id: string;
  account_code: string;
  name: string;
  is_header?: boolean;
  is_control_account?: boolean;
}

/** Why an account cannot be chosen as the counter-account, or null if it can.
 *  Mirrors bank_adjustment_validate_counter() so the picker explains the rule
 *  before the server refuses. */
export function counterAccountBlockReason(account: GlAccountOption): string | null {
  if (account.is_header) return 'a header account cannot be posted to';
  if (account.is_control_account) return 'a control account (receivables/payables) cannot be the other side';
  return null;
}
