import { describe, expect, it } from 'vitest';
import {
  accrualDate, eligibilityLabel, EMPTY_ACCRUAL_FILTERS, filterAccruals, registerTotals, sortAccruals, sortEvents,
  withholdingNote, type AccrualLabels, type AgentAccrualDetail, type AgentAccrualEvent,
} from './agentCommission';

const base = (over: Partial<AgentAccrualDetail> = {}): AgentAccrualDetail => ({
  id: 'a1',
  policy_id: 'p1',
  intermediary_id: 'i1',
  basis: 'pct_of_broker_commission',
  gross_amount: 300000,
  wht_amount: 0,
  net_amount: 300000,
  currency: 'UGX',
  status: 'accrued',
  eligible_on: null,
  paid_at: null,
  created_at: '2026-11-10T09:00:00Z',
  updated_at: '2026-11-10T09:00:00Z',
  term_id: 't1',
  rate_pct: 40,
  fixed_amount: null,
  commission_base: 750000,
  reversal_reason: null,
  journal_entry_id: 'j1',
  payment_journal_entry_id: null,
  wht_rate_pct: null,
  wht_is_final: null,
  wht_parameter_ref: null,
  ...over,
});

const labels: AccrualLabels = {
  agent: (a) => ({ i1: 'Acme Agents', i2: 'Zeta Partners' } as Record<string, string>)[a.intermediary_id] ?? '',
  policy: (a) => ({ p1: 'POL-001', p2: 'POL-002' } as Record<string, string>)[a.policy_id] ?? '',
  client: (a) => ({ p1: 'Jubilee Foods', p2: 'Müller Logistics' } as Record<string, string>)[a.policy_id] ?? '',
};

describe('accrualDate', () => {
  it('is the date part only, so a timezone cannot shift the day', () => {
    expect(accrualDate({ created_at: '2026-11-10T23:30:00Z' })).toBe('2026-11-10');
  });
});

describe('eligibilityLabel', () => {
  it('never says "eligible" alone, because it reads like "paid"', () => {
    expect(eligibilityLabel({ status: 'eligible', eligible_on: '2026-11-12' }))
      .toBe('Eligible since 2026-11-12');
    expect(eligibilityLabel({ status: 'eligible', eligible_on: null })).toBe('Eligible, not yet paid');
  });

  it('says what an accrued row is waiting for', () => {
    expect(eligibilityLabel({ status: 'accrued', eligible_on: null }))
      .toContain('commission to be earned');
  });

  it('distinguishes paid and reversed', () => {
    expect(eligibilityLabel({ status: 'paid', eligible_on: '2026-11-01' })).toBe('Paid');
    expect(eligibilityLabel({ status: 'reversed', eligible_on: null })).toContain('not payable');
  });
});

describe('withholdingNote', () => {
  // The rule that changed: withholding is taken when the agent is PAID. An unpaid
  // share's 0.00 is "not yet determined", and must not read as "no tax owed".
  it('describes an unpaid share as not yet determined, not as no tax', () => {
    const note = withholdingNote({ status: 'accrued', wht_amount: 0, wht_rate_pct: null, wht_is_final: null });
    expect(note).toBe('determined when the agent is paid');
    expect(note).not.toContain('no tax');
  });

  it('distinguishes a final withholding from one on account', () => {
    expect(withholdingNote({ status: 'paid', wht_amount: 30000, wht_rate_pct: 10, wht_is_final: true }))
      .toBe('final tax at 10%');
    expect(withholdingNote({ status: 'paid', wht_amount: 30000, wht_rate_pct: 10, wht_is_final: false }))
      .toContain('the agent still declares the income');
  });

  it('describes a paid share that carried no tax plainly', () => {
    expect(withholdingNote({ status: 'paid', wht_amount: 0, wht_rate_pct: null, wht_is_final: null }))
      .toBe('nothing withheld on this share');
  });

  it('says a reversed share has nothing to withhold', () => {
    expect(withholdingNote({ status: 'reversed', wht_amount: 0, wht_rate_pct: null, wht_is_final: null }))
      .toBe('nothing to withhold, the share was reversed');
  });
});

