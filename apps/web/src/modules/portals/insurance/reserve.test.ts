import { describe, expect, it } from 'vitest';
import { isReserveRevisable, reserveDelta, validateReserveRevision } from './logic';

const base = { current: 2_000_000, next: 3_000_000, sumInsured: 50_000_000, currency: 'UGX', reason: 'Surveyor found more damage' };

describe('isReserveRevisable', () => {
  it('allows open claims only', () => {
    for (const s of ['notified', 'assessing', 'approved'] as const) expect(isReserveRevisable(s)).toBe(true);
    for (const s of ['settled', 'repudiated', 'closed'] as const) expect(isReserveRevisable(s)).toBe(false);
  });
});

describe('validateReserveRevision', () => {
  it('accepts a valid revision', () => {
    expect(validateReserveRevision(base)).toEqual([]);
  });
  it('accepts a reduction to zero', () => {
    expect(validateReserveRevision({ ...base, next: 0 })).toEqual([]);
  });
  it('rejects a negative or non-numeric amount', () => {
    expect(validateReserveRevision({ ...base, next: -1 })[0]).toMatch(/zero or more/);
    expect(validateReserveRevision({ ...base, next: Number('abc') })[0]).toMatch(/zero or more/);
    expect(validateReserveRevision({ ...base, next: Number('') })).toEqual([]);
  });
  it('rejects an unchanged reserve, comparing at 2 decimal places', () => {
    expect(validateReserveRevision({ ...base, next: 2_000_000 })[0]).toMatch(/already/);
    expect(validateReserveRevision({ ...base, next: 2_000_000.004 })[0]).toMatch(/already/);
  });
  it('rejects a reserve above the sum insured but not when the sum insured is unknown', () => {
    expect(validateReserveRevision({ ...base, next: 50_000_001 })[0]).toMatch(/sum insured/);
    expect(validateReserveRevision({ ...base, next: 50_000_000 })).toEqual([]);
    expect(validateReserveRevision({ ...base, next: 90_000_000, sumInsured: 0 })).toEqual([]);
  });
  it('needs a reason of at least 5 characters', () => {
    expect(validateReserveRevision({ ...base, reason: '  no ' })[0]).toMatch(/reason/);
  });
});

describe('reserveDelta', () => {
  it('is the signed change', () => {
    expect(reserveDelta(2_000_000, 3_500_000.46)).toBe(1_500_000.46);
    expect(reserveDelta(3_000_000, 1_000_000)).toBe(-2_000_000);
  });
  it('treats a missing previous reserve as zero', () => {
    expect(reserveDelta(null, 500)).toBe(500);
  });
});
