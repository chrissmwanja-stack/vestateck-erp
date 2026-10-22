import { useEffect } from 'react';
import { rpc } from './db';

// Insurance has no scheduler (the platform does not use pg_cron), so renewal
// reminders are produced by a "cronless cron": ins_renewal_notification_sweep()
// is called when an insurance screen opens. The server marks every policy it
// has announced, so calling it often is harmless; this throttle only avoids a
// pointless round trip on every navigation.
export const SWEEP_MIN_INTERVAL_MS = 30 * 60 * 1000;

let lastRunAt: number | null = null;

/** True when no sweep has run yet, or the last one is older than the interval. */
export function shouldRunSweep(now: number, last: number | null, interval = SWEEP_MIN_INTERVAL_MS): boolean {
  return last === null || now - last >= interval;
}

/** Runs the sweep at most once per interval per browser session. Failures are ignored on purpose. */
export function useRenewalNotificationSweep(): void {
  useEffect(() => {
    const now = Date.now();
    if (!shouldRunSweep(now, lastRunAt)) return;
    lastRunAt = now;
    rpc<number>('ins_renewal_notification_sweep').catch(() => {
      // A failed sweep must never disturb the screen; allow a retry on the next visit.
      lastRunAt = null;
    });
  }, []);
}
