import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../test/renderGuarded';
import RequireFinanceTeam from './RequireFinanceTeam';

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

describe('RequireFinanceTeam', () => {
  it('shows a spinner while auth is still loading, without calling can_access_finance yet', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: true });

    renderGuarded(<RequireFinanceTeam />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('denies access with no session', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: false });

    renderGuarded(<RequireFinanceTeam />);

    expect(screen.getByText('Not available to you')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('renders the route when can_access_finance returns true (covers either finance_team_members OR PO-approver access)', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: true, error: null });

    renderGuarded(<RequireFinanceTeam />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('can_access_finance');
  });

  it('denies access when can_access_finance returns false', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: false, error: null });

    renderGuarded(<RequireFinanceTeam />);

    await waitFor(() =>
      expect(screen.getByText(/don't have finance access/i)).toBeInTheDocument()
    );
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
  });

  it('denies access when can_access_finance errors', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });

    renderGuarded(<RequireFinanceTeam />);

    await waitFor(() =>
      expect(screen.getByText(/don't have finance access/i)).toBeInTheDocument()
    );
  });

  // A failed check and a real "no" both stay closed, but they are different
  // problems and the desk should not read a network blip as "you lost your
  // finance role".
  it('says the access check failed, and why, when the RPC errors', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });

    renderGuarded(<RequireFinanceTeam />);

    await waitFor(() =>
      expect(screen.getByText(/Checking your access failed/)).toBeInTheDocument()
    );
    expect(screen.getByText(/boom/)).toBeInTheDocument();
    expect(screen.getByText(/Reload to try again/)).toBeInTheDocument();
  });

  it('does not claim a failed check when the RPC answered false', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: false, error: null });

    renderGuarded(<RequireFinanceTeam />);

    await waitFor(() =>
      expect(screen.getByText(/don't have finance access/i)).toBeInTheDocument()
    );
    expect(screen.queryByText(/Checking your access failed/)).not.toBeInTheDocument();
  });
});
