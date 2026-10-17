import { describe, expect, it } from 'vitest';
import { isInForce } from './logic';

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
