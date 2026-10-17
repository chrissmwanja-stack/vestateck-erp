import { describe, expect, it } from 'vitest';
import { formatMoneyByCurrency, sumByCurrency } from './logic';

describe('sumByCurrency', () => {
  const rows = [
    { currency: 'UGX', amount: 1_000_000 },
    { currency: 'USD', amount: 2_500.5 },
    { currency: 'UGX', amount: '250000' },
    { currency: 'USD', amount: 499.5 },
  ];

  it('keeps each currency in its own total', () => {
    expect(sumByCurrency(rows, (r) => r.currency, (r) => r.amount)).toEqual({ UGX: 1_250_000, USD: 3_000 });
  });

  it('counts a missing currency as the fallback and a missing amount as zero', () => {
    const odd = [{ currency: null, amount: 100 }, { currency: 'USD', amount: null }, { currency: undefined, amount: undefined }];
    expect(sumByCurrency(odd, (r) => r.currency, (r) => r.amount)).toEqual({ UGX: 100, USD: 0 });
    expect(sumByCurrency(odd, (r) => r.currency, (r) => r.amount, 'KES')).toEqual({ KES: 100, USD: 0 });
  });

  it('ignores amounts that are not numbers', () => {
    expect(sumByCurrency([{ c: 'UGX', a: 'abc' }, { c: 'UGX', a: 5 }], (r) => r.c, (r) => r.a)).toEqual({ UGX: 5 });
  });

  it('does not drift on cents', () => {
    const cents = Array.from({ length: 10 }, () => ({ c: 'USD', a: 0.1 }));
    expect(sumByCurrency(cents, (r) => r.c, (r) => r.a)).toEqual({ USD: 1 });
  });

  it('returns nothing for no rows', () => {
    expect(sumByCurrency([], () => 'UGX', () => 1)).toEqual({});
  });
});

describe('formatMoneyByCurrency', () => {
  it('puts the company currency first, then the others A to Z, one per line', () => {
    const lines = formatMoneyByCurrency({ USD: 3000, EUR: 10, UGX: 1_250_000 }, 'UGX').split('\n');
    expect(lines).toHaveLength(3);
    expect(lines[0]).toContain('1,250,000');
    expect(lines[1]).toContain('10');
    expect(lines[2]).toContain('3,000');
  });

  it('shows zero in the company currency when there is nothing', () => {
    expect(formatMoneyByCurrency({}, 'UGX')).toBe(formatMoneyByCurrency({ UGX: 0 }, 'UGX'));
    expect(formatMoneyByCurrency({}, 'UGX')).not.toContain('\n');
  });

  it('never joins two currencies into one figure', () => {
    expect(formatMoneyByCurrency({ UGX: 100, USD: 100 }, 'UGX').split('\n')).toHaveLength(2);
  });
});
