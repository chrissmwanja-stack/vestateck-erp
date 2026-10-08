import { renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { REGISTRY_FIXTURE } from '../test/moduleRegistryMock';
import { resetModuleRegistryCache, useModuleRegistry } from './useModuleRegistry';

// Query chain used by the hook: from().select().eq().order()
const mockOrder = vi.fn();
const mockEq = vi.fn(() => ({ order: mockOrder }));
const mockSelect = vi.fn(() => ({ eq: mockEq }));
const mockFrom = vi.fn(() => ({ select: mockSelect }));
vi.mock('./supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => (mockFrom as (...a: unknown[]) => unknown)(...args) },
}));

beforeEach(() => {
  resetModuleRegistryCache();
  mockFrom.mockClear();
  mockOrder.mockReset();
});

describe('useModuleRegistry', () => {
  it('loads active modules, exposes registry names, and excludes non-entitled keys from entitledModules', async () => {
    mockOrder.mockResolvedValue({ data: REGISTRY_FIXTURE, error: null });

    const { result } = renderHook(() => useModuleRegistry());
    expect(result.current.loading).toBe(true);
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(mockFrom).toHaveBeenCalledWith('platform_modules');
    expect(mockEq).toHaveBeenCalledWith('is_active', true);
    expect(result.current.modules).toHaveLength(9);
    expect(result.current.entitledModules.map((m) => m.key)).not.toContain('finance');
    expect(result.current.entitledModules).toHaveLength(8);
    expect(result.current.labelFor('hr')).toBe('Human Resources');
    expect(result.current.labelFor('not_a_module')).toBe('not_a_module');
  });

  it('fetches once and serves later mounts from the cache', async () => {
    mockOrder.mockResolvedValue({ data: REGISTRY_FIXTURE, error: null });

    const first = renderHook(() => useModuleRegistry());
    await waitFor(() => expect(first.result.current.loading).toBe(false));
    const second = renderHook(() => useModuleRegistry());

    expect(second.result.current.modules).toHaveLength(9);
    expect(second.result.current.loading).toBe(false);
    expect(mockFrom).toHaveBeenCalledTimes(1);
  });

  it('reports an error, leaves the list empty, and retries on the next mount', async () => {
    mockOrder.mockResolvedValueOnce({ data: null, error: { message: 'boom' } });

    const first = renderHook(() => useModuleRegistry());
    await waitFor(() => expect(first.result.current.error).toBe('boom'));
    expect(first.result.current.modules).toEqual([]);

    mockOrder.mockResolvedValueOnce({ data: REGISTRY_FIXTURE, error: null });
    const second = renderHook(() => useModuleRegistry());
    await waitFor(() => expect(second.result.current.modules).toHaveLength(9));
    expect(second.result.current.error).toBeNull();
  });
});
