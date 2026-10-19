// The Finance worklist (ins_finance_pending_approvals): premium cash requests, cancellation cash
// requests and open cancellation cases that are waiting for a Finance decision. Read only; the
// decisions themselves still go through the existing approve and reject RPCs on each policy.

export type PendingItemType = 'premium_cash' | 'cancellation_cash' | 'cancellation';

export interface PendingApproval {
  item_type: PendingItemType;
  item_id: string;
  policy_id: string;
  policy_no: string;
  client_name: string;
  insurer_name: string;
  currency: string;
  kind: string;
  amount: number | string | null;
  submitted_at: string;
  submitted_by_name: string;
  /** True when the caller made it, so the server bars them from approving it. */
  is_mine: boolean;
}

/** The server returns at most this many, oldest first. */
export const PENDING_LIMIT = 200;

export const PENDING_TYPE_LABEL: Record<PendingItemType, string> = {
  premium_cash: 'Premium cash',
  cancellation_cash: 'Cancellation cash',
  cancellation: 'Cancellation',
};

const KIND_LABEL: Record<PendingItemType, Record<string, string>> = {
  premium_cash: { receipt: 'Premium receipt', remittance: 'Insurer remittance' },
  cancellation_cash: {
    recovery: 'Recovery',
    premium_receipt: 'Premium receipt',
    refund: 'Client refund',
    remittance: 'Insurer remittance',
    commission_return: 'Commission return',
    commission_withdrawal: 'Commission withdrawal',
    void: 'Void of a posted request',
  },
  cancellation: { proposed: 'Awaiting preparation', prepared: 'Awaiting decision' },
};

/** What the item is, in words. An unknown kind from a newer server is shown as it came, not hidden. */
export function pendingKindLabel(item: Pick<PendingApproval, 'item_type' | 'kind'>): string {
  return KIND_LABEL[item.item_type]?.[item.kind] ?? item.kind;
}

/** How long an item has been waiting, in whole days: "Today", "1 day", "5 days". */
export function waitingLabel(submittedAt: string, now: Date = new Date()): string {
  const days = Math.max(0, Math.floor((now.getTime() - new Date(submittedAt).getTime()) / 86_400_000));
  return days === 0 ? 'Today' : days === 1 ? '1 day' : `${days} days`;
}

/** The items the caller may decide come first; the ones they made follow. Each group keeps the server's oldest-first order. */
export function orderForReviewer(items: PendingApproval[]): PendingApproval[] {
  return [...items.filter((i) => !i.is_mine), ...items.filter((i) => i.is_mine)];
}

export function pendingCounts(items: Pick<PendingApproval, 'is_mine'>[]): { forYou: number; yours: number } {
  const yours = items.filter((i) => i.is_mine).length;
  return { forYou: items.length - yours, yours };
}
