import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import LeadSourcesAdmin from './LeadSourcesAdmin';
import { mockSupabaseTable } from '../../../../../test/lookupAdminHarness';

// This page sits behind RequireModule module="bd" roles={BD_ADMIN_ROLES}
// (see ../../access.ts / access.test.tsx for the route-level gate). These
// tests cover what the guard doesn't: the CRUD behavior of the page an
// admin/manager actually reaches.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const SOURCE_A = {
  id: 's1',
  tenant_id: 't1',
  name: 'Referral',
  is_active: true,
  created_at: '2026-01-01T00:00:00Z',
};

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: {} } } });
  vi.restoreAllMocks();
});

describe('LeadSourcesAdmin', () => {
  it('shows the empty state when there are no sources', async () => {
    mockSupabaseTable(mockFrom, 'bd_lead_sources', { rows: [] });

    render(<LeadSourcesAdmin />);

    await waitFor(() => expect(screen.getByText(/No lead sources yet/)).toBeInTheDocument());
  });

  it('lists existing sources with their active state', async () => {
    mockSupabaseTable(mockFrom, 'bd_lead_sources', { rows: [SOURCE_A] });

    render(<LeadSourcesAdmin />);

    await waitFor(() => expect(screen.getByText('Referral')).toBeInTheDocument());
    const row = screen.getByText('Referral').closest('tr') as HTMLElement;
    expect(within(row).getByText('Active')).toBeInTheDocument();
  });

  it('the Create button is disabled until a name is entered, then inserts and refetches', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_sources', { rows: [] });

    render(<LeadSourcesAdmin />);
    await waitFor(() => expect(screen.getByText(/No lead sources yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New Source' }));
    const createButton = screen.getByRole('button', { name: 'Create' });
    expect(createButton).toBeDisabled();

    await user.type(screen.getByLabelText('Name *'), 'Website');
    expect(createButton).toBeEnabled();
    await user.click(createButton);

    await waitFor(() => expect(calls.inserts).toEqual([{ name: 'Website', is_active: true }]));
    // dialog closes and the list is refetched after a successful save
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Create' })).not.toBeInTheDocument());
    expect(calls.selectCount).toBe(2);
  });

  it('includes tenant_id on insert when present in the session', async () => {
    const user = userEvent.setup();
    mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: { tenant_id: 'tenant-9' } } } });
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_sources', { rows: [] });

    render(<LeadSourcesAdmin />);
    await waitFor(() => expect(screen.getByText(/No lead sources yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New Source' }));
    await user.type(screen.getByLabelText('Name *'), 'Cold Call');
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() =>
      expect(calls.inserts).toEqual([{ name: 'Cold Call', is_active: true, tenant_id: 'tenant-9' }]),
    );
  });

  it('editing a row pre-fills the form and updates on save', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_sources', { rows: [SOURCE_A] });

    render(<LeadSourcesAdmin />);
    await waitFor(() => expect(screen.getByText('Referral')).toBeInTheDocument());

    const row = screen.getByText('Referral').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[0]); // Edit is the first icon button, Delete the last
    expect(screen.getByDisplayValue('Referral')).toBeInTheDocument();

    const nameField = screen.getByLabelText('Name *');
    await user.clear(nameField);
    await user.type(nameField, 'Referral Program');
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() =>
      expect(calls.updates).toEqual([
        { payload: { name: 'Referral Program', is_active: true }, id: 's1' },
      ]),
    );
  });

  it('an insert error alerts and leaves the dialog open without refetching', async () => {
    const user = userEvent.setup();
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_sources', {
      rows: [],
      insertError: { message: 'duplicate key value' },
    });

    render(<LeadSourcesAdmin />);
    await waitFor(() => expect(screen.getByText(/No lead sources yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New Source' }));
    await user.type(screen.getByLabelText('Name *'), 'Website');
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => expect(alertSpy).toHaveBeenCalledWith(expect.stringContaining('duplicate key value')));
    // dialog stays open, no refetch happened
    expect(screen.getByRole('button', { name: 'Create' })).toBeInTheDocument();
    expect(calls.selectCount).toBe(1);
  });

  it('toggling the active switch updates is_active and refetches', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_sources', { rows: [SOURCE_A] });

    render(<LeadSourcesAdmin />);
    await waitFor(() => expect(screen.getByText('Referral')).toBeInTheDocument());

    const row = screen.getByText('Referral').closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('checkbox'));

    await waitFor(() =>
      expect(calls.updates).toEqual([{ payload: { is_active: false }, id: 's1' }]),
    );
    expect(calls.selectCount).toBe(2);
  });

  it('delete asks for confirmation and does nothing if cancelled', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(false);
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_sources', { rows: [SOURCE_A] });

    render(<LeadSourcesAdmin />);
    await waitFor(() => expect(screen.getByText('Referral')).toBeInTheDocument());

    const row = screen.getByText('Referral').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]); // Delete is the last icon button

    expect(calls.deletes).toEqual([]);
    expect(screen.getByText('Referral')).toBeInTheDocument();
  });

  it('a failed delete (FK constraint) alerts and keeps the row', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    const { calls } = mockSupabaseTable(mockFrom, 'bd_lead_sources', {
      rows: [SOURCE_A],
      deleteError: { message: 'violates foreign key constraint' },
    });

    render(<LeadSourcesAdmin />);
    await waitFor(() => expect(screen.getByText('Referral')).toBeInTheDocument());

    const row = screen.getByText('Referral').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]);

    await waitFor(() =>
      expect(alertSpy).toHaveBeenCalledWith(expect.stringContaining('violates foreign key constraint')),
    );
    expect(calls.deletes).toEqual(['s1']);
    expect(calls.selectCount).toBe(1); // no refetch on failure
    expect(screen.getByText('Referral')).toBeInTheDocument();
  });
});
