import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AnnouncementBanner from './AnnouncementBanner';

// The app-wide banner: renders what get_active_announcements() returns,
// critical ones without a close control, and dismisses optimistically
// (rolling back if the RPC fails).

const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: { rpc: (...args: [string, unknown]) => mockRpc(...args) },
}));

const ROWS = [
  { id: 'c', title: 'Security notice', body: 'Rotate keys', severity: 'critical', starts_at: '', ends_at: null, dismissible: false, link_url: 'https://status.example', link_label: 'Status', is_global: true },
  { id: 'w', title: 'Maintenance', body: 'Down 02:00', severity: 'warning', starts_at: '', ends_at: null, dismissible: true, link_url: null, link_label: null, is_global: false },
];

beforeEach(() => {
  mockRpc.mockReset();
});

describe('AnnouncementBanner', () => {
  it('renders nothing when there are no announcements', async () => {
    mockRpc.mockResolvedValue({ data: [], error: null });
    const { container } = render(<AnnouncementBanner />);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('get_active_announcements'));
    expect(container.querySelector('[data-testid="announcement-banner"]')).toBeNull();
  });

  it('shows each announcement; critical has no close, company-scoped is labelled', async () => {
    mockRpc.mockResolvedValue({ data: ROWS, error: null });
    render(<AnnouncementBanner />);
    expect(await screen.findByText('Security notice')).toBeInTheDocument();
    expect(screen.getByText('Maintenance')).toBeInTheDocument();
    expect(screen.getByText(/for your company/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Status' })).toHaveAttribute('href', 'https://status.example');
    // exactly one close button (the warning); the critical one has none
    expect(screen.getAllByRole('button', { name: /close/i })).toHaveLength(1);
  });

  it('dismisses optimistically and calls dismiss_announcement', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'get_active_announcements') return Promise.resolve({ data: ROWS, error: null });
      if (fn === 'dismiss_announcement') return Promise.resolve({ data: null, error: null });
      throw new Error(fn);
    });
    const user = userEvent.setup();
    render(<AnnouncementBanner />);
    await screen.findByText('Maintenance');
    await user.click(screen.getByRole('button', { name: /close/i }));
    await waitFor(() => expect(screen.queryByText('Maintenance')).not.toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('dismiss_announcement', { p_id: 'w' });
    expect(screen.getByText('Security notice')).toBeInTheDocument();
  });

  it('puts a dismissed announcement back if the server refuses', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'get_active_announcements') return Promise.resolve({ data: ROWS, error: null });
      if (fn === 'dismiss_announcement') return Promise.resolve({ data: null, error: { message: 'nope' } });
      throw new Error(fn);
    });
    const user = userEvent.setup();
    render(<AnnouncementBanner />);
    await screen.findByText('Maintenance');
    await user.click(screen.getByRole('button', { name: /close/i }));
    await waitFor(() => expect(screen.getByText('Maintenance')).toBeInTheDocument());
  });
});
