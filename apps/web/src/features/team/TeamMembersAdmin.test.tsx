import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import TeamMembersAdmin from './TeamMembersAdmin';
import { mockSupabaseRpc } from '../../test/rpcHarness';

// This page sits behind useTenantAdminAccess (company admin or platform
// admin only) -- mocked directly here rather than simulated through
// auth.getSession()/app_users, since that hook's own logic (impersonation,
// auth-state-change refetch) is out of scope for this file and already a
// single shared source of truth per its own comments.
//
// The two RPCs this page drives (get_tenant_team_members,
// set_member_access) were added in 20260821140000/20260821143000; a
// caller-side bug fixed alongside those migrations is covered directly
// below: get_tenant_team_members' `modules` column comes back as
// generic jsonb (Json) from the generated Supabase types, not a typed
// ModuleGrant[], so a malformed/non-array value must degrade to an
// empty list rather than blowing up the render.

const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

const mockUseTenantAdminAccess = vi.fn();
vi.mock('./useTenantAdminAccess', () => ({
  useTenantAdminAccess: () => mockUseTenantAdminAccess(),
}));

const MEMBER_A = {
  user_id: 'u1',
  name: 'Amina Okello',
  email: 'amina@test.local',
  role_title: 'HR Manager',
  is_company_admin: false,
  modules: [{ module: 'hr', role: 'admin' }],
  finance_role: null,
};

const MEMBER_B = {
  user_id: 'u2',
  name: 'Chris Mwanja',
  email: 'chris@test.local',
  role_title: 'Owner',
  is_company_admin: true,
  modules: [],
  finance_role: 'finance',
};

beforeEach(() => {
  mockRpc.mockReset();
  mockUseTenantAdminAccess.mockReturnValue({ isAdmin: true, tenantId: 't1' });
});

