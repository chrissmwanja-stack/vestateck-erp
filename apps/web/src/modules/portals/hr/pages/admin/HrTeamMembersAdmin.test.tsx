import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import HrTeamMembersAdmin from './HrTeamMembersAdmin';
import { mockSupabaseRpc } from '../../../../../test/rpcHarness';

// This page sits behind RequireModule module="hr" (no roles= restriction
// -- any hr module member can reach the route; see App.tsx), so unlike
// the IT admin pages the client-side has_module_role('hr', ['admin'])
// check (isHrAdmin here) is the ONLY gate on Add/Remove, not a
// route-level backstop for it. These tests cover that gate plus the
// grant_hr_team_member/revoke_hr_team_member RPCs added in
// 20260821090000_hr_team_and_payroll_approver_admin_rpcs.sql.
//
// The page reads two tables side by side via Promise.all (hr_team_members
// joined to app_users, plus a flat app_users candidate list) -- both
// through a plain select().order() chain with no .eq() filtering, so
// setupFromMock below dispatches on table name only.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

const MEMBER_A = {
  id: 'm1',
  user_id: 'u1',
  role: 'member',
  created_at: '2026-01-01T00:00:00Z',
  user: { id: 'u1', name: 'Amina Okello', email: 'amina@test.local' },
};

const CANDIDATE_B = { id: 'u2', name: 'Brian Byaruhanga', email: 'brian@test.local' };

function setupFromMock(opts: { members?: unknown[]; candidates?: unknown[]; membersError?: { message: string } | null } = {}) {
  const { members = [], candidates = [CANDIDATE_B], membersError = null } = opts;

  mockFrom.mockImplementation((table: string) => {
    if (table === 'hr_team_members') {
      return {
        select: () => ({
          order: () => Promise.resolve({ data: membersError ? null : members, error: membersError }),
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

describe('HrTeamMembersAdmin', () => {
  it('shows the empty state and hides admin controls when is-hr-admin resolves false', async () => {
    setupFromMock({ members: [] });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: false }) });

    render(<HrTeamMembersAdmin />);

    await waitFor(() => expect(screen.getByText('No HR team members yet.')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: 'Add member' })).not.toBeInTheDocument();
    expect(screen.queryByText('Actions')).not.toBeInTheDocument();
  });

  it('lists existing members with name, email, and role, and shows admin controls', async () => {
    setupFromMock({ members: [MEMBER_A] });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: true }) });

    render(<HrTeamMembersAdmin />);

    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());
    const row = screen.getByText('Amina Okello').closest('tr') as HTMLElement;
    expect(within(row).getByText('amina@test.local')).toBeInTheDocument();
    expect(within(row).getByText('member')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add member' })).toBeInTheDocument();
  });

  it('a member already on the team is excluded from the Add dialog\'s candidate list', async () => {
    const user = userEvent.setup();
    // MEMBER_A (u1) is already a team member; CANDIDATE_B (u2) is not.
    setupFromMock({ members: [MEMBER_A], candidates: [{ id: 'u1', name: 'Amina Okello', email: 'amina@test.local' }, CANDIDATE_B] });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: true }) });

    render(<HrTeamMembersAdmin />);
    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add member' }));
    await user.click(screen.getByLabelText('User'));

    expect(await screen.findByRole('option', { name: 'Brian Byaruhanga' })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Amina Okello' })).not.toBeInTheDocument();
  });

  it('adding a member is disabled until a user is selected, then calls grant_hr_team_member with the chosen role and refetches', async () => {
    const user = userEvent.setup();
    setupFromMock({ members: [] });
    const { calls } = mockSupabaseRpc(mockRpc, {
      has_module_role: () => ({ data: true }),
      grant_hr_team_member: () => ({ error: null }),
    });

    render(<HrTeamMembersAdmin />);
    await waitFor(() => expect(screen.getByText('No HR team members yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add member' }));
    const addButton = screen.getByRole('button', { name: 'Add' });
    expect(addButton).toBeDisabled();

    await user.click(screen.getByLabelText('User'));
    await user.click(await screen.findByRole('option', { name: 'Brian Byaruhanga' }));
    expect(addButton).toBeEnabled();

    // default role is "member" -- change it to confirm the field is sent through as-is.
    const roleField = screen.getByLabelText('Role');
    await user.clear(roleField);
    await user.type(roleField, 'lead');
    await user.click(addButton);

    await waitFor(() =>
      expect(calls.callsTo('grant_hr_team_member')).toEqual([
        { fn: 'grant_hr_team_member', args: { p_user_id: 'u2', p_role: 'lead' } },
      ]),
    );
    // dialog closes after a successful save
    expect(screen.queryByRole('button', { name: 'Add' })).not.toBeInTheDocument();
  });

  it('a grant_hr_team_member error shows in an alert and keeps the dialog open', async () => {
    const user = userEvent.setup();
    setupFromMock({ members: [] });
    mockSupabaseRpc(mockRpc, {
      has_module_role: () => ({ data: true }),
      grant_hr_team_member: () => ({ error: { message: 'not authorized to manage the HR team' } }),
    });

    render(<HrTeamMembersAdmin />);
    await waitFor(() => expect(screen.getByText('No HR team members yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add member' }));
    await user.click(screen.getByLabelText('User'));
    await user.click(await screen.findByRole('option', { name: 'Brian Byaruhanga' }));
    await user.click(screen.getByRole('button', { name: 'Add' }));

    expect(await screen.findByText('not authorized to manage the HR team')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add' })).toBeInTheDocument();
  });

  describe('removing a member', () => {
    const confirmSpy = vi.spyOn(window, 'confirm');

    afterEach(() => {
      confirmSpy.mockReset();
    });

    it('asks for confirmation, then calls revoke_hr_team_member and refetches', async () => {
      const user = userEvent.setup();
      confirmSpy.mockReturnValue(true);
      setupFromMock({ members: [MEMBER_A] });
      const { calls } = mockSupabaseRpc(mockRpc, {
        has_module_role: () => ({ data: true }),
        revoke_hr_team_member: () => ({ error: null }),
      });

      render(<HrTeamMembersAdmin />);
      await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

      const row = screen.getByText('Amina Okello').closest('tr') as HTMLElement;
      await user.click(within(row).getByRole('button'));

      expect(confirmSpy).toHaveBeenCalledWith('Remove Amina Okello from the HR team?');
      await waitFor(() =>
        expect(calls.callsTo('revoke_hr_team_member')).toEqual([
          { fn: 'revoke_hr_team_member', args: { p_user_id: 'u1' } },
        ]),
      );
    });

    it('does nothing if the confirmation is declined', async () => {
      const user = userEvent.setup();
      confirmSpy.mockReturnValue(false);
      setupFromMock({ members: [MEMBER_A] });
      mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: true }) });

      render(<HrTeamMembersAdmin />);
      await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

      const row = screen.getByText('Amina Okello').closest('tr') as HTMLElement;
      await user.click(within(row).getByRole('button'));

      expect(mockRpc).not.toHaveBeenCalledWith('revoke_hr_team_member', expect.anything());
    });
  });

  it('a load error on hr_team_members is shown in an alert', async () => {
    setupFromMock({ membersError: { message: 'not authorized to view the HR team' } });
    mockSupabaseRpc(mockRpc, { has_module_role: () => ({ data: false }) });

    render(<HrTeamMembersAdmin />);

    expect(await screen.findByText('not authorized to view the HR team')).toBeInTheDocument();
  });
});