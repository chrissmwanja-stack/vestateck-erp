import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../../test/renderGuarded';
import RequireModule from '../../components/RequireModule';
import { IT_ADMIN_ROLES } from './access';

// Exercises the two-tier IT Support route split added in App.tsx:
//   - data-entry routes: <RequireModule module="it" />        (default roles)
//   - approvals/admin lookups: <RequireModule module="it" roles={IT_ADMIN_ROLES} />
//
// Same shape as business-development/access.test.tsx. has_module_role does
// an exact `role = any(p_roles)` match with no hierarchy (is_it_support()
// is just has_module_role('it', array['admin','manager','member'])), so
// these tests simulate that same exact-match semantics against a single
// staff_roles row per case, the same way Postgres would evaluate it. This
// is what actually catches a future accidental widening of IT_ADMIN_ROLES
// back to include 'member'.

const mockUseAuth = vi.fn();
vi.mock('../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

// Stand-in for the has_module_role SQL function: the caller's single IT
// staff_roles.role, checked for exact membership in whatever p_roles the
// component asked for -- no admin/manager/member hierarchy, matching
// production.
function mockStaffRole(role: string | null) {
  mockRpc.mockImplementation((_fn: string, args: { p_roles: string[] }) =>
    Promise.resolve({ data: role !== null && args.p_roles.includes(role), error: null }),
  );
}

beforeEach(() => {
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
  mockRpc.mockReset();
});

describe('IT_ADMIN_ROLES', () => {
  it('does not include member -- widening this silently reopens ticket approvals/admin lookups to every IT user', () => {
    expect(IT_ADMIN_ROLES).toEqual(['admin', 'manager']);
  });
});

describe('IT support data-entry tier (RequireModule module="it", default roles)', () => {
  it.each(['admin', 'manager', 'member'] as const)('lets an it %s in', async (role) => {
    mockStaffRole(role);

    renderGuarded(<RequireModule module="it" />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });

  it('denies a user with no it staff_roles row', async () => {
    mockStaffRole(null);

    renderGuarded(<RequireModule module="it" />);

    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
  });
});

describe('IT support admin/manager tier (RequireModule module="it" roles={IT_ADMIN_ROLES}) -- ticket approvals + lookup admin', () => {
  it.each(['admin', 'manager'] as const)('lets an it %s in', async (role) => {
    mockStaffRole(role);

    renderGuarded(<RequireModule module="it" roles={IT_ADMIN_ROLES} />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('has_module_role', {
      p_module: 'it',
      p_roles: [...IT_ADMIN_ROLES],
    });
  });

  it('denies a plain it member -- this is the behavior the fix adds (previously any it role could reach approvals/admin lookups)', async () => {
    mockStaffRole('member');

    renderGuarded(<RequireModule module="it" roles={IT_ADMIN_ROLES} />);

    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
  });

  it('denies a user with no it staff_roles row', async () => {
    mockStaffRole(null);

    renderGuarded(<RequireModule module="it" roles={IT_ADMIN_ROLES} />);

    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
  });
});
