import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import PayrollApproversAdmin from './PayrollApproversAdmin';
import { mockSupabaseRpc } from '../../../../../test/rpcHarness';

// Same shape and same client-side has_module_role('hr', ['admin']) gate
// as HrTeamMembersAdmin.test.tsx (see that file's header) -- this one
// covers payroll_approvers instead, via grant_payroll_approver/
// set_payroll_approver_active (20260821090000_hr_team_and_payroll_approver_admin_rpcs.sql).
// The one behavior specific to this page: approvers are deactivated
// rather than deleted, and the "available to add" candidate filter only
// excludes users who are currently ACTIVE approvers -- a deactivated
// approver's user id must still be selectable so re-adding them (which
// reactivates via grant_payroll_approver) works.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

const APPROVER_ACTIVE = {
  id: 'a1',
  user_id: 'u1',
  role: 'approver',
  is_active: true,
  created_at: '2026-01-01T00:00:00Z',
  user: { id: 'u1', name: 'Amina Okello', email: 'amina@test.local' },
};

const APPROVER_INACTIVE = {
  id: 'a2',
  user_id: 'u2',
  role: 'approver',
  is_active: false,
  created_at: '2026-01-02T00:00:00Z',
  user: { id: 'u2', name: 'Brian Byaruhanga', email: 'brian@test.local' },
};

function setupFromMock(opts: { approvers?: unknown[]; candidates?: unknown[]; approversError?: { message: string } | null } = {}) {
  const { approvers = [], candidates = [], approversError = null } = opts;

  mockFrom.mockImplementation((table: string) => {
    if (table === 'payroll_approvers') {
      return {
        select: () => ({
          order: () => Promise.resolve({ data: approversError ? null : approvers, error: approversError }),
        }),
      };
    }
    if (table === 'app_users') {
      return {
        select: () => ({
          order: () => Promise.resolve({ data: candidates, error: null }),
        }),
      };
    }
    throw new Error(`setupFromMock: no handler for table "${table}"`);
  });
}

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
});

