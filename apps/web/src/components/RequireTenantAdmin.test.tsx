import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../test/renderGuarded';
import RequireTenantAdmin from './RequireTenantAdmin';

// The guard delegates the access decision to useTenantAdminAccess
// (shared hook, also used by InviteMember/TeamMembersAdmin), so the
// test just mocks the hook and checks the three states.
const mockAccess = vi.fn();
vi.mock('../features/team/useTenantAdminAccess', () => ({
  useTenantAdminAccess: () => mockAccess(),
}));

beforeEach(() => {
  mockAccess.mockReset();
});

describe('RequireTenantAdmin', () => {
  it('shows a spinner while access is still resolving', () => {
    mockAccess.mockReturnValue(null);

    renderGuarded(<RequireTenantAdmin />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
  });

  it('renders the route for the company admin', async () => {
    mockAccess.mockReturnValue({ isAdmin: true, tenantId: 't1' });

    renderGuarded(<RequireTenantAdmin />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });

  it('renders the route for a platform admin (View-as path)', async () => {
    // useTenantAdminAccess returns isAdmin: true for platform admins.
    mockAccess.mockReturnValue({ isAdmin: true, tenantId: 't-home' });

    renderGuarded(<RequireTenantAdmin />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });

  it('denies access to non-admin members', async () => {
    mockAccess.mockReturnValue({ isAdmin: false, tenantId: 't1' });

    renderGuarded(<RequireTenantAdmin />);

    await waitFor(() => expect(screen.getByText('Company admin only')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: /back to my workspace/i })).toBeInTheDocument();
  });
});
