import { describe, expect, it, vi } from 'vitest';
import { filterNodesByAccess, portals } from './ModuleTree';
import { businessDevNodes } from '../../modules/portals/ShellConfigs';
import { BD_ADMIN_ROLES } from '../../modules/portals/business-development/access';
import type { ModuleAccessState } from './types';

// Mocks for the rendered-ModuleTree tests below (portal visibility).
// The pure-function tests above don't touch these hooks.
let mockModuleAccess: ModuleAccessState = {
  isPlatformAdmin: false,
  modules: new Set<string>(),
  rolesByModule: new Map<string, Set<string>>(),
  isImpersonating: false,
  canAccessFinance: false,
  isCompanyAdmin: false,
  hasPoAccess: false,
};
vi.mock('./useMyModuleAccess', () => ({
  useMyModuleAccess: () => mockModuleAccess,
}));
vi.mock('../../lib/brandingContext', () => ({
  useBranding: () => ({
    platformName: 'VestaPortal',
    tagline: '',
    logoUrl: '',
    primaryColor: '#1B5560',
    supportEmail: '',
    refresh: async () => {},
  }),
}));

// Covers the BD nav filtering added alongside the BD_ADMIN_ROLES route
// split: "Proposal Approvals" and the whole "Admin" (lookup tables) node
// should disappear from the sidebar for a plain bd member, while every
// other BD nav entry stays visible. Runs against the real businessDevNodes
// tree from ShellConfigs, not a hand-rolled fixture, so it breaks if that
// tree's requiredRoles wiring ever regresses.

function findNode(nodes: ReturnType<typeof filterNodesByAccess>, id: string): unknown {
  for (const n of nodes) {
    if (n.id === id) return n;
    if (n.children) {
      const found = findNode(n.children, id);
      if (found) return found;
    }
  }
  return undefined;
}

function accessFor(role: string | null, opts: { isPlatformAdmin?: boolean; canAccessFinance?: boolean } = {}) {
  const rolesByModule = new Map<string, Set<string>>();
  if (role) rolesByModule.set('bd', new Set([role]));
  return {
    isPlatformAdmin: !!opts.isPlatformAdmin,
    modules: new Set(['bd']),
    rolesByModule,
    isImpersonating: false,
    canAccessFinance: !!opts.canAccessFinance,
    isCompanyAdmin: false,
    hasPoAccess: false,
  };
}

describe('BD nav role gating (filterNodesByAccess + businessDevNodes)', () => {
  it('hides Proposal Approvals and the whole Admin node from a plain bd member', () => {
    const visible = filterNodesByAccess(businessDevNodes, accessFor('member'), 'bd');

    expect(findNode(visible, 'proposal-approvals')).toBeUndefined();
    expect(findNode(visible, 'bd-admin')).toBeUndefined();
    expect(findNode(visible, 'lead-sources')).toBeUndefined(); // child of bd-admin, never walked
  });

  it('keeps every other BD nav entry visible to a plain bd member', () => {
    const visible = filterNodesByAccess(businessDevNodes, accessFor('member'), 'bd');

    for (const id of ['bd-dashboard', 'leads', 'opportunities', 'proposal-list', 'proposal-new', 'clients', 'tenders', 'pipeline-report']) {
      expect(findNode(visible, id)).toBeDefined();
    }
  });

  it.each(BD_ADMIN_ROLES)('shows Proposal Approvals and Admin to a bd %s', (role) => {
    const visible = filterNodesByAccess(businessDevNodes, accessFor(role), 'bd');

    expect(findNode(visible, 'proposal-approvals')).toBeDefined();
    expect(findNode(visible, 'bd-admin')).toBeDefined();
    expect(findNode(visible, 'lead-sources')).toBeDefined();
  });

  it('shows everything to a platform admin regardless of their bd role', () => {
    const visible = filterNodesByAccess(businessDevNodes, accessFor(null, { isPlatformAdmin: true }), 'bd');

    expect(findNode(visible, 'proposal-approvals')).toBeDefined();
    expect(findNode(visible, 'bd-admin')).toBeDefined();
  });

  it('hides admin/approvals entries for a user with no bd staff_roles row at all', () => {
    const visible = filterNodesByAccess(businessDevNodes, accessFor(null), 'bd');

    expect(findNode(visible, 'proposal-approvals')).toBeUndefined();
    expect(findNode(visible, 'bd-admin')).toBeUndefined();
  });
});

