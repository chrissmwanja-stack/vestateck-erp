import { describe, expect, it } from 'vitest';
import { isExpired, isInForce, policyDisplayStatus } from './logic';

describe('isInForce', () => {
  const today = '2026-10-17';

  it('counts an active policy that has not expired', () => {
    expect(isInForce({ status: 'active', expiry_date: '2027-01-01' }, today)).toBe(true);
  });

  it('counts a policy on its last day of cover', () => {
    expect(isInForce({ status: 'active', expiry_date: '2026-10-17' }, today)).toBe(true);
  });

  it('does not count an active policy past its expiry date', () => {
    expect(isInForce({ status: 'active', expiry_date: '2026-10-16' }, today)).toBe(false);
  });

  it('does not count other statuses, whatever the date', () => {
    for (const status of ['draft', 'renewed', 'reversed', 'cancelled'] as const) {
      expect(isInForce({ status, expiry_date: '2027-01-01' }, today)).toBe(false);
    }
  });

  it('reads a timestamp expiry as its date', () => {
    expect(isInForce({ status: 'active', expiry_date: '2026-10-17T00:00:00Z' }, today)).toBe(true);
  });
});

describe('policyDisplayStatus', () => {
  const today = '2026-10-17';

  it('shows an active policy past its expiry date as expired', () => {
    expect(policyDisplayStatus({ status: 'active', expiry_date: '2026-10-16' }, today)).toBe('expired');
    expect(isExpired({ status: 'active', expiry_date: '2026-10-16' }, today)).toBe(true);
  });

  it('keeps an active policy active on its last day of cover', () => {
    expect(policyDisplayStatus({ status: 'active', expiry_date: '2026-10-17' }, today)).toBe('active');
  });

  it('never relabels other statuses, even past expiry', () => {
    for (const status of ['draft', 'renewed', 'reversed', 'cancelled'] as const) {
      expect(policyDisplayStatus({ status, expiry_date: '2020-01-01' }, today)).toBe(status);
    }
  });

  it('reads a timestamp expiry as its date', () => {
    expect(isExpired({ status: 'active', expiry_date: '2026-10-16T23:59:59Z' }, today)).toBe(true);
    expect(isExpired({ status: 'active', expiry_date: '2026-10-17T00:00:00Z' }, today)).toBe(false);
  });

  it('is the exact complement of isInForce for active policies', () => {
    for (const d of ['2026-10-16', '2026-10-17', '2026-10-18']) {
      const p = { status: 'active' as const, expiry_date: d };
      expect(isExpired(p, today)).toBe(!isInForce(p, today));
    }
  });
});
