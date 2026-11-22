import { describe, expect, it } from 'vitest';
import { agedBalances, agingBucket, type StatementRow } from './reports';

const stmt = (over: Partial<StatementRow>): StatementRow => ({
  policy_id: 'p1', policy_no: 'POL-1', client_id: 'c1', client_name: 'Acme', currency: 'UGX',
  billed_amount: 1000, received_amount: 0, balance_amount: 1000, bound_date: '2026-10-01',
  expiry_date: '2027-09-30', status: 'active',
  ...over,
});

describe('agingBucket', () => {
  it('buckets by days outstanding since the policy was bound', () => {
    expect(agingBucket('2026-10-10', '2026-10-21')).toBe('current');
    expect(agingBucket('2026-09-15', '2026-10-21')).toBe('d30');
    expect(agingBucket('2026-08-20', '2026-10-21')).toBe('d90');
    expect(agingBucket('2026-06-01', '2026-10-21')).toBe('over90');
    expect(agingBucket(null, '2026-10-21')).toBe('current');
  });
});

describe('agedBalances', () => {
  it('keeps only outstanding balances, buckets them per client and currency, and totals', () => {
    const rows = [
      stmt({}),                                                            // fully outstanding, 11 days old -> current
      stmt({ policy_id: 'p2', balance_amount: 0, received_amount: 1000 }), // settled: excluded
      stmt({ policy_id: 'p3', policy_no: 'POL-3', bound_date: '2026-06-01', balance_amount: 400, received_amount: 600 }), // over90
      stmt({ policy_id: 'p4', policy_no: 'POL-4', client_name: 'Beta', currency: 'USD', balance_amount: 50, received_amount: 50 }),
    ];
    const aged = agedBalances(rows, '2026-10-21');
    expect(aged).toHaveLength(2);
    const acme = aged.find((a) => a.client === 'Acme' && a.currency === 'UGX');
    expect(acme?.buckets).toMatchObject({ current: 1000, over90: 400 });
    expect(acme?.total).toBe(1400);
    expect(aged[0].total).toBe(1400); // biggest balance first
  });
});
