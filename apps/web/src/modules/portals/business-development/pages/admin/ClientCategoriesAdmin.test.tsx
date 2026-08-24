import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ClientCategoriesAdmin from './ClientCategoriesAdmin';
import { mockSupabaseTable } from '../../../../../test/lookupAdminHarness';

// Same shape as LeadSourcesAdmin (see its test for the fuller writeup of
// the pattern this whole admin-page family shares) but on
// bd_client_categories, with a description field and no active-toggle
// switch in the table -- only in the dialog.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const CATEGORY_A = {
  id: 'c1',
  tenant_id: 't1',
  name: 'Government',
  description: 'Ministries and agencies',
  is_active: true,
  created_at: '2026-01-01T00:00:00Z',
};

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: {} } } });
  vi.restoreAllMocks();
});

describe('ClientCategoriesAdmin', () => {
  it('shows the empty state when there are no categories', async () => {
    mockSupabaseTable(mockFrom, 'bd_client_categories', { rows: [] });

    render(<ClientCategoriesAdmin />);

    await waitFor(() => expect(screen.getByText(/No categories yet/)).toBeInTheDocument());
  });

  it('lists categories with a "-" fallback for a blank description', async () => {
    mockSupabaseTable(mockFrom, 'bd_client_categories', {
      rows: [{ ...CATEGORY_A, id: 'c2', name: 'NGO', description: null }],
    });

    render(<ClientCategoriesAdmin />);

    await waitFor(() => expect(screen.getByText('NGO')).toBeInTheDocument());
    expect(screen.getByText('-')).toBeInTheDocument();
  });

  it('creates a category with a trimmed, nulled-out-if-blank description', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_client_categories', { rows: [] });

    render(<ClientCategoriesAdmin />);
    await waitFor(() => expect(screen.getByText(/No categories yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New Category' }));
    await user.type(screen.getByLabelText('Name *'), '  Private Sector  ');
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() =>
      expect(calls.inserts).toEqual([{ name: 'Private Sector', description: null, is_active: true, tenant_id: 't1' }]),
    );
  });

  it('an update error alerts and keeps the dialog open', async () => {
    const user = userEvent.setup();
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    const { calls } = mockSupabaseTable(mockFrom, 'bd_client_categories', {
      rows: [CATEGORY_A],
      updateError: { message: 'permission denied' },
    });

    render(<ClientCategoriesAdmin />);
    await waitFor(() => expect(screen.getByText('Government')).toBeInTheDocument());

    const row = screen.getByText('Government').closest('tr') as HTMLElement;
    await user.click(within(row).getAllByRole('button')[0]); // Edit
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() => expect(alertSpy).toHaveBeenCalledWith('permission denied'));
    expect(calls.updates).toHaveLength(1);
    expect(calls.selectCount).toBe(1); // no refetch after a failed update
  });

  it('delete: confirms, deletes, and refetches', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { calls } = mockSupabaseTable(mockFrom, 'bd_client_categories', { rows: [CATEGORY_A] });

    render(<ClientCategoriesAdmin />);
    await waitFor(() => expect(screen.getByText('Government')).toBeInTheDocument());

    const row = screen.getByText('Government').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]); // Delete

    await waitFor(() => expect(calls.deletes).toEqual(['c1']));
    expect(calls.selectCount).toBe(2);
  });
});
