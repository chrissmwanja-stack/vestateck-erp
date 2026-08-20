import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ProposalStatusesAdmin from './ProposalStatusesAdmin';
import { mockSupabaseTable } from '../../../../../test/lookupAdminHarness';

// Same enum-status shape as LeadStatusesAdmin, on bd_proposal_statuses,
// but an 8-entry seed set instead of 6 -- worth pinning the exact
// workflow order since ProposalApprovals filters on
// 'pending_approval'/'in_review' by name, and a re-ordering or renamed
// enum here would silently break that filter.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const STATUS_A = {
  id: 'ps1',
  tenant_id: 't1',
  status: 'draft',
  label: 'Draft',
  color: '#bdbdbd',
  order_index: 0,
  is_active: true,
};

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: {} } } });
  vi.restoreAllMocks();
});

describe('ProposalStatusesAdmin', () => {
  it('seeds all 8 statuses in workflow order against bd_proposal_statuses', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_proposal_statuses', { rows: [] });

    render(<ProposalStatusesAdmin />);
    await waitFor(() => expect(screen.getByText(/No statuses. Seed defaults/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Seed 8 Statuses' }));

    await waitFor(() => expect(calls.inserts).toHaveLength(8));
    expect(calls.inserts.map((i: any) => i.status)).toEqual([
      'draft',
      'in_review',
      'pending_approval',
      'approved',
      'sent',
      'accepted',
      'rejected',
      'expired',
    ]);
    // order_index should match array position, since ProposalApprovals
    // and any status-tracker UI relies on this for left-to-right order
    expect(calls.inserts.map((i: any) => i.order_index)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
  });

  it('lists a status row with its enum and label', async () => {
    mockSupabaseTable(mockFrom, 'bd_proposal_statuses', { rows: [STATUS_A] });

    render(<ProposalStatusesAdmin />);

    await waitFor(() => expect(screen.getByText('draft')).toBeInTheDocument());
    expect(screen.getByText('Draft')).toBeInTheDocument();
  });

  it('changing the status dropdown updates label and color to match the new enum', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_proposal_statuses', { rows: [STATUS_A] });

    render(<ProposalStatusesAdmin />);
    await waitFor(() => expect(screen.getByText('Draft')).toBeInTheDocument());

    const row = screen.getByText('draft').closest('tr') as HTMLElement;
    await user.click(within(row).getAllByRole('button')[0]); // Edit

    await user.click(screen.getByLabelText('Status Enum'));
    await user.click(await screen.findByRole('option', { name: 'Accepted (accepted)' }));
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() =>
      expect(calls.updates).toEqual([
        {
          payload: { status: 'accepted', label: 'Accepted', color: '#4caf50', order_index: 0, is_active: true },
          id: 'ps1',
        },
      ]),
    );
  });

  it('a failed delete alerts with the raw error message (no FK-specific copy here)', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    mockSupabaseTable(mockFrom, 'bd_proposal_statuses', {
      rows: [STATUS_A],
      deleteError: { message: 'in use by 3 proposals' },
    });

    render(<ProposalStatusesAdmin />);
    await waitFor(() => expect(screen.getByText('Draft')).toBeInTheDocument());

    const row = screen.getByText('draft').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]);

    await waitFor(() => expect(alertSpy).toHaveBeenCalledWith('in use by 3 proposals'));
    expect(screen.getByText('Draft')).toBeInTheDocument();
  });
});
