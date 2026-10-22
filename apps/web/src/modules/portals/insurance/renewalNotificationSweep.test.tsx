import { renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const rpcMock = vi.fn();
vi.mock('./db', () => ({ rpc: (...args: unknown[]) => rpcMock(...args) }));

// The throttle lives at module level, so each test loads a fresh copy.
async function load() {
  vi.resetModules();
  return import('./renewalNotificationSweep');
}

beforeEach(() => {
  rpcMock.mockReset();
  rpcMock.mockResolvedValue(0);
});

describe('shouldRunSweep', () => {
  it('runs when it has never run', async () => {
    const { shouldRunSweep } = await load();
    expect(shouldRunSweep(1_000, null)).toBe(true);
  });
  it('waits until the interval has passed', async () => {
    const { shouldRunSweep, SWEEP_MIN_INTERVAL_MS } = await load();
    expect(shouldRunSweep(1_000 + SWEEP_MIN_INTERVAL_MS - 1, 1_000)).toBe(false);
    expect(shouldRunSweep(1_000 + SWEEP_MIN_INTERVAL_MS, 1_000)).toBe(true);
  });
  it('honours a custom interval', async () => {
    const { shouldRunSweep } = await load();
    expect(shouldRunSweep(5_000, 1_000, 3_000)).toBe(true);
    expect(shouldRunSweep(3_999, 1_000, 3_000)).toBe(false);
  });
});

describe('useRenewalNotificationSweep', () => {
  it('calls the sweep once, then not again within the interval', async () => {
    const { useRenewalNotificationSweep } = await load();
    renderHook(() => useRenewalNotificationSweep());
    renderHook(() => useRenewalNotificationSweep());
    expect(rpcMock).toHaveBeenCalledTimes(1);
    expect(rpcMock).toHaveBeenCalledWith('ins_renewal_notification_sweep');
  });

  it('swallows a failure and lets the next visit retry', async () => {
    const { useRenewalNotificationSweep } = await load();
    rpcMock.mockRejectedValueOnce(new Error('boom'));
    renderHook(() => useRenewalNotificationSweep());
    await vi.waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1));
    await Promise.resolve();
    renderHook(() => useRenewalNotificationSweep());
    expect(rpcMock).toHaveBeenCalledTimes(2);
  });
});
