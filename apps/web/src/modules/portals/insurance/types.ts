// Row shapes for the insurance tables and views, as the UI reads them.
// The generated Database types predate these tables, so they are typed here.

export type PolicyStatus = 'draft' | 'active' | 'renewed';
export type ClaimStatus = 'notified' | 'assessing' | 'approved' | 'settled' | 'repudiated' | 'closed';
export type CommissionStatus = 'deferred' | 'earned' | 'transferred';
/** Who pays a claim: the insurer straight to the client, or the insurer to the brokerage which pays the client. */
export type ClaimPaymentMode = 'insurer_direct' | 'via_broker';
export type ClaimPaymentKind = 'insurer_direct' | 'insurer_receipt' | 'client_payout';

export interface CommissionEntry {
  id: string;
  tenant_id: string;
  policy_id: string;
  policy_no: string;
  insurer_id: string;
  client_id: string;
  amount: number;
  status: CommissionStatus;
  earned_on: string | null;
  transfer_id: string | null;
  transfer_no: string | null;
  transfer_date: string | null;
  created_at: string;
  updated_at: string;
}

export interface CommissionPosition {
  tenant_id: string;
  unearned_amount: number;
  earned_in_client_money: number;
  transferred_amount: number;
}

export interface CommissionTransfer {
  id: string;
  tenant_id: string;
  transfer_no: string;
  from_bank_account_id: string;
  to_bank_account_id: string;
  transfer_date: string;
  amount: number;
  currency: string;
  status: 'posted' | 'void';
  notes: string | null;
  void_reason: string | null;
  created_at: string;
}

export interface TransferBankAccount {
  id: string;
  name: string;
  kind: 'operating' | 'client_money';
  currency: string;
  bank_name: string | null;
}

export interface ProductLine {
  id: string;
  code: string;
  name: string;
  class: 'general' | 'life' | 'health';
  is_active: boolean;
}

export interface Insurer {
  id: string;
  code: string;
  name: string;
  contact_name: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  default_commission_rate_pct: number;
  claim_payment_mode: ClaimPaymentMode;
  is_active: boolean;
}

export interface InsClient {
  id: string;
  client_id: string;
  client_type: 'individual' | 'corporate';
  tax_id: string | null;
  risk_rating: 'low' | 'medium' | 'high';
  kyc_status: 'pending' | 'verified' | 'expired';
  bd_clients: { name: string; email: string | null; phone: string | null } | null;
}

export interface Policy {
  id: string;
  policy_no: string;
  status: PolicyStatus;
  client_id: string;
  insurer_id: string;
  product_line_id: string;
  inception_date: string;
  expiry_date: string;
  sum_insured: number;
  currency: string;
  gross_premium: number;
  commission_rate_pct: number;
  commission_amount: number | null;
  net_premium_to_insurer: number | null;
  bound_at: string | null;
  journal_entry_id: string | null;
  renewal_of_id: string | null;
  risk_description: string | null;
  notes: string | null;
  ins_clients?: { bd_clients: { name: string } | null } | null;
  ins_insurers?: { name: string } | null;
  ins_product_lines?: { name: string } | null;
}

export interface Claim {
  id: string;
  claim_no: string;
  policy_id: string;
  status: ClaimStatus;
  loss_date: string;
  notified_date: string;
  loss_description: string;
  insurer_claim_ref: string | null;
  reserve_amount: number;
  approved_amount: number | null;
  paid_amount: number;
  payment_mode: ClaimPaymentMode | null;
  settled_at: string | null;
  created_at: string;
  ins_policies?: {
    policy_no: string;
    sum_insured: number;
    currency: string;
    ins_clients?: { bd_clients: { name: string } | null } | null;
  } | null;
}

export interface ClaimEvent {
  id: string;
  from_status: ClaimStatus | null;
  to_status: ClaimStatus;
  note: string | null;
  created_at: string;
}

export interface ClaimPayment {
  id: string;
  claim_id: string;
  kind: ClaimPaymentKind;
  amount: number;
  payment_date: string;
  reference: string | null;
  notes: string | null;
  settlement_id: string | null;
  status: 'posted' | 'void';
  void_reason: string | null;
  created_at: string;
}

export interface ClaimCashPosition {
  claim_id: string;
  claim_no: string;
  payment_mode: ClaimPaymentMode | null;
  approved_amount: number | null;
  paid_amount: number;
  received_from_insurer: number;
  paid_to_client: number;
  paid_by_insurer_direct: number;
  held_for_client: number;
  due_from_insurer: number | null;
}

export interface RenewalRow {
  policy_id: string;
  policy_no: string;
  client_name: string;
  insurer_name: string;
  product_name: string;
  inception_date: string;
  expiry_date: string;
  days_to_expiry: number;
  gross_premium: number;
  commission_rate_pct: number;
  currency: string;
  renewal_draft_id: string | null;
}

/** A policy's commission as shown on an insurer statement. 'legacy' = bound before commission deferral (income taken at bind, no ledger entry). */
export type StatementCommissionStatus = CommissionStatus | 'legacy';

export interface CommissionStatementRow {
  policy_id: string;
  policy_no: string;
  client_name: string;
  bound_on: string;
  currency: string;
  gross_premium: number;
  net_premium: number;
  commission: number;
  status: StatementCommissionStatus;
  earned_on: string | null;
  transfer_no: string | null;
  transfer_date: string | null;
}

export interface CommissionStatementTotals {
  policies: number;
  gross_premium: number;
  net_premium: number;
  commission: number;
  deferred: number;
  earned: number;
  transferred: number;
  legacy: number;
}

export interface CommissionStatement {
  rows: CommissionStatementRow[];
  totals: CommissionStatementTotals;
}

