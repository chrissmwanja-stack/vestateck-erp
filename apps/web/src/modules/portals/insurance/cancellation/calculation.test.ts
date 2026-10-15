import { describe, expect, it } from 'vitest';
import {
  allocatePassThroughRefund,
  calculateBrokerFeeRefund,
  calculatePassThroughRefund,
  calculateInsurerCancellation,
  CancellationReviewRequired,
  cents,
  coverageDays,
  money,
  splitClientCancellationCredit,
  type InsurerCancellationTerms,
} from './calculation';
const dates = {
  inception: '2026-01-01',
  expiry: '2026-12-31',
  effective: '2026-07-20',
}; // 200 used, 165 unused
const allocation = {
  insurer_id: 'A',
  premium_amount: '600.00',
  commission_amount: '60.00',
  commission_rate_pct: '10',
};
const terms: InsurerCancellationTerms = {
  method: 'pro_rata',
  contract_reference: 'Contract A / cancellation clause 3',
  pro_rata_permitted: true,
};
const run = (t: Partial<InsurerCancellationTerms> = {}) =>
  calculateInsurerCancellation(allocation, { ...terms, ...t }, dates);
describe('exact decimal arithmetic', () => {
  it.each(['0', '0.01', '9999999999999999.99', '1000.10'])(
    'round-trips %s without floating point',
    (n) => expect(cents(money(cents(n)))).toBe(cents(n)),
  );
  it.each([
    '-1',
    '1.001',
    '1e3',
    'NaN',
    'Infinity',
    '',
    ' 1',
    '10000000000000000',
  ])('rejects invalid money %s', (n) => expect(() => cents(n)).toThrow());
});
describe('coverage day convention', () => {
  it('uses inclusive cover dates and excludes the cancellation day', () =>
    expect(
      coverageDays(dates.inception, dates.expiry, dates.effective),
    ).toEqual({ total: 365, used: 200, unused: 165 }));
  it('accounts for leap years', () =>
    expect(coverageDays('2024-01-01', '2024-12-31', '2024-07-01')).toEqual({
      total: 366,
      used: 182,
      unused: 184,
    }));
  it('allows inception-day and day-after-expiry cancellation', () => {
    expect(coverageDays('2026-01-01', '2026-01-01', '2026-01-01').unused).toBe(
      1,
    );
    expect(coverageDays('2026-01-01', '2026-01-01', '2026-01-02').unused).toBe(
      0,
    );
  });
  it.each(['2026-02-30', '2025-12-31', '2027-01-02', '2026-1-1'])(
    'rejects invalid/out-of-cover date %s',
    (effective) =>
      expect(() =>
        coverageDays(dates.inception, dates.expiry, effective),
      ).toThrow(),
  );
});
describe('insurer-specific contractual calculations', () => {
  it('calculates pro-rata return, then derives retained premium exactly', () =>
    expect(run()).toMatchObject({
      return_premium: '271.23',
      retained_premium: '328.77',
      commission_clawback: '27.12',
      net_insurer_credit: '244.11',
    }));
  it('uses each insurer’s original rate, never a blended rate or equal split', () => {
    const a = run();
    const b = calculateInsurerCancellation(
      {
        insurer_id: 'B',
        premium_amount: '400',
        commission_amount: '80',
        commission_rate_pct: '20',
      },
      terms,
      dates,
    );
    expect(b.return_premium).toBe('180.82');
    expect(b.commission_clawback).toBe('36.16');
    expect(a.commission_clawback).not.toBe(b.commission_clawback);
  });
  it('requires affirmative contractual permission for fallback pro-rata', () =>
    expect(() => run({ pro_rata_permitted: false })).toThrow(
      CancellationReviewRequired,
    ));
  it('requires contractual evidence', () =>
    expect(() => run({ contract_reference: '' })).toThrow(
      CancellationReviewRequired,
    ));
  it('applies minimum retained premium', () =>
    expect(run({ minimum_retained_premium: '500' })).toMatchObject({
      return_premium: '100.00',
      retained_premium: '500.00',
      commission_clawback: '10.00',
    }));
  it('applies short-period terms instead of pro-rata', () =>
    expect(
      run({
        method: 'short_period',
        short_period_bands: [
          { through_day: 30, retained_pct: '20' },
          { through_day: 210, retained_pct: '70' },
          { through_day: 365, retained_pct: '100' },
        ],
      }),
    ).toMatchObject({
      return_premium: '180.00',
      commission_clawback: '18.00',
    }));
  it('resolves a short-period boundary to its inclusive band', () =>
    expect(
      calculateInsurerCancellation(
        allocation,
        {
          ...terms,
          method: 'short_period',
          short_period_bands: [
            { through_day: 30, retained_pct: '20' },
            { through_day: 365, retained_pct: '100' },
          ],
        },
        { ...dates, effective: '2026-01-31' },
      ).return_premium,
    ).toBe('480.00'));
  it('supports contractually non-refundable premium', () =>
    expect(run({ method: 'non_refundable' })).toMatchObject({
      return_premium: '0.00',
      commission_clawback: '0.00',
    }));
  it('sends unresolved amounts to Finance review without inventing a rate', () =>
    expect(() => run({ method: 'manual_review' })).toThrow(
      CancellationReviewRequired,
    ));
  it('cannot approve its own manual exception through an input flag', () =>
    expect(
      run({
        method: 'manual_review',
        manual_return_premium: '123.45',
        finance_exception_approved: true,
      }),
    ).toMatchObject({
      return_premium: '123.45',
      commission_clawback: '12.35',
      requires_finance_exception: true,
    }));
  it('enforces minimum retained premium for manual exceptions too', () =>
    expect(
      run({
        method: 'manual_review',
        manual_return_premium: '550',
        minimum_retained_premium: '100',
      }).return_premium,
    ).toBe('500.00'));
  it('returns the full original commission on full premium return', () =>
    expect(
      calculateInsurerCancellation(allocation, terms, {
        ...dates,
        effective: dates.inception,
      }),
    ).toMatchObject({
      return_premium: '600.00',
      commission_clawback: '60.00',
    }));
  it('returns no premium after expiry, even with a manual input', () =>
    expect(
      calculateInsurerCancellation(
        allocation,
        { ...terms, method: 'manual_review', manual_return_premium: '600' },
        { ...dates, effective: '2027-01-01' },
      ).return_premium,
    ).toBe('0.00'));
  it.each([
    { method: 'short_period' as const, short_period_bands: [] },
    {
      method: 'short_period' as const,
      short_period_bands: [{ through_day: 365, retained_pct: '90' }],
    },
    {
      method: 'short_period' as const,
      short_period_bands: [{ through_day: 300, retained_pct: '100' }],
    },
  ])('requires a complete short-period schedule %#', (t) =>
    expect(() => run(t)).toThrow(CancellationReviewRequired),
  );
  it.each([
    [
      { through_day: 365, retained_pct: '100' },
      { through_day: 30, retained_pct: '20' },
    ],
    [
      { through_day: 30, retained_pct: '80' },
      { through_day: 365, retained_pct: '50' },
    ],
    [
      { through_day: 30, retained_pct: '20' },
      { through_day: 30, retained_pct: '100' },
    ],
    [
      { through_day: 1.5, retained_pct: '20' },
      { through_day: 365, retained_pct: '100' },
    ],
  ])('rejects malformed schedules %#', (...bands) =>
    expect(() =>
      run({ method: 'short_period', short_period_bands: bands }),
    ).toThrow(),
  );
  it('rejects manual over-refunds and excessive minimum retention', () => {
    expect(() =>
      run({ method: 'manual_review', manual_return_premium: '601' }),
    ).toThrow();
    expect(() => run({ minimum_retained_premium: '601' })).toThrow();
  });
  it('rejects inconsistent historical commission', () =>
    expect(() =>
      calculateInsurerCancellation(
        { ...allocation, commission_amount: '59' },
        terms,
        dates,
      ),
    ).toThrow());
  it('retains the original four-decimal commission terms', () =>
    expect(
      calculateInsurerCancellation(
        {
          ...allocation,
          premium_amount: '1000',
          commission_amount: '123.46',
          commission_rate_pct: '12.3456',
        },
        { ...terms, method: 'manual_review', manual_return_premium: '500' },
        dates,
      ).commission_clawback,
    ).toBe('61.73'));
});
describe('recipient-specific charge refunds', () => {
  it('allocates against actual original amounts, not equal shares', () =>
    expect(
      allocatePassThroughRefund(
        [
          { insurer_id: 'A', amount: '60' },
          { insurer_id: 'B', amount: '90' },
        ],
        '75',
      ),
    ).toEqual([
      { insurer_id: 'A', amount: '30.00' },
      { insurer_id: 'B', amount: '45.00' },
    ]));
  it('never assigns an insurer-only charge to the lead', () =>
    expect(
      allocatePassThroughRefund([{ insurer_id: 'B', amount: '50' }], '20'),
    ).toEqual([{ insurer_id: 'B', amount: '20.00' }]));
  it('does not assign a cent to an insurer originally allocated zero', () =>
    expect(
      allocatePassThroughRefund(
        [
          { insurer_id: 'A', amount: '0.01' },
          { insurer_id: 'B', amount: '0' },
        ],
        '0.01',
      ),
    ).toEqual([
      { insurer_id: 'A', amount: '0.01' },
      { insurer_id: 'B', amount: '0.00' },
    ]));
  it('uses a deterministic tie-break independent of input order', () =>
    expect(
      allocatePassThroughRefund(
        [
          { insurer_id: 'B', amount: '0.01' },
          { insurer_id: 'A', amount: '0.01' },
        ],
        '0.01',
      ),
    ).toEqual([
      { insurer_id: 'B', amount: '0.00' },
      { insurer_id: 'A', amount: '0.01' },
    ]));
  it('supports zero-valued charge lines', () =>
    expect(
      allocatePassThroughRefund([{ insurer_id: 'A', amount: '0' }], '0'),
    ).toEqual([{ insurer_id: 'A', amount: '0.00' }]));
  it('rejects duplicate recipients and over-refunds', () => {
    expect(() =>
      allocatePassThroughRefund(
        [
          { insurer_id: 'A', amount: '1' },
          { insurer_id: 'A', amount: '1' },
        ],
        '1',
      ),
    ).toThrow();
    expect(() =>
      allocatePassThroughRefund([{ insurer_id: 'A', amount: '1' }], '2'),
    ).toThrow();
  });
  it('reconciles every cent and caps each recipient across small-amount combinations', () => {
    for (let a = 0; a <= 12; a++)
      for (let b = 0; b <= 12; b++)
        for (let r = 0; r <= a + b; r++) {
          const result = allocatePassThroughRefund(
            [
              { insurer_id: 'A', amount: money(BigInt(a)) },
              { insurer_id: 'B', amount: money(BigInt(b)) },
            ],
            money(BigInt(r)),
          );
          expect(result.reduce((sum, x) => sum + cents(x.amount), 0n)).toBe(
            BigInt(r),
          );
          expect(cents(result[0].amount) <= BigInt(a)).toBe(true);
          expect(cents(result[1].amount) <= BigInt(b)).toBe(true);
        }
  });
});
describe('broker-fee and VAT calculations', () => {
  it('credits VAT proportionately from the original tax amount', () =>
    expect(calculateBrokerFeeRefund('50', '9', '25')).toEqual({
      refund_base: '25.00',
      refund_vat: '4.50',
      refund_total: '29.50',
      retained_base: '25.00',
      retained_vat: '4.50',
    }));
  it('credits original VAT exactly on a full refund', () =>
    expect(calculateBrokerFeeRefund('0.03', '0.01', '0.03').refund_vat).toBe(
      '0.01',
    ));
  it('does not invent VAT where it was not calculated', () =>
    expect(calculateBrokerFeeRefund('50', '0', '25').refund_vat).toBe('0.00'));
  it('supports explicit zero charges', () =>
    expect(calculateBrokerFeeRefund('0', '0', '0').refund_total).toBe('0.00'));
  it('rejects over-refunds and tax without a taxable base', () => {
    expect(() => calculateBrokerFeeRefund('50', '9', '51')).toThrow();
    expect(() => calculateBrokerFeeRefund('0', '1', '0')).toThrow();
  });
});
describe('credit versus client cash refund', () => {
  it('credits unpaid amounts before calculating cash due', () =>
    expect(splitClientCancellationCredit('500', '300')).toEqual({
      receivable_credit: '300.00',
      refund_due: '200.00',
    }));
  it('does not promise a cash refund on an uncollected policy', () =>
    expect(splitClientCancellationCredit('500', '1000')).toEqual({
      receivable_credit: '500.00',
      refund_due: '0.00',
    }));
  it('calculates the full cash liability on a fully collected policy', () =>
    expect(splitClientCancellationCredit('500', '0')).toEqual({
      receivable_credit: '0.00',
      refund_due: '500.00',
    }));
});

