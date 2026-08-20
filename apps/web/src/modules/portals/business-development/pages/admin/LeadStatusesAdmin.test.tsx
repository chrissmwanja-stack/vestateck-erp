import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import LeadStatusesAdmin from './LeadStatusesAdmin';
import { mockSupabaseTable } from '../../../../../test/lookupAdminHarness';

// Enum-backed status lookup on bd_lead_statuses -- unlike the plain
// name/description admin pages, the "Label" field here has a fallback
// (label.trim() || status) so an all-whitespace label can never save as
// blank, and there's a seed-defaults bulk-insert button in the empty
// state.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const STATUS_A = {
  id: 'ls1',
  tenant_id: 't1',
  status: 'new',
  label: 'New',
  color: '#90caf9',
  order_index: 0,
  is_active: true,
};

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: {} } } });
  vi.restoreAllMocks();
});

describe('LeadStatusesAdmin', () => {
  it('shows the seed-defaults empty state and bulk-inserts all 6 statuses', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_statuses', { rows: [] });

    render(<LeadStatusesAdmin />);
    await waitFor(() => expect(screen.getByText(/No statuses. Seed defaults/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Seed 6 Statuses' }));

    await waitFor(() => expect(calls.inserts).toHaveLength(6));
    expect(calls.inserts.map((i: any) => i.status)).toEqual([
      'new',
      'contacted',
      'qualified',
      'unqualified',
      'converted',
      'lost',
    ]);
  });

  it('lists a status row with its enum, label, and order', async () => {
    mockSupabaseTable(mockFrom, 'bd_lead_statuses', { rows: [STATUS_A] });

    render(<LeadStatusesAdmin />);

    await waitFor(() => expect(screen.getByText('new')).toBeInTheDocument());
    expect(screen.getByText('New')).toBeInTheDocument();
  });

  it('falls back to the enum value if the label is saved blank', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_statuses', { rows: [STATUS_A] });

    render(<LeadStatusesAdmin />);
    await waitFor(() => expect(screen.getByText('New')).toBeInTheDocument());

    const row = screen.getByText('new').closest('tr') as HTMLElement;
    await user.click(within(row).getAllByRole('button')[0]); // Edit

    const labelField = screen.getByLabelText('Label');
    await user.clear(labelField);
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() =>
      expect(calls.updates).toEqual([
        { payload: { status: 'new', label: 'new', color: '#90caf9', order_index: 0, is_active: true }, id: 'ls1' },
      ]),
    );
  });

  it('delete: a plain confirm with no FK context, still gated behind window.confirm', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_statuses', { rows: [STATUS_A] });

    render(<LeadStatusesAdmin />);
    await waitFor(() => expect(screen.getByText('New')).toBeInTheDocument());

    const row = screen.getByText('new').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]);

    await waitFor(() => expect(calls.deletes).toEqual(['ls1']));
  });
});
