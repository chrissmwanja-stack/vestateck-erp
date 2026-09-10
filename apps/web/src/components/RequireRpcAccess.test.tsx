import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../test/renderGuarded';
import RequireRpcAccess from './RequireRpcAccess';

const mockUseAuth = vi.fn();
vi.mock('../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const mockRpc = vi.fn();
vi.mock('../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

beforeEach(() => {
  mockUseAuth.mockReset();
  mockRpc.mockReset();
});

describe('RequireRpcAccess', () => {
  it('shows a spinner while auth is still loading, without calling the rpc yet', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: true });

    renderGuarded(<RequireRpcAccess rpc="can_view_payroll_approvals" />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('denies access with no session', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: false });

    renderGuarded(<RequireRpcAccess rpc="can_view_payroll_approvals" />);

    expect(screen.getByText('Not available to you')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('renders the route when the named rpc returns true (covers either HR staff OR a designated payroll approver)', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: true, error: null });

    renderGuarded(<RequireRpcAccess rpc="can_view_payroll_approvals" />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('can_view_payroll_approvals');
  });

  it('denies access when the named rpc returns false', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: false, error: null });

    renderGuarded(<RequireRpcAccess rpc="can_view_payroll_approvals" />);

    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
  });

  it('denies access when the rpc errors', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });

    renderGuarded(<RequireRpcAccess rpc="can_view_payroll_approvals" />);

    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
  });

  it('re-runs the check when the rpc prop itself changes', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: true, error: null });

    renderGuarded(<RequireRpcAccess rpc="can_view_payroll_approvals" />);

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('can_view_payroll_approvals'));
  });
});
