import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ProposalTypesAdmin from './ProposalTypesAdmin';
import { mockSupabaseTable } from '../../../../../test/lookupAdminHarness';

// Same lookup-admin shape as LeadSourcesAdmin, on bd_proposal_types.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const TYPE_A = {
  id: 'pt1',
  tenant_id: 't1',
  name: 'Technical',
  description: null,
  is_active: true,
  created_at: '2026-01-01T00:00:00Z',
};

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: { tenant_id: 'tenant-5' } } } });
  vi.restoreAllMocks();
});

describe('ProposalTypesAdmin', () => {
  it('shows the empty state when there are no types', async () => {
    mockSupabaseTable(mockFrom, 'bd_proposal_types', { rows: [] });

    render(<ProposalTypesAdmin />);

    await waitFor(() => expect(screen.getByText(/No types yet/)).toBeInTheDocument());
  });

  it('creates a type against bd_proposal_types with the resolved tenant_id', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_proposal_types', { rows: [] });

    render(<ProposalTypesAdmin />);
    await waitFor(() => expect(screen.getByText(/No types yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New Type' }));
    await user.type(screen.getByLabelText('Name *'), 'BOQ');
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() =>
      expect(calls.inserts).toEqual([
        { name: 'BOQ', description: null, is_active: true, tenant_id: 't1' },
      ]),
    );
  });

  it('a delete error alerts with the FK message and keeps the row', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    mockSupabaseTable(mockFrom, 'bd_proposal_types', {
      rows: [TYPE_A],
      deleteError: { message: 'violates foreign key constraint' },
    });

    render(<ProposalTypesAdmin />);
    await waitFor(() => expect(screen.getByText('Technical')).toBeInTheDocument());

    const row = screen.getByText('Technical').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]);

    await waitFor(() =>
      expect(alertSpy).toHaveBeenCalledWith(expect.stringContaining('violates foreign key constraint')),
    );
    expect(screen.getByText('Technical')).toBeInTheDocument();
  });
});
