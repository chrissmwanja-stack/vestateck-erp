import { useEffect, useRef } from 'react';

const ACTIVITY_EVENTS: (keyof WindowEventMap)[] = ['mousemove', 'keydown', 'mousedown', 'touchstart', 'scroll'];
const CHECK_INTERVAL_MS = 30_000;

// Tracks activity in a ref (not state) so listeners don't cause re-renders
// on every mouse move. Checks on a fixed interval instead of scheduling a
// fresh timer on every event, which is simpler to reason about and cheap
// enough at a 30s cadence.
export function useIdleTimeout(timeoutMinutes: number, enabled: boolean, onTimeout: () => void) {
  const lastActivityRef = useRef(Date.now());
  const onTimeoutRef = useRef(onTimeout);
  onTimeoutRef.current = onTimeout;

  useEffect(() => {
    if (!enabled || timeoutMinutes <= 0) return;

    const markActive = () => {
      lastActivityRef.current = Date.now();
    };
    markActive();

    ACTIVITY_EVENTS.forEach((evt) => window.addEventListener(evt, markActive, { passive: true }));

    const interval = window.setInterval(() => {
      if (Date.now() - lastActivityRef.current >= timeoutMinutes * 60_000) {
        onTimeoutRef.current();
      }
    }, CHECK_INTERVAL_MS);

    return () => {
      ACTIVITY_EVENTS.forEach((evt) => window.removeEventListener(evt, markActive));
      window.clearInterval(interval);
    };
  }, [enabled, timeoutMinutes]);
}