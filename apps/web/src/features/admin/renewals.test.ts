import { describe, expect, it } from 'vitest';
import { renewalsDue, type RenewalRow } from './renewals';

// Fixed "now" so the window math is deterministic.
const NOW = new Date('2026-09-30T12:00:00Z');

function row(partial: Partial<RenewalRow> & { id: string; name: string }): RenewalRow {
  return {
    plan: 'standard',
    subscription_status: 'active',
    renews_at: null,
    trial_ends_at: null,
    ...partial,
  };
}

describe('renewalsDue', () => {
  it('lists paid renewals inside the 90-day window, soonest first', () => {
    const rows = renewalsDue(
      [
        row({ id: 'a', name: 'Alpha', renews_at: '2026-12-20T23:59:59Z' }), // ~81d
        row({ id: 'b', name: 'Beta', renews_at: '2026-10-10T23:59:59Z' }), // ~10d
        row({ id: 'c', name: 'Gamma', renews_at: '2027-06-01T23:59:59Z' }), // outside window
      ],
      NOW,
    );
    expect(rows.map((r) => r.row.id)).toEqual(['b', 'a']);
    expect(rows.every((r) => r.kind === 'renewal')).toBe(true);
  });

  it('flags past renews_at as overdue (and sorts it first)', () => {
    const rows = renewalsDue(
      [
        row({ id: 'ok', name: 'Ok', renews_at: '2026-10-10T23:59:59Z' }),
        row({ id: 'late', name: 'Late', renews_at: '2026-09-10T23:59:59Z' }),
      ],
      NOW,
    );
    expect(rows[0].row.id).toBe('late');
    expect(rows[0].kind).toBe('overdue');
    expect(rows[0].days).toBeLessThan(0);
  });

  it('lists trials ending within 30 days, including already-ended ones', () => {
    const rows = renewalsDue(
      [
        row({ id: 't1', name: 'Trial Soon', plan: 'trial', subscription_status: 'trialing', trial_ends_at: '2026-10-05T23:59:59Z' }),
        row({ id: 't2', name: 'Trial Far', plan: 'trial', subscription_status: 'trialing', trial_ends_at: '2026-12-25T23:59:59Z' }),
        row({ id: 't3', name: 'Trial Ended', plan: 'trial', subscription_status: 'trialing', trial_ends_at: '2026-09-25T23:59:59Z' }),
      ],
      NOW,
    );
    expect(rows.map((r) => r.row.id)).toEqual(['t3', 't1']);
    expect(rows.every((r) => r.kind === 'trial')).toBe(true);
    expect(rows[0].days).toBeLessThan(0);
  });

  it('skips internal tenants, cancelled subscriptions, and rows without dates', () => {
    const rows = renewalsDue(
      [
        row({ id: 'i', name: 'Internal', plan: 'internal', renews_at: '2026-10-01T23:59:59Z' }),
        row({ id: 'x', name: 'Cancelled', subscription_status: 'cancelled', renews_at: '2026-10-01T23:59:59Z' }),
        row({ id: 'n', name: 'No dates' }),
      ],
      NOW,
    );
    expect(rows).toEqual([]);
  });

  it('treats a trialing company on a paid plan by its trial clock', () => {
    const rows = renewalsDue(
      [row({ id: 'conv', name: 'Converting', plan: 'starter', subscription_status: 'trialing', trial_ends_at: '2026-10-02T23:59:59Z' })],
      NOW,
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('trial');
  });
});