// Regression coverage for the finance-nav leak: every route under
// RequireFinanceTeam in App.tsx (financial-management/*, purchase-orders,
// sap payment-approvals, cost-codes, material-receipt/lookups/catalog,
// warehouses) previously had no corresponding nav gate at all, so it
// appeared in the sidebar for every logged-in user regardless of
// can_access_finance(). These tests pin the fix: the whole
// financial-management portal, and the specific finance-only nodes inside
// purchasing-logistics, must not render without canAccessFinance/platform
// admin, and must render when either is true.
describe('finance nav gating (requiredAccess: "finance")', () => {
  const financeAccess = (opts: { canAccessFinance?: boolean; isPlatformAdmin?: boolean; hasPoAccess?: boolean } = {}) => ({
    isPlatformAdmin: !!opts.isPlatformAdmin,
    modules: new Set<string>(),
    rolesByModule: new Map<string, Set<string>>(),
    isImpersonating: false,
    canAccessFinance: !!opts.canAccessFinance,
    isCompanyAdmin: false,
    hasPoAccess: !!opts.hasPoAccess,
  });

  it('tags the whole financial-management portal with requiredAccess: "finance"', () => {
    const portal = portals.find((p) => p.id === 'financial-management');
    expect(portal?.requiredAccess).toBe('finance');
  });

  it('tags every finance-only node inside purchasing-logistics', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    // Post-Phase-2: material admin screens moved to the po tier (their
    // RLS writes are has_po_access-keyed); cost codes moved into the
    // finance portal. Warehouses and Material Receipt access stay finance
    // (finance-team authority: assign_receipt_access() requires
    // is_finance_team_member('finance')).
    const financeGatedIds = ['purchase-orders', 'payment-approvals', 'warehouses-admin', 'material-receipt-admin'];
    for (const id of financeGatedIds) {
      expect(findNode(portal.nodes, id)).toMatchObject({ requiredAccess: 'finance' });
    }
  });

  it('keeps Material Receipt access in the warehouse namespace behind the finance gate', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    expect(findNode(portal.nodes, 'material-receipt-admin')).toMatchObject({
      requiredAccess: 'finance',
      to: '/warehouse/admin/material-receipt',
    });
  });

  it('tags the material classification/catalog nodes with requiredAccess: "po" at their procurement URLs', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    expect(findNode(portal.nodes, 'material-lookups-admin')).toMatchObject({
      requiredAccess: 'po',
      to: '/procurement/admin/material-lookups',
    });
    expect(findNode(portal.nodes, 'material-catalog-admin')).toMatchObject({
      requiredAccess: 'po',
      to: '/procurement/admin/material-catalog',
    });
  });

  it('moved the cost-code nodes into the finance portal admin group', () => {
    const portal = portals.find((p) => p.id === 'financial-management')!;
    expect(findNode(portal.nodes, 'cost-code-list')).toMatchObject({ to: '/financial-management/admin/cost-codes' });
    expect(findNode(portal.nodes, 'cost-code-list-new')).toMatchObject({ to: '/financial-management/admin/cost-codes/new' });
    expect(findNode(portal.nodes, 'accounts-admin')).toMatchObject({ to: '/financial-management/admin/accounts' });
    expect(findNode(portal.nodes, 'chart-of-accounts-admin')).toMatchObject({ to: '/financial-management/admin/chart-of-accounts' });
  });

  it('hides material admin nodes without po access, shows them with it', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const denied = filterNodesByAccess(portal.nodes, financeAccess({ canAccessFinance: true }));
    expect(findNode(denied, 'material-catalog-admin')).toBeUndefined();
    // warehouses and material-receipt access keep showing on finance access alone
    expect(findNode(denied, 'warehouses-admin')).toBeDefined();
    expect(findNode(denied, 'material-receipt-admin')).toBeDefined();

    const allowed = filterNodesByAccess(portal.nodes, financeAccess({ hasPoAccess: true }));
    expect(findNode(allowed, 'material-catalog-admin')).toBeDefined();
    expect(findNode(allowed, 'material-lookups-admin')).toBeDefined();
  });

  it('hides finance-only purchasing-logistics nodes from a user without finance access', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const visible = filterNodesByAccess(portal.nodes, financeAccess());

    expect(findNode(visible, 'purchase-orders')).toBeUndefined();
    expect(findNode(visible, 'payment-approvals')).toBeUndefined();
    expect(findNode(visible, 'warehouses-admin')).toBeUndefined();
  });

  it('shows finance-only purchasing-logistics nodes to a user with finance access', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const visible = filterNodesByAccess(portal.nodes, financeAccess({ canAccessFinance: true }));

    expect(findNode(visible, 'purchase-orders')).toBeDefined();
    expect(findNode(visible, 'payment-approvals')).toBeDefined();
    expect(findNode(visible, 'warehouses-admin')).toBeDefined();
  });

  it('shows finance-only nodes to a platform admin regardless of canAccessFinance', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const visible = filterNodesByAccess(portal.nodes, financeAccess({ isPlatformAdmin: true }));

    expect(findNode(visible, 'purchase-orders')).toBeDefined();
  });

  it('does not gate non-finance purchasing-logistics nodes on canAccessFinance', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const visible = filterNodesByAccess(portal.nodes, financeAccess());

    // request-ops entries have no requiredModule/requiredAccess -- open to
    // any authenticated user, unaffected by finance gating.
    expect(findNode(visible, 'new-request')).toBeDefined();
    expect(findNode(visible, 'my-requests')).toBeDefined();
  });
});
// The Company Administration portal (Phase 1 of the admin-architecture
// rework) is whole-portal gated to the company admin, same shape as the
// finance gate above. The route-level enforcement is RequireTenantAdmin;
// this pins the nav-visibility half.
describe('company-admin nav gating (requiredAccess: "company-admin")', () => {
  const companyAdminAccess = (opts: { isCompanyAdmin?: boolean; isPlatformAdmin?: boolean } = {}) => ({
    isPlatformAdmin: !!opts.isPlatformAdmin,
    modules: new Set<string>(),
    rolesByModule: new Map<string, Set<string>>(),
    isImpersonating: false,
    canAccessFinance: false,
    isCompanyAdmin: !!opts.isCompanyAdmin,
    hasPoAccess: false,
  });

  it('tags the whole company-admin portal with requiredAccess: "company-admin"', () => {
    const portal = portals.find((p) => p.id === 'company-admin');
    expect(portal?.requiredAccess).toBe('company-admin');
  });

  it('lists the dashboard, organization, users, workflows and setup entries', () => {
    const portal = portals.find((p) => p.id === 'company-admin')!;
    for (const id of ['ca-dashboard', 'ca-organization', 'ca-users', 'ca-workflows', 'ca-setup']) {
      expect(findNode(portal.nodes, id)).toBeDefined();
    }
  });

  it('shows company-admin nodes to the company admin', () => {
    const portal = portals.find((p) => p.id === 'company-admin')!;
    const visible = filterNodesByAccess(portal.nodes, companyAdminAccess({ isCompanyAdmin: true }));
    expect(findNode(visible, 'ca-dashboard')).toBeDefined();
    expect(findNode(visible, 'ca-departments')).toBeDefined();
  });

  it('hides the whole portal from a regular member, shows it to a company admin', async () => {
    // The gate lives at portal level in ModuleTree's visiblePortals, so
    // render the real tree with mocked access and open the portal
    // switcher to see what's offered.
    const { default: ModuleTree } = await import('./ModuleTree');
    const { render, screen, fireEvent, cleanup } = await import('@testing-library/react');
    const { MemoryRouter } = await import('react-router-dom');

    for (const [isCompanyAdmin, expectVisible] of [
      [false, false],
      [true, true],
    ] as const) {
      mockModuleAccess = {
        isPlatformAdmin: false,
        modules: new Set<string>(),
        rolesByModule: new Map<string, Set<string>>(),
        isImpersonating: false,
        canAccessFinance: false,
        isCompanyAdmin,
        hasPoAccess: false,
      };
      render(
        <MemoryRouter>
          <ModuleTree />
        </MemoryRouter>
      );
      // Open the portal switcher (the header row).
      fireEvent.click(screen.getByText(/click to switch portal/i));
      const items = await screen.findAllByRole('menuitem');
      const labels = items.map((i) => i.textContent ?? '');
      expect(labels.some((l) => l.includes('Company Administration'))).toBe(expectVisible);
      cleanup();
    }
  });

  it('shows company-admin nodes to a platform admin (View-as)', () => {
    const portal = portals.find((p) => p.id === 'company-admin')!;
    const visible = filterNodesByAccess(portal.nodes, companyAdminAccess({ isPlatformAdmin: true }));
    expect(findNode(visible, 'ca-dashboard')).toBeDefined();
  });
});