describe('filterAccruals', () => {
  const rows = [
    base({ id: 'a1' }),
    base({ id: 'a2', intermediary_id: 'i2', policy_id: 'p2', basis: 'pct_of_gross_premium', currency: 'USD' }),
    base({ id: 'a3', status: 'reversed', created_at: '2026-10-01T09:00:00Z' }),
  ];

  it('an empty filter matches everything', () => {
    expect(filterAccruals(rows, EMPTY_ACCRUAL_FILTERS, labels)).toHaveLength(3);
  });

  it('matches text against agent, policy and client at once', () => {
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, text: 'zeta' }, labels).map((r) => r.id)).toEqual(['a2']);
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, text: 'POL-001' }, labels).map((r) => r.id)).toEqual(['a1', 'a3']);
    // Accents folded, like the rest of the insurance lists.
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, text: 'muller' }, labels).map((r) => r.id)).toEqual(['a2']);
  });

  it('requires every typed word to match, across fields', () => {
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, text: 'zeta muller' }, labels).map((r) => r.id)).toEqual(['a2']);
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, text: 'zeta acme' }, labels)).toHaveLength(0);
  });

  it('filters by agent, status, basis and currency', () => {
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, agentId: 'i2' }, labels).map((r) => r.id)).toEqual(['a2']);
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, status: 'reversed' }, labels).map((r) => r.id)).toEqual(['a3']);
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, basis: 'pct_of_gross_premium' }, labels).map((r) => r.id)).toEqual(['a2']);
    expect(filterAccruals(rows, { ...EMPTY_ACCRUAL_FILTERS, currency: 'USD' }, labels).map((r) => r.id)).toEqual(['a2']);
  });

  it('includes both ends of a date range', () => {
    const onEdge = [base({ id: 'edge', created_at: '2026-11-15T18:00:00Z' })];
    expect(filterAccruals(onEdge, { ...EMPTY_ACCRUAL_FILTERS, accruedFrom: '2026-11-15', accruedTo: '2026-11-15' }, labels))
      .toHaveLength(1);
    expect(filterAccruals(onEdge, { ...EMPTY_ACCRUAL_FILTERS, accruedFrom: '2026-11-16' }, labels)).toHaveLength(0);
    expect(filterAccruals(onEdge, { ...EMPTY_ACCRUAL_FILTERS, accruedTo: '2026-11-14' }, labels)).toHaveLength(0);
  });
});

describe('sortAccruals', () => {
  const rows = [
    base({ id: 'a1', gross_amount: 300000, created_at: '2026-11-10T09:00:00Z' }),
    base({ id: 'a2', gross_amount: 500000, created_at: '2026-11-12T09:00:00Z', intermediary_id: 'i2', policy_id: 'p2' }),
    base({ id: 'a3', gross_amount: 100000, created_at: '2026-11-11T09:00:00Z' }),
  ];
  const ids = (s: Parameters<typeof sortAccruals>[1]) => sortAccruals(rows, s, labels).map((r) => r.id);

  it('sorts newest and oldest first', () => {
    expect(ids('newest')).toEqual(['a2', 'a3', 'a1']);
    expect(ids('oldest')).toEqual(['a1', 'a3', 'a2']);
  });

  it('sorts by gross descending and by agent and policy A to Z', () => {
    expect(ids('gross_desc')).toEqual(['a2', 'a1', 'a3']);
    // Within one agent, newest first: a3 (12 Nov) before a1 (10 Nov).
    expect(ids('agent_az')).toEqual(['a3', 'a1', 'a2']); // Acme, Acme, Zeta
    expect(sortAccruals(rows, 'policy_az', labels).map((r) => labels.policy(r)))
      .toEqual(['POL-001', 'POL-001', 'POL-002']);
  });
});

describe('registerTotals', () => {
  it('leaves reversed rows out entirely', () => {
    const t = registerTotals([base({ status: 'reversed', gross_amount: 999 })]);
    expect(t).toEqual({ gross: {}, withholding: {}, net: {} });
  });

  it('keeps currencies apart rather than adding them', () => {
    const t = registerTotals([base(), base({ id: 'b', currency: 'USD', gross_amount: 100 })]);
    expect(t.gross).toEqual({ UGX: 300000, USD: 100 });
  });

  // The behavioural consequence of moving withholding to the payment event: an
  // accrued share has had nothing taken out of it, so the agent is owed the gross.
  it('counts an unpaid share at its gross, because nothing has been withheld', () => {
    const t = registerTotals([base({ status: 'accrued' })]);
    expect(t.withholding).toEqual({});
    expect(t.net).toEqual({ UGX: 300000 });
  });

  it('counts a paid share at the net it was actually paid', () => {
    const t = registerTotals([base({
      status: 'paid', wht_amount: 30000, net_amount: 270000, wht_rate_pct: 10, wht_is_final: true,
    })]);
    expect(t.gross).toEqual({ UGX: 300000 });
    expect(t.withholding).toEqual({ UGX: 30000 });
    expect(t.net).toEqual({ UGX: 270000 });
  });

  it('falls back to gross less withholding when no net was stored', () => {
    const t = registerTotals([base({ status: 'eligible', wht_amount: 5000, net_amount: null })]);
    expect(t.net).toEqual({ UGX: 295000 });
  });
});

describe('sortEvents', () => {
  const ev = (over: Partial<AgentAccrualEvent>): AgentAccrualEvent => ({
    id: 'e1', accrual_id: 'a1', event: 'accrued', amount: 300000, journal_entry_id: null,
    note: null, actor_id: null, created_at: '2026-11-10T09:00:00Z', ...over,
  });

  it('is chronological regardless of arrival order', () => {
    const out = sortEvents([
      ev({ id: 'e3', event: 'paid', created_at: '2026-11-12T09:00:00Z' }),
      ev({ id: 'e1', event: 'accrued', created_at: '2026-11-10T09:00:00Z' }),
      ev({ id: 'e2', event: 'eligible', created_at: '2026-11-11T09:00:00Z' }),
    ]);
    expect(out.map((e) => e.event)).toEqual(['accrued', 'eligible', 'paid']);
  });

  it('is stable when two events share a timestamp', () => {
    const out = sortEvents([
      ev({ id: 'b', created_at: '2026-11-10T09:00:00Z' }),
      ev({ id: 'a', created_at: '2026-11-10T09:00:00Z' }),
    ]);
    expect(out.map((e) => e.id)).toEqual(['a', 'b']);
  });
});
