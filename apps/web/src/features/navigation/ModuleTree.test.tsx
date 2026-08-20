import { describe, expect, it } from 'vitest';
import { filterNodesByAccess } from './ModuleTree';
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

function accessFor(role: string | null, opts: { isPlatformAdmin?: boolean } = {}) {
  const rolesByModule = new Map<string, Set<string>>();
  if (role) rolesByModule.set('bd', new Set([role]));
  return {
    isPlatformAdmin: !!opts.isPlatformAdmin,
    modules: new Set(['bd']),
    rolesByModule,
    isImpersonating: false,
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