describe('contractual pass-through refund decisions', () => {
  const original = [
    { insurer_id: 'A', amount: '60' },
    { insurer_id: 'B', amount: '40' },
  ];
  it('supports a refundable charge for A while B retains its own allocation', () => {
    const result = calculatePassThroughRefund(original, [
      { insurer_id: 'A', refund_amount: '60', basis: 'A terms permit refund' },
      { insurer_id: 'B', refund_amount: '0', basis: 'B terms retain charge' },
    ]);
    expect(result.refund_total).toBe('60.00');
    expect(result.recipients[0].refund_amount).toBe('60.00');
    expect(result.recipients[1].retained_amount).toBe('40.00');
  });
  it('rejects missing recipients even where the total amount looks reasonable', () =>
    expect(() =>
      calculatePassThroughRefund(original, [
        { insurer_id: 'A', refund_amount: '50', basis: 'Agreed basis' },
      ]),
    ).toThrow());
  it('rejects an over-refund to one recipient even when it is within the global charge', () =>
    expect(() =>
      calculatePassThroughRefund(original, [
        { insurer_id: 'A', refund_amount: '70', basis: 'Agreed basis' },
        { insurer_id: 'B', refund_amount: '0', basis: 'Agreed basis' },
      ]),
    ).toThrow());
  it('rejects missing contractual evidence', () =>
    expect(() =>
      calculatePassThroughRefund(original, [
        { insurer_id: 'A', refund_amount: '60', basis: '' },
        { insurer_id: 'B', refund_amount: '0', basis: 'Agreed basis' },
      ]),
    ).toThrow(CancellationReviewRequired));
  it('does not silently ignore short-period terms in favour of pro-rata', () =>
    expect(() =>
      run({ short_period_bands: [{ through_day: 365, retained_pct: '100' }] }),
    ).toThrow(CancellationReviewRequired));
});
