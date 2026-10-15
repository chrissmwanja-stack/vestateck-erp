import { cents } from './calculation';
export const CASH_KINDS = {
  recovery: 'Insurer recovery receipt',
  premium_receipt: 'Remaining client premium receipt',
  refund: 'Client refund payment',
  remittance: 'Retained insurer remittance',
  commission_return: 'Return transferred commission to client money',
  commission_withdrawal: 'Withdraw retained earned commission',
} as const;
export type CancellationCashKind = keyof typeof CASH_KINDS;
export interface CancellationCashInsurer {
  adjustment_id: string;
  insurer_id: string;
  insurer_name: string;
  outstanding: string;
  recovery_due: string;
  commission_return_due: string;
  retained_commission: string;
  commission_withdrawal_due: string;
  funded_gross: string;
  spent: string;
  maximum_remittance: string;
  maximum_commission_return: string;
  maximum_commission_withdrawal: string;
  commission_status: string;
}
export interface CancellationCashRequest {
  id: string;
  kind: CancellationCashKind | 'void';
  status: 'pending' | 'posted' | 'rejected' | 'cancelled' | 'voided';
  amount: string;
  cash_date: string;
  reference: string;
  notes: string;
  decision_reason: string | null;
  adjustment_id: string | null;
  bank_account_id: string;
  to_bank_account_id: string | null;
  maker_id: string;
  checker_id: string | null;
  settlement_id: string | null;
  to_settlement_id: string | null;
  settlement_no: string | null;
  destination_settlement_no: string | null;
  matched: boolean;
  destination_matched: boolean;
  void_requested: boolean;
  voids_request_id: string | null;
  journals: { journal_entry_id: string; purpose: string }[];
}
export interface CancellationCashContext {
  policy_id: string;
  available: true;
  cancellation_id: string;
  cancellation_no: string;
  currency: string;
  actor_id: string;
  can_finance: boolean;
  selected_bank_id: string | null;
  bank_funding_sound?: boolean;
  proven_cash: string;
  bank_proven_cash: string;
  bank_book_cash: string;
  client_refund_outstanding: string;
  client_premium_outstanding: string;
  retained_fee_vat_reserve: string;
  commission_reserve: string;
  insurer_payable_reserve: string;
  maximum_refund: string;
  banks: {
    id: string;
    name: string;
    kind: 'client_money' | 'operating';
    currency: string;
  }[];
  insurers: CancellationCashInsurer[];
  requests: CancellationCashRequest[];
  offset: number;
  has_more: boolean;
}
export function parseCashContext(
  value: unknown,
  policy: string,
): CancellationCashContext | null {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error(
      'Cancellation cash details are unavailable. Refresh before taking action.',
    );
  const v = value as Omit<Partial<CancellationCashContext>, 'available'> & {
    available?: boolean;
  };
  if (v.policy_id !== policy)
    throw new Error(
      'Cancellation cash returned a different policy. No action is permitted.',
    );
  if (v.available === false) return null;
  if (
    v.available !== true ||
    typeof v.can_finance !== 'boolean' ||
    typeof v.cancellation_id !== 'string' ||
    typeof v.actor_id !== 'string' ||
    !Array.isArray(v.requests) ||
    !Array.isArray(v.insurers) ||
    !Array.isArray(v.banks) ||
    [
      'proven_cash',
      'bank_proven_cash',
      'bank_book_cash',
      'maximum_refund',
      'client_refund_outstanding',
    ].some(
      (k) => typeof (v as unknown as Record<string, unknown>)[k] !== 'string',
    )
  )
    throw new Error(
      'Cancellation cash details are incomplete. No payment authority is inferred.',
    );
  if (
    !v.requests.every(
      (r) =>
        r &&
        Array.isArray(r.journals) &&
        typeof r.id === 'string' &&
        typeof r.amount === 'string',
    )
  )
    throw new Error(
      'Cancellation cash audit details are incomplete. No payment authority is inferred.',
    );
  return v as CancellationCashContext;
}
export function cashMaximum(
  context: CancellationCashContext,
  kind: CancellationCashKind,
  adjustment: string,
): string {
  const a = context.insurers.find((x) => x.adjustment_id === adjustment);
  switch (kind) {
    case 'refund':
      return context.maximum_refund;
    case 'premium_receipt':
      return context.client_premium_outstanding;
    case 'recovery':
      return a?.recovery_due ?? '0';
    case 'remittance':
      return a?.maximum_remittance ?? '0';
    case 'commission_return':
      return a?.maximum_commission_return ?? '0';
    case 'commission_withdrawal':
      return a?.maximum_commission_withdrawal ?? '0';
  }
}
export function cashActions(
  context: Pick<CancellationCashContext, 'actor_id' | 'can_finance'>,
  row: CancellationCashRequest,
  mode: 'view' | 'finance',
) {
  if (mode !== 'finance' || !context.can_finance) return [] as string[];
  if (row.status === 'pending')
    return row.maker_id === context.actor_id
      ? ['cancel']
      : ['approve', 'reject'];
  return row.status === 'posted' && row.kind !== 'void' && !row.void_requested
    ? ['void']
    : [];
}
export function validateCashAmount(amount: string, maximum: string): void {
  if (cents(amount) <= 0n || cents(amount) > cents(maximum))
    throw new Error(
      `Enter a positive exact-cent amount no greater than ${maximum}. Refresh the selected bank's limits first.`,
    );
}
export function pairedCash(kind: CancellationCashKind): boolean {
  return kind === 'commission_return' || kind === 'commission_withdrawal';
}
export function insurerCash(kind: CancellationCashKind): boolean {
  return [
    'recovery',
    'remittance',
    'commission_return',
    'commission_withdrawal',
  ].includes(kind);
}
