import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../test/renderGuarded';
import RequirePlatformAdmin from './RequirePlatformAdmin';

const mockUseAuth = vi.fn();
vi.mock('../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

// Unlike RequireModule/RequireFinanceTeam (a single .rpc() call), this
// guard reads app_users directly via the query builder chain
// (.from().select().eq().maybeSingle()), so the mock needs to support
// that chain rather than a single function call.
const mockMaybeSingle = vi.fn();
const mockEq = vi.fn(() => ({ maybeSingle: mockMaybeSingle }));
const mockSelect = vi.fn(() => ({ eq: mockEq }));
const mockFrom = vi.fn((_table: string) => ({ select: mockSelect }));
vi.mock('../lib/supabaseClient', () => ({
  supabase: {
    from: (table: string) => mockFrom(table),
  },
}));

beforeEach(() => {
  mockUseAuth.mockReset();
  mockFrom.mockClear();
  mockSelect.mockClear();
  mockEq.mockClear();
  mockMaybeSingle.mockReset();
});

describe('RequirePlatformAdmin', () => {
  it('shows a spinner while auth is still loading, without querying app_users yet', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: true });

    renderGuarded(<RequirePlatformAdmin />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(mockFrom).not.toHaveBeenCalled();
  });

  it('denies access with no session', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: false });

    renderGuarded(<RequirePlatformAdmin />);

    expect(screen.getByText('Platform admin only')).toBeInTheDocument();
    expect(mockFrom).not.toHaveBeenCalled();
  });

  it('queries app_users.is_platform_admin for the current user and renders the route when true', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockMaybeSingle.mockResolvedValue({ data: { is_platform_admin: true }, error: null });

    renderGuarded(<RequirePlatformAdmin />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
    expect(mockFrom).toHaveBeenCalledWith('app_users');
    expect(mockSelect).toHaveBeenCalledWith('is_platform_admin');
    expect(mockEq).toHaveBeenCalledWith('id', 'u1');
  });

  it('denies access when is_platform_admin is false', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockMaybeSingle.mockResolvedValue({ data: { is_platform_admin: false }, error: null });

    renderGuarded(<RequirePlatformAdmin />);

    await waitFor(() => expect(screen.getByText('Platform admin only')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: /go to my workspace/i })).toBeInTheDocument();
  });

  it('denies access when the app_users row is missing (maybeSingle returns null data)', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockMaybeSingle.mockResolvedValue({ data: null, error: null });

    renderGuarded(<RequirePlatformAdmin />);

    await waitFor(() => expect(screen.getByText('Platform admin only')).toBeInTheDocument());
  });

  it('denies access when the query errors', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockMaybeSingle.mockResolvedValue({ data: null, error: { message: 'boom' } });

    renderGuarded(<RequirePlatformAdmin />);

    await waitFor(() => expect(screen.getByText('Platform admin only')).toBeInTheDocument());
  });
});