describe('PayrollApproversAdmin', () => {
  it('shows the empty state and hides admin controls when is-hr-admin resolves false', async () => {
    setupFromMock({ approvers: [] });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: false }) });

    render(<PayrollApproversAdmin />);

    await waitFor(() => expect(screen.getByText('No payroll approvers yet.')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: 'Add approver' })).not.toBeInTheDocument();
    expect(screen.queryByText('Actions')).not.toBeInTheDocument();
  });

  it('lists approvers with an Active/Inactive status chip', async () => {
    setupFromMock({ approvers: [APPROVER_ACTIVE, APPROVER_INACTIVE] });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: true }) });

    render(<PayrollApproversAdmin />);

    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());
    const activeRow = screen.getByText('Amina Okello').closest('tr') as HTMLElement;
    expect(within(activeRow).getByText('Active')).toBeInTheDocument();
    expect(within(activeRow).getByRole('button', { name: 'Deactivate' })).toBeInTheDocument();

    const inactiveRow = screen.getByText('Brian Byaruhanga').closest('tr') as HTMLElement;
    expect(within(inactiveRow).getByText('Inactive')).toBeInTheDocument();
    expect(within(inactiveRow).getByRole('button', { name: 'Reactivate' })).toBeInTheDocument();
  });

  it('a deactivated approver is still offered as an available candidate to re-add, but an active one is not', async () => {
    const user = userEvent.setup();
    setupFromMock({
      approvers: [APPROVER_ACTIVE, APPROVER_INACTIVE],
      candidates: [
        { id: 'u1', name: 'Amina Okello', email: 'amina@test.local' },
        { id: 'u2', name: 'Brian Byaruhanga', email: 'brian@test.local' },
      ],
    });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: true }) });

    render(<PayrollApproversAdmin />);
    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add approver' }));
    await user.click(screen.getByLabelText('User'));

    expect(await screen.findByRole('option', { name: 'Brian Byaruhanga' })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Amina Okello' })).not.toBeInTheDocument();
  });

  it('adding an approver is disabled until a user is selected, then calls grant_payroll_approver and refetches', async () => {
    const user = userEvent.setup();
    setupFromMock({ approvers: [], candidates: [{ id: 'u1', name: 'Amina Okello', email: 'amina@test.local' }] });
    const { calls } = mockSupabaseRpc(mockRpc, {
      has_module_role: () => ({ data: true }),
      grant_payroll_approver: () => ({ error: null }),
    });

    render(<PayrollApproversAdmin />);
    await waitFor(() => expect(screen.getByText('No payroll approvers yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add approver' }));
    const addButton = screen.getByRole('button', { name: 'Add' });
    expect(addButton).toBeDisabled();

    await user.click(screen.getByLabelText('User'));
    await user.click(await screen.findByRole('option', { name: 'Amina Okello' }));
    expect(addButton).toBeEnabled();
    await user.click(addButton);

    await waitFor(() =>
      expect(calls.callsTo('grant_payroll_approver')).toEqual([
        { fn: 'grant_payroll_approver', args: { p_user_id: 'u1' } },
      ]),
    );
    expect(screen.queryByRole('button', { name: 'Add' })).not.toBeInTheDocument();
  });

  it('a grant_payroll_approver error shows in an alert and keeps the dialog open', async () => {
    const user = userEvent.setup();
    setupFromMock({ approvers: [], candidates: [{ id: 'u1', name: 'Amina Okello', email: 'amina@test.local' }] });
    mockSupabaseRpc(mockRpc, {
      has_module_role: () => ({ data: true }),
      grant_payroll_approver: () => ({ error: { message: 'not authorized to manage payroll approvers' } }),
    });

    render(<PayrollApproversAdmin />);
    await waitFor(() => expect(screen.getByText('No payroll approvers yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add approver' }));
    await user.click(screen.getByLabelText('User'));
    await user.click(await screen.findByRole('option', { name: 'Amina Okello' }));
    await user.click(screen.getByRole('button', { name: 'Add' }));

    expect(await screen.findByText('not authorized to manage payroll approvers')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add' })).toBeInTheDocument();
  });

  it('deactivating an active approver calls set_payroll_approver_active with is_active=false', async () => {
    const user = userEvent.setup();
    setupFromMock({ approvers: [APPROVER_ACTIVE] });
    const { calls } = mockSupabaseRpc(mockRpc, {
      has_module_role: () => ({ data: true }),
      set_payroll_approver_active: () => ({ error: null }),
    });

    render(<PayrollApproversAdmin />);
    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

    const row = screen.getByText('Amina Okello').closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('button', { name: 'Deactivate' }));

    await waitFor(() =>
      expect(calls.callsTo('set_payroll_approver_active')).toEqual([
        { fn: 'set_payroll_approver_active', args: { p_user_id: 'u1', p_is_active: false } },
      ]),
    );
  });

  it('reactivating an inactive approver calls set_payroll_approver_active with is_active=true', async () => {
    const user = userEvent.setup();
    setupFromMock({ approvers: [APPROVER_INACTIVE] });
    const { calls } = mockSupabaseRpc(mockRpc, {
      has_module_role: () => ({ data: true }),
      set_payroll_approver_active: () => ({ error: null }),
    });

    render(<PayrollApproversAdmin />);
    await waitFor(() => expect(screen.getByText('Brian Byaruhanga')).toBeInTheDocument());

    const row = screen.getByText('Brian Byaruhanga').closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('button', { name: 'Reactivate' }));

    await waitFor(() =>
      expect(calls.callsTo('set_payroll_approver_active')).toEqual([
        { fn: 'set_payroll_approver_active', args: { p_user_id: 'u2', p_is_active: true } },
      ]),
    );
  });

  it('a load error on payroll_approvers is shown in an alert', async () => {
    setupFromMock({ approversError: { message: 'not authorized to view payroll approvers' } });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: false }) });

    render(<PayrollApproversAdmin />);

    expect(await screen.findByText('not authorized to view payroll approvers')).toBeInTheDocument();
  });
});