describe('platform-admin portal visibility', () => {
  it('is tagged with the "platform" whole-portal gate', () => {
    const portal = portals.find((p) => p.id === 'platform-admin')!;
    expect(portal.requiredAccess).toBe('platform');
  });

  it('hides the switcher entry from non-platform users, shows it only to platform admins', async () => {
    // Render the real tree with mocked access and inspect the switcher
    // menu, same pattern as the company-admin portal test above.
    const { default: ModuleTree } = await import('./ModuleTree');
    const { render, screen, fireEvent, cleanup } = await import('@testing-library/react');
    const { MemoryRouter } = await import('react-router-dom');

    const base = {
      modules: new Set<string>(),
      rolesByModule: new Map<string, Set<string>>(),
      canAccessFinance: false,
      isCompanyAdmin: false,
      hasPoAccess: false,
    };

    const cases = [
      // [access, expect platform portal in switcher, expect it to be the ONLY portal]
      [{ ...base, isPlatformAdmin: false, isImpersonating: false }, false, false],
      [{ ...base, isPlatformAdmin: true, isImpersonating: false }, true, true],
      [{ ...base, isPlatformAdmin: true, isImpersonating: true }, true, false],
    ] as const;

    for (const [accessState, expectVisible, expectOnly] of cases) {
      mockModuleAccess = accessState;
      render(
        <MemoryRouter>
          <ModuleTree />
        </MemoryRouter>
      );
      fireEvent.click(screen.getByText(/click to switch portal/i));
      const items = await screen.findAllByRole('menuitem');
      const labels = items.map((i) => i.textContent ?? '');
      expect(labels.some((l) => l.includes('Platform Administration'))).toBe(expectVisible);
      if (expectOnly) {
        expect(labels).toHaveLength(1);
      }
      cleanup();
    }
  });
});
