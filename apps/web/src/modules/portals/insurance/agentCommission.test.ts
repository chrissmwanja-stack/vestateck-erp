import { describe, expect, it } from 'vitest';
import { netOf, recentAccruals, summariseAccruals, type AgentAccrual } from './agentCommission';

const acc = (over: Partial<AgentAccrual>): AgentAccrual => ({
  id: 'a', policy_id: 'p', intermediary_id: 'i', basis: 'pct_of_broker_commission', gross_amount: 100,
  wht_amount: 0, net_amount: null, currency: 'UGX', status: 'accrued', eligible_on: null, paid_at: null,
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z', ...over,
});

describe('summariseAccruals', () => {
  it('groups by status and never mixes currencies', () => {
    const s = summariseAccruals([
      acc({ id: '1', gross_amount: 1000 }),
      acc({ id: '2', gross_amount: 500, status: 'eligible' }),
      acc({ id: '3', gross_amount: 200, currency: 'USD' }),
      acc({ id: '4', gross_amount: 300, status: 'paid' }),
    ]);
    expect(s.accrued).toEqual({ UGX: 1000, USD: 200 });
    expect(s.eligible).toEqual({ UGX: 500 });
    expect(s.paid).toEqual({ UGX: 300 });
  });

  it('ignores reversed accruals entirely', () => {
    const s = summariseAccruals([acc({ gross_amount: 900, wht_amount: 90, status: 'reversed' })]);
    expect(s).toEqual({ accrued: {}, eligible: {}, paid: {}, outstanding: {}, withholding: {} });
  });

  it('outstanding is net of withholding and excludes paid', () => {
    const s = summariseAccruals([
      acc({ id: '1', gross_amount: 1000, wht_amount: 100 }),
      acc({ id: '2', gross_amount: 500, wht_amount: 50, net_amount: 450, status: 'eligible' }),
      acc({ id: '3', gross_amount: 700, wht_amount: 70, status: 'paid' }),
    ]);
    expect(s.outstanding).toEqual({ UGX: 1350 });
    expect(s.withholding).toEqual({ UGX: 220 });
  });
});

describe('netOf', () => {
  it('prefers the stored net, else gross less withholding', () => {
    expect(netOf({ gross_amount: 100, wht_amount: 10, net_amount: 88 })).toBe(88);
    expect(netOf({ gross_amount: 100, wht_amount: 10, net_amount: null })).toBe(90);
  });
});

describe('recentAccruals', () => {
  it('returns the newest changes first, capped at the limit', () => {
    const list = [
      acc({ id: 'old', updated_at: '2026-01-01T00:00:00Z' }),
      acc({ id: 'new', updated_at: '2026-11-01T00:00:00Z' }),
      acc({ id: 'mid', updated_at: '2026-06-01T00:00:00Z' }),
    ];
    expect(recentAccruals(list, 2).map((a) => a.id)).toEqual(['new', 'mid']);
  });
});
