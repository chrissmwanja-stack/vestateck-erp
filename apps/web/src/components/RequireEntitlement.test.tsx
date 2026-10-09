import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { renderGuarded } from '../test/renderGuarded';
import RequireEntitlement from './RequireEntitlement';

// The guard reads the nav subject's tenant entitlements from useMyModuleAccess
// (mocked). It must not look at staff_roles: `modules` is left empty in every
// case on purpose, as it is for a finance-team user with no procurement role.
const mockNav = vi.fn();
vi.mock('../features/navigation/useMyModuleAccess', () => ({
  useMyModuleAccess: () => mockNav(),
}));

const nav = (opts: { entitled?: string[]; isPlatformAdmin?: boolean } = {}) => ({
  isPlatformAdmin: !!opts.isPlatformAdmin,
  isImpersonating: false,
  modules: new Set<string>(),
  entitledModules: new Set<string>(opts.entitled ?? []),
  rolesByModule: new Map<string, Set<string>>(),
  canAccessFinance: true,
  isCompanyAdmin: false,
  hasPoAccess: false,
});

beforeEach(() => {
  mockNav.mockReset();
});

describe('RequireEntitlement', () => {
  it('shows a spinner while the access state is still resolving', () => {
    mockNav.mockReturnValue(null);

    renderGuarded(<RequireEntitlement module="procurement" />);

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
  });

  it('renders the route when the tenant is entitled, even with no staff role in the module', async () => {
    mockNav.mockReturnValue(nav({ entitled: ['procurement'] }));

    renderGuarded(<RequireEntitlement module="procurement" />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });

  it('refuses the route when the tenant is not entitled to the module', async () => {
    mockNav.mockReturnValue(nav({ entitled: ['hr', 'legal'] }));

    renderGuarded(<RequireEntitlement module="procurement" />);

    await waitFor(() => expect(screen.getByText('Not enabled for your company')).toBeInTheDocument());
    expect(screen.queryByText('Protected content')).not.toBeInTheDocument();
  });

  it('lets a platform admin through whatever the entitlements', async () => {
    mockNav.mockReturnValue(nav({ isPlatformAdmin: true, entitled: [] }));

    renderGuarded(<RequireEntitlement module="procurement" />);

    await waitFor(() => expect(screen.getByText('Protected content')).toBeInTheDocument());
  });
});
