import { describe, expect, it, vi, beforeEach } from 'vitest';
import { resolveTenantId } from './ResolveTenantId';

const mockFrom = vi.fn();
vi.mock('./supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

function mockAppUsersSingle(result: { data: unknown; error: unknown }) {
  mockFrom.mockImplementation((table: string) => {
    if (table !== 'app_users') throw new Error(`resolveTenantId.test: unexpected table "${table}"`);
    return { select: () => ({ eq: () => ({ single: () => Promise.resolve(result) }) }) };
  });
}

beforeEach(() => {
  mockFrom.mockReset();
});

describe('resolveTenantId', () => {
  it('returns an error, and never queries app_users, when there is no session', async () => {
    const result = await resolveTenantId(null);
    expect(result).toEqual({ error: 'Could not determine your session. Please refresh and try again.' });
    expect(mockFrom).not.toHaveBeenCalled();
  });

  it('returns the real tenant_id for a valid session', async () => {
    mockAppUsersSingle({ data: { tenant_id: 't1' }, error: null });
    const session = { user: { id: 'u1' } } as any;

    const result = await resolveTenantId(session);

    expect(result).toEqual({ tenantId: 't1' });
    expect(mockFrom).toHaveBeenCalledWith('app_users');
  });

  it('returns an error when the app_users lookup errors', async () => {
    mockAppUsersSingle({ data: null, error: { message: 'boom' } });
    const session = { user: { id: 'u1' } } as any;

    const result = await resolveTenantId(session);

    expect(result).toEqual({ error: 'Could not determine your organization. Please refresh and try again.' });
  });

  it('returns an error when app_users has no row or a null tenant_id', async () => {
    mockAppUsersSingle({ data: { tenant_id: null }, error: null });
    const session = { user: { id: 'u1' } } as any;

    const result = await resolveTenantId(session);

    expect(result).toEqual({ error: 'Could not determine your organization. Please refresh and try again.' });
  });
});