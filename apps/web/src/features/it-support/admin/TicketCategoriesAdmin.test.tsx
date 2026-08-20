import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import TicketCategoriesAdmin from './TicketCategoriesAdmin';
import { mockSupabaseRpc } from '../../../test/rpcHarness';

// This page sits behind RequireModule module="it" roles={IT_ADMIN_ROLES}
// (see ../access.ts / ../access.test.tsx for the route-level gate). These
// tests cover what the guard doesn't: the CRUD behavior of the page an
// admin/manager actually reaches.
//
// Unlike the BD lookup admin pages (a single supabase.from() table),
// this page goes through the IT admin RPC layer added in
// 20260820120000_it_support_admin_tier_write_rpcs.sql
// (create_ticket_category / update_ticket_category), gated server-side
// by is_it_support_admin(). Note the page's own New/Rename/Deactivate
// controls are shown based on the *flat* is_it_support() RPC result,
// not an admin-tier check -- harmless in production since the route
// itself is already admin/manager-only, but it does mean those controls
// disappear whenever is_it_support resolves false, independent of
// what's in the categories list. Pinned down here rather than assumed.

const mockRpc = vi.fn();
vi.mock('../../../lib/supabaseClient', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

const CATEGORY_A = {
  id: 'c1',
  code: 'HW',
  name: 'Hardware',
  is_active: true,
  created_at: '2026-01-01T00:00:00Z',
};

beforeEach(() => {
  mockRpc.mockReset();
});

describe('TicketCategoriesAdmin', () => {
  it('shows the empty state and hides admin controls when is_it_support resolves false', async () => {
    mockSupabaseRpc(mockRpc, {
      is_it_support: () => ({ data: false }),
      get_ticket_categories: () => ({ data: [] }),
    });

    render(<TicketCategoriesAdmin />);

    await waitFor(() => expect(screen.getByText('No categories yet.')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: 'New category' })).not.toBeInTheDocument();
  });

  it('lists existing categories with their active state and shows admin controls', async () => {
    mockSupabaseRpc(mockRpc, {
      is_it_support: () => ({ data: true }),
      get_ticket_categories: () => ({ data: [CATEGORY_A] }),
    });

    render(<TicketCategoriesAdmin />);

    await waitFor(() => expect(screen.getByText('Hardware')).toBeInTheDocument());
    const row = screen.getByText('Hardware').closest('tr') as HTMLElement;
    expect(within(row).getByText('Active')).toBeInTheDocument();
    expect(within(row).getByRole('button', { name: 'Rename' })).toBeInTheDocument();
  });

  it('the Create button is disabled until code and name are entered, then creates and refetches', async () => {
    const user = userEvent.setup();
    let categories: typeof CATEGORY_A[] = [];
    const { calls } = mockSupabaseRpc(mockRpc, {
      is_it_support: () => ({ data: true }),
      get_ticket_categories: () => ({ data: categories }),
      create_ticket_category: (args) => {
        const { p_code, p_name } = args as { p_code: string; p_name: string };
        categories = [...categories, { id: 'c2', code: p_code, name: p_name, is_active: true, created_at: '2026-01-02T00:00:00Z' }];
        return { error: null };
      },
    });

    render(<TicketCategoriesAdmin />);
    await waitFor(() => expect(screen.getByText('No categories yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New category' }));
    const createButton = screen.getByRole('button', { name: 'Create' });
    expect(createButton).toBeDisabled();

    await user.type(screen.getByLabelText('Code'), 'SW');
    await user.type(screen.getByLabelText('Name'), 'Software');
    expect(createButton).toBeEnabled();
    await user.click(createButton);

    await waitFor(() => expect(screen.getByText('Software')).toBeInTheDocument());
    expect(calls.callsTo('create_ticket_category')).toEqual([
      { fn: 'create_ticket_category', args: { p_code: 'SW', p_name: 'Software' } },
    ]);
    // dialog closes after a successful save
    expect(screen.queryByRole('button', { name: 'Create' })).not.toBeInTheDocument();
  });

  it('renaming a category pre-fills the name and updates on save', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseRpc(mockRpc, {
      is_it_support: () => ({ data: true }),
      get_ticket_categories: () => ({ data: [CATEGORY_A] }),
      update_ticket_category: () => ({ error: null }),
    });

    render(<TicketCategoriesAdmin />);
    await waitFor(() => expect(screen.getByText('Hardware')).toBeInTheDocument());

    const row = screen.getByText('Hardware').closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('button', { name: 'Rename' }));
    expect(screen.getByDisplayValue('Hardware')).toBeInTheDocument();

    const nameField = screen.getByLabelText('Name');
    await user.clear(nameField);
    await user.type(nameField, 'Hardware & Peripherals');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() =>
      expect(calls.callsTo('update_ticket_category')).toEqual([
        { fn: 'update_ticket_category', args: { p_id: 'c1', p_name: 'Hardware & Peripherals' } },
      ]),
    );
  });

  it('deactivating a category toggles is_active only and refetches', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseRpc(mockRpc, {
      is_it_support: () => ({ data: true }),
      get_ticket_categories: () => ({ data: [CATEGORY_A] }),
      update_ticket_category: () => ({ error: null }),
    });

    render(<TicketCategoriesAdmin />);
    await waitFor(() => expect(screen.getByText('Hardware')).toBeInTheDocument());

    const row = screen.getByText('Hardware').closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('button', { name: 'Deactivate' }));

    await waitFor(() =>
      expect(calls.callsTo('update_ticket_category')).toEqual([
        { fn: 'update_ticket_category', args: { p_id: 'c1', p_is_active: false } },
      ]),
    );
  });

  it('a create RPC error (e.g. denied by is_it_support_admin) shows in an alert and keeps the dialog open', async () => {
    const user = userEvent.setup();
    mockSupabaseRpc(mockRpc, {
      is_it_support: () => ({ data: true }),
      get_ticket_categories: () => ({ data: [] }),
      create_ticket_category: () => ({ error: { message: 'not authorized to manage ticket categories' } }),
    });

    render(<TicketCategoriesAdmin />);
    await waitFor(() => expect(screen.getByText('No categories yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New category' }));
    await user.type(screen.getByLabelText('Code'), 'SW');
    await user.type(screen.getByLabelText('Name'), 'Software');
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() =>
      expect(screen.getByText('not authorized to manage ticket categories')).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: 'Create' })).toBeInTheDocument();
  });
});