import { describe, expect, it } from 'vitest';
import { hasForeignLines, ledgerTotals } from './ledgerBase';

describe('ledger base-currency columns', () => {
  it('shows base columns only when a row is in a foreign currency', () => {
    expect(hasForeignLines([{ debit: 100, credit: 0, fx_rate: 1 }])).toBe(false);
    expect(hasForeignLines([{ debit: 100, credit: 0, fx_rate: 1 }, { debit: 0, credit: 100, fx_rate: 3700.1234 }])).toBe(true);
  });

  it('does not show base columns for rows that carry no rate (older views)', () => {
    expect(hasForeignLines([{ debit: 100, credit: 0 }])).toBe(false);
    expect(hasForeignLines([])).toBe(false);
  });

  it('totals transaction and base amounts separately', () => {
    const t = ledgerTotals([
      { debit: 1000, credit: 0, base_debit: 3700123.4, base_credit: 0, fx_rate: 3700.1234 },
      { debit: 0, credit: 1000, base_debit: 0, base_credit: 3700123.4, fx_rate: 3700.1234 },
    ]);
    expect(t).toEqual({ debit: 1000, credit: 1000, baseDebit: 3700123.4, baseCredit: 3700123.4 });
  });

  it('falls back to the transaction amount when a base amount is missing', () => {
    const t = ledgerTotals([{ debit: 50, credit: 0 }, { debit: 0, credit: 50, base_credit: 50 }]);
    expect(t.baseDebit).toBe(50);
    expect(t.baseCredit).toBe(50);
  });

  it('accepts numeric strings from the database', () => {
    const t = ledgerTotals([{ debit: '12.50', credit: '0', base_debit: '46253.00', base_credit: '0', fx_rate: '3700.12340000' }]);
    expect(t.debit).toBe(12.5);
    expect(t.baseDebit).toBe(46253);
  });
});
