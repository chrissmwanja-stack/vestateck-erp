import { renderHook } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { useIdleTimeout } from './useIdleTimeout';

// Drives AuthProvider's session-timeout banner + forced sign-out (see
// authContext.test.tsx for that integration). Tested in isolation here
// because the timing/event-listener logic is worth locking down on its
// own: a 30s poll against a ref (not state), reset by a fixed set of
// DOM activity events, gated by `enabled` and `timeoutMinutes`.

const CHECK_INTERVAL_MS = 30_000;

describe('useIdleTimeout', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('never fires when disabled, even after a long time', () => {
    const onTimeout = vi.fn();
    renderHook(() => useIdleTimeout(1, false, onTimeout));

    vi.advanceTimersByTime(10 * 60_000);

    expect(onTimeout).not.toHaveBeenCalled();
  });

  it('never fires when timeoutMinutes is zero or negative', () => {
    const onTimeout = vi.fn();
    renderHook(() => useIdleTimeout(0, true, onTimeout));

    vi.advanceTimersByTime(10 * 60_000);

    expect(onTimeout).not.toHaveBeenCalled();
  });

  it('fires onTimeout once enough time has passed with no activity', () => {
    const onTimeout = vi.fn();
    renderHook(() => useIdleTimeout(1, true, onTimeout)); // 1 minute = 60_000ms

    // Just under the threshold: no call yet.
    vi.advanceTimersByTime(CHECK_INTERVAL_MS); // 30s, elapsed 30s
    expect(onTimeout).not.toHaveBeenCalled();

    // Crosses the 60s threshold on the next 30s poll.
    vi.advanceTimersByTime(CHECK_INTERVAL_MS); // 60s, elapsed 60s
    expect(onTimeout).toHaveBeenCalledTimes(1);
  });

  it('keeps firing on later polls if activity never resumes', () => {
    const onTimeout = vi.fn();
    renderHook(() => useIdleTimeout(1, true, onTimeout));

    vi.advanceTimersByTime(60_000);
    expect(onTimeout).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(CHECK_INTERVAL_MS);
    expect(onTimeout).toHaveBeenCalledTimes(2);
  });

  it('activity resets the idle clock and prevents the timeout', () => {
    const onTimeout = vi.fn();
    renderHook(() => useIdleTimeout(1, true, onTimeout));

    // First poll (t=30s) passes with no activity yet -- fine, budget is 60s.
    vi.advanceTimersByTime(30_000);
    // Reset right on that poll boundary (t=30s).
    window.dispatchEvent(new Event('keydown'));

    // Next poll (t=60s): only 30s of real idle time since the reset.
    vi.advanceTimersByTime(30_000);
    expect(onTimeout).not.toHaveBeenCalled();

    // Poll after that (t=90s): now a full 60s idle since the reset.
    vi.advanceTimersByTime(30_000);
    expect(onTimeout).toHaveBeenCalledTimes(1);
  });

  it.each(['mousemove', 'mousedown', 'touchstart', 'scroll'])(
    'treats "%s" as activity too',
    (eventName) => {
      const onTimeout = vi.fn();
      renderHook(() => useIdleTimeout(1, true, onTimeout));

      vi.advanceTimersByTime(45_000);
      window.dispatchEvent(new Event(eventName));
      vi.advanceTimersByTime(45_000); // would be 90s total if activity didn't count

      expect(onTimeout).not.toHaveBeenCalled();
    },
  );

  it('stops polling and drops its activity listeners on unmount', () => {
    const onTimeout = vi.fn();
    const removeSpy = vi.spyOn(window, 'removeEventListener');
    const { unmount } = renderHook(() => useIdleTimeout(1, true, onTimeout));

    unmount();
    vi.advanceTimersByTime(5 * 60_000);

    expect(onTimeout).not.toHaveBeenCalled();
    // 5 activity listeners registered in the hook should each be torn down.
    expect(removeSpy).toHaveBeenCalledTimes(5);
    removeSpy.mockRestore();
  });

  it('restarts the idle clock from zero when re-enabled', () => {
    const onTimeout = vi.fn();
    const { rerender } = renderHook(
      ({ enabled }) => useIdleTimeout(1, enabled, onTimeout),
      { initialProps: { enabled: false } },
    );

    // Time passes while disabled -- shouldn't count toward the budget.
    vi.advanceTimersByTime(50_000);
    rerender({ enabled: true });

    vi.advanceTimersByTime(30_000); // 30s since enabling
    expect(onTimeout).not.toHaveBeenCalled();

    vi.advanceTimersByTime(30_000); // 60s since enabling
    expect(onTimeout).toHaveBeenCalledTimes(1);
  });

  it('always calls the latest onTimeout callback without resetting the clock', () => {
    const firstCallback = vi.fn();
    const secondCallback = vi.fn();
    const { rerender } = renderHook(
      ({ cb }) => useIdleTimeout(1, true, cb),
      { initialProps: { cb: firstCallback } },
    );

    vi.advanceTimersByTime(45_000);
    rerender({ cb: secondCallback }); // swap the callback identity mid-flight
    vi.advanceTimersByTime(15_000); // total elapsed: 60s

    expect(firstCallback).not.toHaveBeenCalled();
    expect(secondCallback).toHaveBeenCalledTimes(1);
  });
});