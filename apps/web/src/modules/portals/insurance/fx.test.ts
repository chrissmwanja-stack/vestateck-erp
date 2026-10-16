import { describe, expect, it } from 'vitest';
import {
  canApproveFxRate,
  canWithdrawFxRate,
  formatFxRate,
  isValidFxWithdrawReason,
  localIsoDate,
  validateFxRateEntry,
  type FxRateInput,
} from './fx';

const TODAY = '2026-10-16';
const good: FxRateInput = { currency: 'usd', rateDate: '2026-10-15', rate: '3700.5', source: 'Central bank bulletin' };

describe('validateFxRateEntry', () => {
  it('accepts a valid draft and normalises the currency and source', () => {
    const r = validateFxRateEntry({ ...good, source: '  Bulletin  ' }, 'UGX', TODAY);
    expect(r).toEqual({ ok: true, value: { currency: 'USD', rate_date: '2026-10-15', rate: 3700.5, source: 'Bulletin' } });
  });

  it('refuses the functional currency, whose rate is always 1', () => {
    const r = validateFxRateEntry({ ...good, currency: 'ugx' }, 'UGX', TODAY);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.errors.currency).toContain('always 1');
  });

  it('refuses a malformed currency code', () => {
    for (const currency of ['US', 'USDX', 'U5D', '']) {
      const r = validateFxRateEntry({ ...good, currency }, 'UGX', TODAY);
      expect(r.ok, currency).toBe(false);
    }
  });

  it('refuses a future date and a missing date', () => {
    const future = validateFxRateEntry({ ...good, rateDate: '2026-10-17' }, 'UGX', TODAY);
    expect(!future.ok && future.errors.rateDate).toContain('future');
    const missing = validateFxRateEntry({ ...good, rateDate: '' }, 'UGX', TODAY);
    expect(!missing.ok && missing.errors.rateDate).toBeTruthy();
  });

  it('allows today', () => {
    expect(validateFxRateEntry({ ...good, rateDate: TODAY }, 'UGX', TODAY).ok).toBe(true);
  });

  it('refuses zero, negative, non-numeric and over-precise rates', () => {
    for (const rate of ['0', '-3', 'abc', '']) {
      const r = validateFxRateEntry({ ...good, rate }, 'UGX', TODAY);
      expect(!r.ok && r.errors.rate, rate).toBeTruthy();
    }
    const precise = validateFxRateEntry({ ...good, rate: '1.12345678901' }, 'UGX', TODAY);
    expect(!precise.ok && precise.errors.rate).toContain('10 decimal');
    expect(validateFxRateEntry({ ...good, rate: '1.1234567890' }, 'UGX', TODAY).ok).toBe(true);
  });

  it('requires a source', () => {
    const r = validateFxRateEntry({ ...good, source: '   ' }, 'UGX', TODAY);
    expect(!r.ok && r.errors.source).toBeTruthy();
  });
});

describe('approval and withdrawal rules', () => {
  const draftByAlice = { status: 'draft' as const, entered_by: 'alice' };

  it('lets someone other than the enterer approve a draft, and never the enterer', () => {
    expect(canApproveFxRate(draftByAlice, 'bob', true)).toBe(true);
    expect(canApproveFxRate(draftByAlice, 'alice', true)).toBe(false);
  });

  it('does not offer approval without the approver role, or for a decided rate', () => {
    expect(canApproveFxRate(draftByAlice, 'bob', false)).toBe(false);
    expect(canApproveFxRate({ status: 'approved', entered_by: 'alice' }, 'bob', true)).toBe(false);
    expect(canApproveFxRate(draftByAlice, null, true)).toBe(false);
  });

  it('lets the enterer or a company admin withdraw a draft only', () => {
    expect(canWithdrawFxRate(draftByAlice, 'alice', false)).toBe(true);
    expect(canWithdrawFxRate(draftByAlice, 'bob', true)).toBe(true);
    expect(canWithdrawFxRate(draftByAlice, 'bob', false)).toBe(false);
    expect(canWithdrawFxRate({ status: 'approved', entered_by: 'alice' }, 'alice', true)).toBe(false);
  });

  it('requires a withdrawal reason of at least five characters', () => {
    expect(isValidFxWithdrawReason('typo')).toBe(false);
    expect(isValidFxWithdrawReason('  typo  ')).toBe(false);
    expect(isValidFxWithdrawReason('wrong date')).toBe(true);
  });
});

describe('display helpers', () => {
  it('shows rates without trailing zeros', () => {
    expect(formatFxRate(3700.5)).toBe('3700.5');
    expect(formatFxRate(1.0)).toBe('1');
    expect(formatFxRate(0.0001234567)).toBe('0.0001234567');
  });

  it('builds the local date as yyyy-mm-dd', () => {
    expect(localIsoDate(new Date(2026, 9, 6, 23, 59))).toBe('2026-10-06');
  });
});
