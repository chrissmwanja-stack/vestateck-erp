import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../test/renderGuarded';
import RequireModule from './RequireModule';

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

describe('RequireModule', () => {
  it('shows a spinner while auth is still loading, without calling has_module_role yet', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: true });

    renderGuarded(<RequireModule module="hr" />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('denies access with no session, without calling has_module_role', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: false });

    renderGuarded(<RequireModule module="hr" />);

    expect(screen.getByText('Not available to you')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('calls has_module_role with the module and the default roles, and renders the route when allowed', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: true, error: null });

    renderGuarded(<RequireModule module="hr" />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('has_module_role', {
      p_module: 'hr',
      p_roles: ['admin', 'manager', 'member'],
    });
  });

  it('passes custom roles through to has_module_role instead of the default set', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: true, error: null });

    renderGuarded(<RequireModule module="pmo" roles={['admin']} />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('has_module_role', {
      p_module: 'pmo',
      p_roles: ['admin'],
    });
  });

  it('denies access when has_module_role returns false', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: false, error: null });

    renderGuarded(<RequireModule module="hr" />);

    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
  });

  it('denies access when has_module_role errors', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });

    renderGuarded(<RequireModule module="hr" />);

    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
  });
});
