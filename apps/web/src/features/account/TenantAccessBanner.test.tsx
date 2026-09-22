import { render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import TenantAccessBanner, { trialDaysLeft } from './TenantAccessBanner';

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

describe('trialDaysLeft', () => {
  const now = new Date('2026-09-22T12:00:00Z');
  it('is null unless trialing with an end date within 7 days', () => {
    expect(trialDaysLeft({ subscription_status: 'active', trial_ends_at: '2026-09-23T00:00:00Z' }, now)).toBeNull();
    expect(trialDaysLeft({ subscription_status: 'trialing', trial_ends_at: null }, now)).toBeNull();
    expect(trialDaysLeft({ subscription_status: 'trialing', trial_ends_at: '2026-10-22T00:00:00Z' }, now)).toBeNull();
  });
  it('counts down and goes to zero/negative once over', () => {
    expect(trialDaysLeft({ subscription_status: 'trialing', trial_ends_at: '2026-09-25T00:00:00Z' }, now)).toBe(3);
    expect(trialDaysLeft({ subscription_status: 'trialing', trial_ends_at: '2026-09-20T00:00:00Z' }, now)).toBe(-2);
  });
});

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

  it('shows a trial heads-up in the final week', async () => {
    const inFiveDays = new Date(Date.now() + 5 * 86_400_000).toISOString();
    mockRpc.mockResolvedValue({
      data: { ...BASE, plan: 'trial', subscription_status: 'trialing', trial_ends_at: inFiveDays },
      error: null,
    });
    render(<TenantAccessBanner />);
    expect(await screen.findByTestId('tenant-trial-banner')).toHaveTextContent('Your trial ends in 5 days.');
  });

  it('stays silent when the RPC errors (never blocks the app)', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const { container } = render(<TenantAccessBanner />);
    await waitFor(() => expect(mockRpc).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
  });
});
