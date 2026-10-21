import { describe, expect, it } from 'vitest';
import { agedBalances, agingBucket, groupProduction, premiumTrend, shortMonth, type ProductionRow, type StatementRow } from './reports';

const prod = (over: Partial<ProductionRow>): ProductionRow => ({
  policy_id: 'p1', policy_no: 'POL-1', client_id: 'c1', client_name: 'Acme', insurer_id: 'i1', insurer_name: 'Jubilee',
  product_line_id: 'pl1', product_line_name: 'Motor', branch_id: null, branch_name: null, agent_id: null, agent_name: null,
  transaction_type: 'new_business', status: 'active', bound_date: '2026-10-01', currency: 'UGX',
  gross_premium: 1000, commission_amount: 100, net_premium_to_insurer: 900,
  ...over,
});

const stmt = (over: Partial<StatementRow>): StatementRow => ({
  policy_id: 'p1', policy_no: 'POL-1', client_id: 'c1', client_name: 'Acme', currency: 'UGX',
  billed_amount: 1000, received_amount: 0, balance_amount: 1000, bound_date: '2026-10-01',
  expiry_date: '2027-09-30', status: 'active',
  ...over,
});

describe('groupProduction', () => {
  it('groups by the chosen dimension and totals money per currency', () => {
    const rows = [
      prod({}),
      prod({ policy_id: 'p2', policy_no: 'POL-2', client_name: 'Beta', gross_premium: 500, commission_amount: 50, net_premium_to_insurer: 450 }),
      prod({ policy_id: 'p3', policy_no: 'POL-3', client_name: 'Gamma', currency: 'USD', gross_premium: 200, commission_amount: 20, net_premium_to_insurer: 180 }),
    ];
    const byClient = groupProduction(rows, 'client');
    expect(byClient).toHaveLength(3);
    expect(byClient[0]).toMatchObject({ key: 'Acme', count: 1 });
    expect(byClient[0].gross).toEqual({ UGX: 1000 });

    const byInsurer = groupProduction(rows, 'insurer');
    expect(byInsurer).toHaveLength(1);
    expect(byInsurer[0].count).toBe(3);
    expect(byInsurer[0].gross).toEqual({ UGX: 1500, USD: 200 });
    expect(byInsurer[0].commission).toEqual({ UGX: 150, USD: 20 });
    expect(byInsurer[0].net).toEqual({ UGX: 1350, USD: 180 });
  });

  it('shows unassigned dimensions as their own group', () => {
    const groups = groupProduction([prod({}), prod({ policy_id: 'p2', agent_name: 'Jane', agent_id: 'a1' })], 'agent');
    expect(groups.map((g) => g.key).sort()).toEqual(['Jane', 'No agent']);
  });

  it('sorts by count descending then name', () => {
    const rows = [
      prod({ client_name: 'Zeta' }),
      prod({ policy_id: 'p2', client_name: 'Acme' }),
      prod({ policy_id: 'p3', client_name: 'Acme' }),
    ];
    expect(groupProduction(rows, 'client').map((g) => g.key)).toEqual(['Acme', 'Zeta']);
  });
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

describe('groupProduction by month', () => {
  it('buckets written business by the month the policy was bound', () => {
    const rows = [
      prod({ bound_date: '2026-09-15' }),
      prod({ policy_id: 'p2', bound_date: '2026-10-01' }),
      prod({ policy_id: 'p3', bound_date: '2026-10-20', currency: 'USD', gross_premium: 200, commission_amount: 20, net_premium_to_insurer: 180 }),
    ];
    const byMonth = groupProduction(rows, 'month');
    expect(byMonth).toHaveLength(2);
    // Sorted by policy count desc, then key.
    expect(byMonth[0]).toMatchObject({ key: '2026-10', count: 2 });
    expect(byMonth[0].gross).toEqual({ UGX: 1000, USD: 200 });
    expect(byMonth[1]).toMatchObject({ key: '2026-09', count: 1 });
  });

  it('keeps an undated policy visible as its own group', () => {
    const groups = groupProduction([prod({}), prod({ policy_id: 'p2', bound_date: null })], 'month');
    expect(groups).toHaveLength(2);
    expect(groups.map((g) => g.key)).toContain('No date');
  });
});

describe('premiumTrend', () => {
  it('builds an ascending per-month series with per-currency gross', () => {
    const rows = [
      prod({ bound_date: '2026-10-05', gross_premium: 700, commission_amount: 70, net_premium_to_insurer: 630 }),
      prod({ policy_id: 'p2', bound_date: '2026-09-15', gross_premium: 1000 }),
      prod({ policy_id: 'p3', bound_date: '2026-10-20', currency: 'USD', gross_premium: 200, commission_amount: 20, net_premium_to_insurer: 180 }),
    ];
    const trend = premiumTrend(rows);
    expect(trend.map((t) => t.month)).toEqual(['2026-09', '2026-10']);
    expect(trend[0].gross).toEqual({ UGX: 1000 });
    expect(trend[1].gross).toEqual({ UGX: 700, USD: 200 });
    expect(trend[1].count).toBe(2);
  });

  it('skips rows without a bound date and returns an empty series for an empty book', () => {
    expect(premiumTrend([])).toEqual([]);
    expect(premiumTrend([prod({ bound_date: null })])).toEqual([]);
  });
});

describe('shortMonth', () => {
  it('formats without Intl', () => {
    expect(shortMonth('2026-09')).toBe('Sep 2026');
    expect(shortMonth('2027-01')).toBe('Jan 2027');
  });
});
