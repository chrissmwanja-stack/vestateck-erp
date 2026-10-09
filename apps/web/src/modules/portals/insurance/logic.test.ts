import { describe, expect, it } from 'vitest';
import {
  commissionSplit,
  daysBetween,
  formatMoney,
  friendlyError,
  isClaimOpen,
  isClaimTransitionAllowed,
  nextClaimStatuses,
  policyTermDays,
  renewalBucket,
  validatePolicyInput,
} from './logic';

// The claim map here must match ins_transition_claim() in
// supabase/migrations/20261010100000_insurance_brokerage_core.sql.
describe('claim lifecycle (mirrors ins_transition_claim)', () => {
  it('allows only the documented moves', () => {
    expect(isClaimTransitionAllowed('notified', 'assessing')).toBe(true);
    expect(isClaimTransitionAllowed('notified', 'repudiated')).toBe(true);
    expect(isClaimTransitionAllowed('assessing', 'approved')).toBe(true);
    expect(isClaimTransitionAllowed('approved', 'settled')).toBe(true);
    expect(isClaimTransitionAllowed('settled', 'closed')).toBe(true);
    expect(isClaimTransitionAllowed('repudiated', 'closed')).toBe(true);
  });

  it('refuses skips, reversals and moves out of closed', () => {
    expect(isClaimTransitionAllowed('notified', 'approved')).toBe(false);
    expect(isClaimTransitionAllowed('approved', 'assessing')).toBe(false);
    expect(isClaimTransitionAllowed('repudiated', 'approved')).toBe(false);
    expect(nextClaimStatuses('closed')).toEqual([]);
  });

  it('treats only notified, assessing and approved as open', () => {
    expect(isClaimOpen('notified')).toBe(true);
    expect(isClaimOpen('approved')).toBe(true);
    expect(isClaimOpen('settled')).toBe(false);
    expect(isClaimOpen('repudiated')).toBe(false);
    expect(isClaimOpen('closed')).toBe(false);
  });
});

describe('commission split (preview of ins_bind_policy)', () => {
  it('splits gross into commission and net to insurer', () => {
    expect(commissionSplit(1_200_000, 10)).toEqual({ commission: 120_000, net: 1_080_000 });
  });

  it('handles zero commission and rounds to 2dp without losing a cent', () => {
    expect(commissionSplit(500_000, 0)).toEqual({ commission: 0, net: 500_000 });
    const s = commissionSplit(1000.01, 12.5);
    expect(s.commission + s.net).toBeCloseTo(1000.01, 2);
    expect(Number.isInteger(Math.round(s.commission * 100))).toBe(true);
  });
});

describe('renewal pipeline buckets', () => {
  it('buckets by days to expiry', () => {
    expect(renewalBucket(-1)).toBe('overdue');
    expect(renewalBucket(0)).toBe('d0_30');
    expect(renewalBucket(30)).toBe('d0_30');
    expect(renewalBucket(31)).toBe('d31_60');
    expect(renewalBucket(90)).toBe('d61_90');
    expect(renewalBucket(120)).toBe('d91_120');
    expect(renewalBucket(121)).toBe('later');
  });
});

describe('dates', () => {
  it('counts whole days regardless of month and leap boundaries', () => {
    expect(daysBetween('2026-01-01', '2026-01-31')).toBe(30);
    expect(daysBetween('2028-02-28', '2028-03-01')).toBe(2); // leap year
    expect(daysBetween('2026-03-01', '2026-02-28')).toBe(-1);
  });

  it('measures a policy term in days', () => {
    expect(policyTermDays('2026-06-01', '2027-05-31')).toBe(364);
  });
});

describe('validatePolicyInput', () => {
  const ok = {
    clientId: 'c',
    insurerId: 'i',
    productLineId: 'p',
    inception: '2026-06-01',
    expiry: '2027-05-31',
    sumInsured: 1,
    grossPremium: 0,
    commissionRatePct: 10,
  };

  it('accepts a valid draft', () => {
    expect(validatePolicyInput(ok)).toEqual([]);
  });

  it('reports every problem, not just the first', () => {
    const errs = validatePolicyInput({ ...ok, clientId: '', expiry: '2026-06-01', commissionRatePct: 100 });
    expect(errs).toEqual(
      expect.arrayContaining(['Choose a client.', 'Expiry must be after inception.', 'Commission must be at least 0% and below 100%.']),
    );
  });
});

describe('formatting', () => {
  it('formats UGX with no decimals for whole amounts and dashes for missing values', () => {
    expect(formatMoney(1200000)).toMatch(/1,200,000/);
    expect(formatMoney(null)).toBe('-');
    expect(formatMoney(undefined)).toBe('-');
  });

  it('strips the server error code for display', () => {
    expect(friendlyError('INS_NOT_DRAFT: policy POL-2026-00001 is already active')).toBe(
      'policy POL-2026-00001 is already active',
    );
    expect(friendlyError('new row violates row-level security policy')).toBe('new row violates row-level security policy');
  });
});
