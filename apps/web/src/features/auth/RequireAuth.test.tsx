import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import RequireAuth from './RequireAuth';

// First component test in the repo -- proves the jsdom + RTL setup end
// to end. RequireAuth is picked deliberately: unlike most screens (thin
// Supabase CRUD forms with little logic of their own, already exercised
// by db-shadow-replay), this is real client-side branching that gates
// every authenticated route in the app -- worth locking down with tests
// independent of the SQL side.

const mockUseAuth = vi.fn();
vi.mock('../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

// get_security_settings() is queried via .rpc(...).single() (see
// useSecuritySettings), while get_my_tenant_status() is queried via a
// plain .rpc(...).then(...) -- so the mock has to branch per function
// name; only the tenant-status shape gets awaited directly.
let securitySettingsResult: { data: unknown; error: unknown } = { data: null, error: null };
let tenantStatusResult: { data: unknown; error: unknown } = { data: null, error: null };

const mockRpc = vi.fn((fnName: string) => {
  if (fnName === 'get_security_settings') {
    return { single: () => Promise.resolve(securitySettingsResult) };
  }
  return Promise.resolve(tenantStatusResult);
});

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: [string, ...unknown[]]) => mockRpc(...args),
  },
}));

function renderRequireAuth() {
  return render(
    <MemoryRouter initialEntries={['/protected']}>
      <Routes>
        <Route path="/login" element={<div>Login page</div>} />
        <Route element={<RequireAuth />}>
          <Route path="/protected" element={<div>Protected content</div>} />
        </Route>
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  mockUseAuth.mockReset();
  mockRpc.mockClear();
  securitySettingsResult = { data: null, error: null };
  tenantStatusResult = { data: null, error: null };
});

describe('RequireAuth', () => {
  it('shows a spinner while the auth session is loading', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: true, signOut: vi.fn() });

    renderRequireAuth();

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
    // Shouldn't even attempt the tenant-status check without a session yet.
    expect(mockRpc).not.toHaveBeenCalledWith('get_my_tenant_status');
  });

  it('redirects to /login when there is no session', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: false, signOut: vi.fn() });

    renderRequireAuth();

    expect(screen.getByText('Login page')).toBeInTheDocument();
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalledWith('get_my_tenant_status');
  });

  it('renders the protected route once a session exists and the tenant is active', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false, signOut: vi.fn() });
    tenantStatusResult = { data: 'active', error: null };

    renderRequireAuth();

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('get_my_tenant_status');
  });

  it('shows a suspension notice instead of the protected route when the tenant is suspended', async () => {
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false, signOut: vi.fn() });
    tenantStatusResult = { data: 'suspended', error: null };

    renderRequireAuth();

    await waitFor(() =>
      expect(screen.getByText(/company's access has been suspended/i)).toBeInTheDocument()
    );
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /sign out/i })).toBeInTheDocument();
  });

  it('fails open to the protected route if the tenant-status RPC errors', async () => {
    // get_my_tenant_status() is designed to stay readable even for a
    // locked-out user (it deliberately bypasses get_my_tenant_id()) --
    // an RPC error here means something else went wrong, not that the
    // tenant is suspended, so this shouldn't silently lock a healthy
    // user out of the app.
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false, signOut: vi.fn() });
    tenantStatusResult = { data: null, error: { message: 'boom' } };

    renderRequireAuth();

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });
});
