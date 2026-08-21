import { describe, expect, it } from 'vitest';
import { filterNodesByAccess, portals } from './ModuleTree';
import { businessDevNodes } from '../../modules/portals/ShellConfigs';
import { BD_ADMIN_ROLES } from '../../modules/portals/business-development/access';

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
  const financeAccess = (opts: { canAccessFinance?: boolean; isPlatformAdmin?: boolean } = {}) => ({
    isPlatformAdmin: !!opts.isPlatformAdmin,
    modules: new Set<string>(),
    rolesByModule: new Map<string, Set<string>>(),
    isImpersonating: false,
    canAccessFinance: !!opts.canAccessFinance,
  });

  it('tags the whole financial-management portal with requiredAccess: "finance"', () => {
    const portal = portals.find((p) => p.id === 'financial-management');
    expect(portal?.requiredAccess).toBe('finance');
  });

  it('tags every finance-only node inside purchasing-logistics', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const financeGatedIds = [
      'purchase-orders',
      'payment-approvals',
      'cost-code-list',
      'cost-code-list-new',
      'material-receipt-admin',
      'material-lookups-admin',
      'material-catalog-admin',
      'warehouses-admin',
    ];
    for (const id of financeGatedIds) {
      expect(findNode(portal.nodes, id)).toMatchObject({ requiredAccess: 'finance' });
    }
  });

  it('hides finance-only purchasing-logistics nodes from a user without finance access', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const visible = filterNodesByAccess(portal.nodes, financeAccess());

    expect(findNode(visible, 'purchase-orders')).toBeUndefined();
    expect(findNode(visible, 'payment-approvals')).toBeUndefined();
    expect(findNode(visible, 'cost-code-list')).toBeUndefined();
  });

  it('shows finance-only purchasing-logistics nodes to a user with finance access', () => {
    const portal = portals.find((p) => p.id === 'purchasing-logistics')!;
    const visible = filterNodesByAccess(portal.nodes, financeAccess({ canAccessFinance: true }));

    expect(findNode(visible, 'purchase-orders')).toBeDefined();
    expect(findNode(visible, 'payment-approvals')).toBeDefined();
    expect(findNode(visible, 'cost-code-list')).toBeDefined();
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