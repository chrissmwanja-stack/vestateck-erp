import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import TenderTypesAdmin from './TenderTypesAdmin';
import { mockSupabaseTable } from '../../../../../test/lookupAdminHarness';

// Same lookup-admin shape as LeadSourcesAdmin, on bd_tender_types.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const TYPE_A = {
  id: 'tt1',
  tenant_id: 't1',
  name: 'Open Tender',
  description: null,
  is_active: true,
  created_at: '2026-01-01T00:00:00Z',
};

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: {} } } });
  vi.restoreAllMocks();
});

describe('TenderTypesAdmin', () => {
  it('shows the empty state when there are no tender types', async () => {
    mockSupabaseTable(mockFrom, 'bd_tender_types', { rows: [] });

    render(<TenderTypesAdmin />);

    await waitFor(() => expect(screen.getByText(/No types yet/)).toBeInTheDocument());
  });

  it('lists existing tender types against bd_tender_types', async () => {
    mockSupabaseTable(mockFrom, 'bd_tender_types', { rows: [TYPE_A] });

    render(<TenderTypesAdmin />);

    await waitFor(() => expect(screen.getByText('Open Tender')).toBeInTheDocument());
  });

  it('editing pre-fills the form and updates on save', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_tender_types', { rows: [TYPE_A] });

    render(<TenderTypesAdmin />);
    await waitFor(() => expect(screen.getByText('Open Tender')).toBeInTheDocument());

    const row = screen.getByText('Open Tender').closest('tr') as HTMLElement;
    await user.click(within(row).getAllByRole('button')[0]); // Edit
    expect(screen.getByDisplayValue('Open Tender')).toBeInTheDocument();

    const nameField = screen.getByLabelText('Name *');
    await user.clear(nameField);
    await user.type(nameField, 'Restricted Tender');
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() =>
      expect(calls.updates).toEqual([
        { payload: { name: 'Restricted Tender', description: null, is_active: true }, id: 'tt1' },
      ]),
    );
  });

  it('cancelling delete leaves the row and makes no delete call', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(false);
    const { calls } = mockSupabaseTable(mockFrom, 'bd_tender_types', { rows: [TYPE_A] });

    render(<TenderTypesAdmin />);
    await waitFor(() => expect(screen.getByText('Open Tender')).toBeInTheDocument());

    const row = screen.getByText('Open Tender').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]); // Delete

    expect(calls.deletes).toEqual([]);
    expect(screen.getByText('Open Tender')).toBeInTheDocument();
  });
});
