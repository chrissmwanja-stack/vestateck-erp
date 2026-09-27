import { render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import TenantAccessBanner from './TenantAccessBanner';

// The customer-side half of read-only mode (20260922180000). The server
// refuses writes regardless; this banner is what tells the user *why*
// before they hit the error.

const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

const BASE = {
  tenant_id: 't1',
  name: 'Acme Ltd',
  status: 'active',
  read_only: false,
  read_only_reason: null,
  plan: 'standard',
  subscription_status: 'active',
  trial_ends_at: null,
};

beforeEach(() => mockRpc.mockReset());

describe('TenantAccessBanner', () => {
  it('renders nothing for a healthy, paid company', async () => {
    mockRpc.mockResolvedValue({ data: BASE, error: null });
    const { container } = render(<TenantAccessBanner />);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('get_my_tenant_access'));
    expect(container).toBeEmptyDOMElement();
  });

  it('shows the read-only warning with the operator reason', async () => {
    mockRpc.mockResolvedValue({
      data: { ...BASE, read_only: true, read_only_reason: 'Subscription payment overdue' },
      error: null,
    });
    render(<TenantAccessBanner />);
    const banner = await screen.findByTestId('tenant-read-only-banner');
    expect(banner).toHaveTextContent('Acme Ltd is in read-only mode.');
    expect(banner).toHaveTextContent('Subscription payment overdue');
  });

  it('stays silent for a trialing/trial-ending tenant (no self-serve trial UI for customers)', async () => {
    const inFiveDays = new Date(Date.now() + 5 * 86_400_000).toISOString();
    mockRpc.mockResolvedValue({
      data: { ...BASE, plan: 'trial', subscription_status: 'trialing', trial_ends_at: inFiveDays },
      error: null,
    });
    const { container } = render(<TenantAccessBanner />);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('get_my_tenant_access'));
    expect(container).toBeEmptyDOMElement();
  });

  it('stays silent when the RPC errors (never blocks the app)', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const { container } = render(<TenantAccessBanner />);
    await waitFor(() => expect(mockRpc).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
  });
});
