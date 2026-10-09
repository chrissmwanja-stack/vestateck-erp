import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../test/renderGuarded';
import RequireTenantAdmin from './RequireTenantAdmin';

// The guard combines two shared hooks: useTenantAdminAccess (is the caller
// a company admin / platform admin -- also used by InviteMember and
// TeamMembersAdmin) and useMyModuleAccess (is a platform admin currently
// viewing as a company). Both are mocked; the test checks the four outcomes.
const mockAccess = vi.fn();
vi.mock('../features/team/useTenantAdminAccess', () => ({
  useTenantAdminAccess: () => mockAccess(),
}));

const mockNav = vi.fn();
vi.mock('../features/navigation/useMyModuleAccess', () => ({
  useMyModuleAccess: () => mockNav(),
}));

const nav = (opts: { isPlatformAdmin?: boolean; isImpersonating?: boolean } = {}) => ({
  isPlatformAdmin: !!opts.isPlatformAdmin,
  isImpersonating: !!opts.isImpersonating,
  modules: new Set<string>(),
  entitledModules: new Set<string>(),
  rolesByModule: new Map<string, Set<string>>(),
  canAccessFinance: false,
  isCompanyAdmin: false,
  hasPoAccess: false,
});

beforeEach(() => {
  mockAccess.mockReset();
  mockNav.mockReset();
  mockNav.mockReturnValue(nav());
});

describe('RequireTenantAdmin', () => {
  it('shows a spinner while the admin check is still resolving', () => {
    mockAccess.mockReturnValue(null);

    renderGuarded(<RequireTenantAdmin />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
  });

  it('shows a spinner while the nav access is still resolving', () => {
    mockAccess.mockReturnValue({ isAdmin: true, tenantId: 't1' });
    mockNav.mockReturnValue(null);

    renderGuarded(<RequireTenantAdmin />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
  });

  it('renders the route for the company admin', async () => {
    mockAccess.mockReturnValue({ isAdmin: true, tenantId: 't1' });

    renderGuarded(<RequireTenantAdmin />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });

  it('renders the route for a platform admin who is viewing as a company', async () => {
    // useTenantAdminAccess returns isAdmin: true for platform admins.
    mockAccess.mockReturnValue({ isAdmin: true, tenantId: 't-target' });
    mockNav.mockReturnValue(nav({ isPlatformAdmin: true, isImpersonating: true }));

    renderGuarded(<RequireTenantAdmin />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });

  it('refuses a platform admin who is not viewing as a company', async () => {
    mockAccess.mockReturnValue({ isAdmin: true, tenantId: 't-home' });
    mockNav.mockReturnValue(nav({ isPlatformAdmin: true, isImpersonating: false }));

    renderGuarded(<RequireTenantAdmin />);

    await waitFor(() => expect(screen.getByText('Open a company first')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: /go to companies/i })).toBeInTheDocument();
  });

  it('denies access to non-admin members', async () => {
    mockAccess.mockReturnValue({ isAdmin: false, tenantId: 't1' });

    renderGuarded(<RequireTenantAdmin />);

    await waitFor(() => expect(screen.getByText('Company admin only')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: /back to my workspace/i })).toBeInTheDocument();
  });
});
