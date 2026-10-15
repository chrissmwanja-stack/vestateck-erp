export type PolicyCashKind = 'receipt' | 'remittance';
export type PolicyCashDecision = 'approve' | 'reject' | 'cancel';
export interface PolicyCashRequest {
  id: string;
  kind: PolicyCashKind;
  amount: number;
  cash_date: string;
  reference: string | null;
  notes: string | null;
  status: 'pending' | 'posted' | 'rejected' | 'cancelled' | 'void';
  maker_id: string;
  checker_id: string | null;
  checked_at: string | null;
  created_at: string;
  decision_reason: string | null;
  bank_account_id: string;
  bank_name: string;
  insurer_share_id?: string | null;
  insurer_name?: string | null;
  settlement_id: string | null;
  settlement_no: string | null;
  reconciled: boolean;
  reconciled_by: string | null;
  reconciled_at: string | null;
}
export interface PolicyCashPosition {
  policy_id: string;
  policy_status: string;
  cash_notice?: string;
  currency: string;
  actor_id: string;
  can_prepare: boolean;
  collected: number;
  remitted: number;
  commission_transferred: number;
  commission_amount: number;
  commission_status: string | null;
  available_allocated_funds: number;
  client_outstanding: number;
  insurer_outstanding: number;
  maximum_remittance: number;
  shares?: { share_id: string; insurer_id: string; insurer_name: string; is_lead: boolean; share_pct: number;
    premium_amount: number; pass_through_amount: number; commission_amount: number; funded: number; remitted: number;
    outstanding: number; available_allocated_funds: number; maximum_remittance: number }[];
  broker_fee_collected?: number; vat_collected?: number;
  requests: PolicyCashRequest[];
}
export interface PolicyCashBank { id: string; name: string; currency: string }
export interface PolicyCashPolicy {
  id: string; policy_no: string; status: string; currency: string; client_name: string; insurer_name: string;
}

/** UI hints only; the database rechecks authority, identity and balances. */
export function policyCashActions(position: PolicyCashPosition, request: PolicyCashRequest): PolicyCashDecision[] {
  if (!position.can_prepare || request.status !== 'pending') return [];
  return request.maker_id === position.actor_id ? ['cancel'] : ['approve', 'reject'];
}

export function validatePolicyCashInput(amount: string, date: string, bankId: string, maximum: number, today: string): string | null {
  if (!/^\d+(\.\d{1,2})?$/.test(amount) || !Number.isFinite(Number(amount)) || Number(amount) <= 0) {
    return 'Enter a positive amount with at most two decimals.';
  }
  if (Number(amount) > maximum) return 'Amount exceeds the current available limit. Refresh the cash position.';
  if (!bankId) return 'Choose a client-money bank account.';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date > today) return 'Choose a cash date no later than today.';
  return null;
}

/** Use the user's local calendar date, not UTC (which can be yesterday). */
export function policyCashToday(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
