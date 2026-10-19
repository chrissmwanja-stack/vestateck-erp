import { describe, expect, it } from 'vitest';
import { orderForReviewer, pendingCounts, pendingKindLabel, waitingLabel, type PendingApproval } from './pendingApprovals';

const item = (over: Partial<PendingApproval>): PendingApproval => ({
  item_type: 'premium_cash', item_id: 'i', policy_id: 'p', policy_no: 'POL-1', client_name: 'Acme', insurer_name: 'Alpha', currency: 'UGX',
  kind: 'receipt', amount: 100, submitted_at: '2026-10-10T08:00:00Z', submitted_by_name: 'Mary', is_mine: false, ...over,
});

describe('pending approvals helpers', () => {
  it('words each kind, and shows an unknown one as it came', () => {
    expect(pendingKindLabel(item({}))).toBe('Premium receipt');
    expect(pendingKindLabel(item({ kind: 'remittance' }))).toBe('Insurer remittance');
    expect(pendingKindLabel(item({ item_type: 'cancellation_cash', kind: 'refund' }))).toBe('Client refund');
    expect(pendingKindLabel(item({ item_type: 'cancellation', kind: 'proposed' }))).toBe('Awaiting preparation');
    expect(pendingKindLabel(item({ item_type: 'cancellation', kind: 'prepared' }))).toBe('Awaiting decision');
    expect(pendingKindLabel(item({ kind: 'something_new' }))).toBe('something_new');
  });

  it('says how long an item has waited', () => {
    const now = new Date('2026-10-19T09:00:00Z');
    expect(waitingLabel('2026-10-19T01:00:00Z', now)).toBe('Today');
    expect(waitingLabel('2026-10-18T08:00:00Z', now)).toBe('1 day');
    expect(waitingLabel('2026-10-14T08:00:00Z', now)).toBe('5 days');
    expect(waitingLabel('2026-10-20T08:00:00Z', now)).toBe('Today');
  });

  it('puts the items the reviewer can decide first, each group oldest first', () => {
    const items = [item({ item_id: 'a', is_mine: true }), item({ item_id: 'b' }), item({ item_id: 'c', is_mine: true }), item({ item_id: 'd' })];
    expect(orderForReviewer(items).map((i) => i.item_id)).toEqual(['b', 'd', 'a', 'c']);
    expect(pendingCounts(items)).toEqual({ forYou: 2, yours: 2 });
    expect(pendingCounts([])).toEqual({ forYou: 0, yours: 0 });
  });
});
