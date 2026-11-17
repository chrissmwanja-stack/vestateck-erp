import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { AuthProvider, useAuth } from './authContext';

vi.mock('./supabaseClient', () => ({
  supabase: {
    auth: {
      getSession: () => mockGetSession(),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      signOut: async () => {},
    },
    // AuthProvider's idle-timeout path reads security settings via RPC.
    rpc: async () => ({ data: null, error: null }),
  },
}));
vi.mock('../hooks/useSecuritySettings', () => ({
  useSecuritySettings: () => ({ sessionTimeoutMinutes: 30 }),
}));

const mockGetSession = vi.fn();

function Probe() {
  const { session, loading } = useAuth();
  return <div>{loading ? 'loading' : session ? 'signed-in' : 'anonymous'}</div>;
}

// Braces matter: `() => mockGetSession.mockReset()` returns the mock, and Vitest
// treats a function returned from beforeEach as a teardown hook, so it calls the
// mock a second time after the test.
beforeEach(() => {
  mockGetSession.mockReset();
});

describe('AuthProvider session bootstrap', () => {
  // Without this, a rejected getSession leaves `loading` true and every
  // guarded route spins forever with no way out.
  it('stops loading when getSession rejects, instead of spinning forever', async () => {
    mockGetSession.mockImplementation(() =>
      Promise.resolve().then(() => {
        throw new Error('network down');
      })
    );
    render(<AuthProvider><Probe /></AuthProvider>);

    await waitFor(() => expect(screen.getByText('anonymous')).toBeInTheDocument());
  });

  it('finishes loading and reports the session', async () => {
    mockGetSession.mockResolvedValue({ data: { session: { user: { id: 'u1' } } } });
    render(<AuthProvider><Probe /></AuthProvider>);
    await waitFor(() => expect(screen.getByText('signed-in')).toBeInTheDocument());
  });

});