describe('TeamMembersAdmin', () => {
  it('shows a warning and never calls the team RPCs when the caller is not a tenant admin', async () => {
    mockUseTenantAdminAccess.mockReturnValue({ isAdmin: false, tenantId: 't1' });

    render(<TeamMembersAdmin />);

    expect(
      await screen.findByText('Managing team member access is only available to company admins.'),
    ).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('lists members with their module grants, company-admin badge, and finance access', async () => {
    mockSupabaseRpc(mockRpc, {
      get_tenant_team_members: () => ({ data: [MEMBER_A, MEMBER_B] }),
    });

    render(<TeamMembersAdmin />);

    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

    const rowA = screen.getByText('Amina Okello').closest('tr') as HTMLElement;
    expect(within(rowA).getByText('HR (admin)')).toBeInTheDocument();
    expect(within(rowA).queryByText('Company admin')).not.toBeInTheDocument();
    expect(within(rowA).getByText('None')).toBeInTheDocument(); // no finance access

    const rowB = screen.getByText('Chris Mwanja').closest('tr') as HTMLElement;
    expect(within(rowB).getByText('Company admin')).toBeInTheDocument();
    expect(within(rowB).getByText('Finance (view & edit)')).toBeInTheDocument();
    // MEMBER_B has no module grants, but the "None" placeholder for the
    // modules column is only shown for non-company-admins (see the
    // `!m.is_company_admin` guard) -- a bare company-admin badge with no
    // module chips is the expected, un-placeholdered state here.
    expect(within(rowB).queryByText('None')).not.toBeInTheDocument();
  });

  it('degrades a malformed (non-array) modules value to an empty list instead of crashing', async () => {
    // Guards the fix for the TS2352 cast: get_tenant_team_members'
    // `modules` column is generic Json, not a typed ModuleGrant[] --
    // this simulates the RPC returning null for it (e.g. a member with
    // no staff_roles rows and a coalesce that somehow didn't fire).
    mockSupabaseRpc(mockRpc, {
      get_tenant_team_members: () => ({ data: [{ ...MEMBER_A, modules: null }] }),
    });

    render(<TeamMembersAdmin />);

    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());
    const row = screen.getByText('Amina Okello').closest('tr') as HTMLElement;
    // Both the modules cell (empty list, not a company admin) and the
    // finance cell (no finance_role) render the "None" placeholder.
    expect(within(row).getAllByText('None')).toHaveLength(2);
  });

  it('a load error is shown in an alert', async () => {
    mockSupabaseRpc(mockRpc, {
      get_tenant_team_members: () => ({ error: { message: 'not authorized to manage team access' } }),
    });

    render(<TeamMembersAdmin />);

    expect(await screen.findByText('not authorized to manage team access')).toBeInTheDocument();
  });

  it('opening Edit access pre-fills the existing module grants and finance role', async () => {
    const user = userEvent.setup();
    mockSupabaseRpc(mockRpc, {
      get_tenant_team_members: () => ({ data: [MEMBER_B] }),
    });

    render(<TeamMembersAdmin />);
    await waitFor(() => expect(screen.getByText('Chris Mwanja')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Edit access' }));

    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText('Edit access — chris@test.local')).toBeInTheDocument();
    expect((screen.getByLabelText('HR') as HTMLInputElement).checked).toBe(false);
    // "Finance (view & edit)" also appears in the table row behind the
    // dialog (chip), so scope to the dialog for the select's displayed value.
    expect(within(dialog).getByText('Finance (view & edit)')).toBeInTheDocument();
  });

  it('checking a module, setting its role, and saving sends only the checked modules to set_member_access', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseRpc(mockRpc, {
      get_tenant_team_members: () => ({ data: [MEMBER_A] }),
      set_member_access: () => ({ error: null }),
    });

    render(<TeamMembersAdmin />);
    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Edit access' }));
    // hr is pre-checked from MEMBER_A's existing grant; add IT Support too.
    await user.click(screen.getByLabelText('IT Support'));

    // Role selects render in ALL_MODULES order: hr, legal, bd, it, ... --
    // set the newly-checked IT Support module (index 3) to "manager".
    const roleSelects = screen.getAllByLabelText('Role');
    await user.click(roleSelects[3]);
    await user.click(await screen.findByRole('option', { name: 'manager' }));

    await user.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(calls.callsTo('set_member_access')).toHaveLength(1));
    expect(calls.callsTo('set_member_access')[0].args).toEqual({
      p_user_id: 'u1',
      p_modules: [
        { module: 'hr', role: 'admin' },
        { module: 'it', role: 'manager' },
      ],
      p_finance_role: '',
    });
    expect(await screen.findByText('Updated access for amina@test.local.')).toBeInTheDocument();
    // dialog closes after a successful save
    expect(screen.queryByText('Edit access — amina@test.local')).not.toBeInTheDocument();
  });

  it('clearing finance access sends an empty string, not null', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseRpc(mockRpc, {
      get_tenant_team_members: () => ({ data: [MEMBER_B] }),
      set_member_access: () => ({ error: null }),
    });

    render(<TeamMembersAdmin />);
    await waitFor(() => expect(screen.getByText('Chris Mwanja')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Edit access' }));
    await user.click(screen.getByLabelText('Finance access'));
    await user.click(await screen.findByRole('option', { name: 'No finance access' }));
    await user.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(calls.callsTo('set_member_access')).toHaveLength(1));
    // set_member_access does nullif(p_finance_role, '') server-side --
    // '' is the RPC's own convention for "clear finance access", and
    // p_finance_role is a non-nullable text param, so null must never
    // be sent here.
    expect(calls.callsTo('set_member_access')[0].args).toMatchObject({ p_finance_role: '' });
  });

  it('a save RPC error (e.g. denied by is_tenant_admin) shows in an alert and keeps the dialog open', async () => {
    const user = userEvent.setup();
    mockSupabaseRpc(mockRpc, {
      get_tenant_team_members: () => ({ data: [MEMBER_A] }),
      set_member_access: () => ({ error: { message: 'not authorized to manage team access' } }),
    });

    render(<TeamMembersAdmin />);
    await waitFor(() => expect(screen.getByText('Amina Okello')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Edit access' }));
    await user.click(screen.getByRole('button', { name: 'Save changes' }));

    expect(await screen.findByText('not authorized to manage team access')).toBeInTheDocument();
    expect(screen.getByText('Edit access — amina@test.local')).toBeInTheDocument();
  });
});