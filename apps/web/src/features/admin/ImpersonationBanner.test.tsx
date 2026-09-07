import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import ImpersonationBanner from './ImpersonationBanner';

// Mounted app-wide in TopNav. get_my_tenant_id() already resolves to the
// impersonated tenant server-side for every RLS check, so this banner is
// purely a "you are not looking at your own data" signal + an exit hatch --
// it isn't what makes impersonation work. Worth locking down anyway: it's
// the only client-side indicator a platform admin has that they're acting
// on someone else's tenant, and the exit flow does a real navigation.

const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: [string, ...unknown[]]) => mockRpc(...args),
  },
}));

const ACTIVE = { tenant_id: 't1', tenant_name: 'Acme Ltd' };

// jsdom doesn't implement real navigation, so window.location.href = '...'
// logs a "not implemented" error rather than doing anything observable.
// Swap in a plain writable object so the exit flow's redirect is
// assertable like any other piece of state.
const originalLocation = window.location;

beforeEach(() => {
  mockRpc.mockReset();
  Object.defineProperty(window, 'location', {
    writable: true,
    value: { ...originalLocation, href: '' },
  });
});

afterEach(() => {
  Object.defineProperty(window, 'location', { writable: true, value: originalLocation });
});

describe('ImpersonationBanner', () => {
  it('renders nothing while the initial check is loading', () => {
    mockRpc.mockReturnValue(new Promise(() => {})); // never resolves

    const { container } = render(<ImpersonationBanner />);

    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when there is no active impersonation', async () => {
    mockRpc.mockResolvedValue({ data: null, error: null });

    const { container } = render(<ImpersonationBanner />);

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('get_active_impersonation'));
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when the RPC errors, rather than showing a stale or broken banner', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });

    const { container } = render(<ImpersonationBanner />);

    await waitFor(() => expect(mockRpc).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when the RPC returns an empty array', async () => {
    mockRpc.mockResolvedValue({ data: [], error: null });

    const { container } = render(<ImpersonationBanner />);

    await waitFor(() => expect(mockRpc).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
  });

  it('shows the tenant name when the RPC returns a single row object', async () => {
    mockRpc.mockResolvedValue({ data: ACTIVE, error: null });

    render(<ImpersonationBanner />);

    expect(await screen.findByText('Acme Ltd')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /exit/i })).toBeInTheDocument();
  });

  it('shows the tenant name when the RPC returns an array-wrapped row', async () => {
    mockRpc.mockResolvedValue({ data: [ACTIVE], error: null });

    render(<ImpersonationBanner />);

    expect(await screen.findByText('Acme Ltd')).toBeInTheDocument();
  });

  it('ends the impersonation session and redirects to the companies console on Exit', async () => {
    mockRpc.mockImplementation((fnName: string) => {
      if (fnName === 'get_active_impersonation') {
        return Promise.resolve({ data: ACTIVE, error: null });
      }
      return Promise.resolve({ data: null, error: null }); // end_impersonation
    });
    const user = userEvent.setup();

    render(<ImpersonationBanner />);
    await screen.findByText('Acme Ltd');

    await user.click(screen.getByRole('button', { name: /exit/i }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('end_impersonation'));
    // Full reload rather than in-app routing, so every screen re-fetches
    // under the real tenant context instead of reconciling stale state.
    expect(window.location.href).toBe('/admin/companies');
  });
});