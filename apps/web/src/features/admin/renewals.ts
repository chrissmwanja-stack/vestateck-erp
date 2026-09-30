// Renewal pipeline for the Overview. VestaPortal subscriptions are
// ANNUAL only (no monthly billing), so the two clocks that matter are:
//
//   renewal -- a paying company's renews_at is within the window (or
//              already past: overdue). The operator invoices off-platform
//              today, so this list IS the dunning/renewal work queue;
//              read-only mode is the usual lever once it goes overdue.
//   trial   -- a trialing company's trial_ends_at is within its window:
//              the annual-conversion conversation.
//
// Pure and unit-tested; PlatformDashboard just renders the rows.

export interface RenewalRow {
  id: string;
  name: string;
  plan: string;
  subscription_status: string;
  renews_at: string | null;
  trial_ends_at: string | null;
}

export interface RenewalDue {
  row: RenewalRow;
  kind: 'overdue' | 'renewal' | 'trial';
  // Days from now to the date; negative = past.
  days: number;
  date: string;
}

function daysUntil(iso: string, now: Date): number {
  return Math.ceil((new Date(iso).getTime() - now.getTime()) / 86_400_000);
}

export const RENEWAL_WINDOW_DAYS = 90;
export const TRIAL_WINDOW_DAYS = 30;

// Companies whose annual renewal or trial conversion needs attention.
// Internal (platform) tenants and cancelled subscriptions are skipped.
export function renewalsDue(
  rows: RenewalRow[],
  now: Date = new Date(),
  renewalWindowDays: number = RENEWAL_WINDOW_DAYS,
  trialWindowDays: number = TRIAL_WINDOW_DAYS,
): RenewalDue[] {
  const out: RenewalDue[] = [];
  for (const row of rows) {
    if (row.plan === 'internal' || row.subscription_status === 'cancelled') continue;

    if (row.subscription_status === 'trialing' || row.plan === 'trial') {
      if (!row.trial_ends_at) continue;
      const days = daysUntil(row.trial_ends_at, now);
      if (days <= trialWindowDays) out.push({ row, kind: 'trial', days, date: row.trial_ends_at });
      continue;
    }

    if (!row.renews_at) continue;
    const days = daysUntil(row.renews_at, now);
    if (days < 0) out.push({ row, kind: 'overdue', days, date: row.renews_at });
    else if (days <= renewalWindowDays) out.push({ row, kind: 'renewal', days, date: row.renews_at });
  }
  return out.sort((a, b) => a.days - b.days);
}
