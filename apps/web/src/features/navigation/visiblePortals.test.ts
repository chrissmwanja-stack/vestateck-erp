import { describe, expect, it } from 'vitest';
import { filterNodesByAccess } from './filterNodesByAccess';
import { portals } from './moduleTreeData';
import type { ModuleAccessState, TreeNode } from './types';
import { portalLandingPath, visiblePortalsFor } from './visiblePortals';

function accessFor(modules: string[], overrides: Partial<ModuleAccessState> = {}): ModuleAccessState {
  return {
    isPlatformAdmin: false,
    modules: new Set(modules),
    entitledModules: new Set(modules),
    rolesByModule: new Map(modules.map((m) => [m, new Set(['admin'])])),
    isImpersonating: false,
    canAccessFinance: false,
    hasPoAccess: false,
    canDecideLeave: false,
    isCompanyAdmin: false,
    ...overrides,
  };
}

const ids = (list: { id: string }[]) => list.map((p) => p.id);

describe('visiblePortalsFor', () => {
  it('returns every portal while access is still loading', () => {
    expect(visiblePortalsFor(null, portals)).toBe(portals);
  });

  it('hides module portals the user has no staff role in, and admin portals they do not own', () => {
    const v = ids(visiblePortalsFor(accessFor(['hr']), portals));
    expect(v).toContain('human-resources');
    expect(v).not.toContain('insurance');
    expect(v).not.toContain('company-admin');
    expect(v).not.toContain('platform-admin');
  });

  it('shows the Company Administration portal only to a company admin', () => {
    expect(ids(visiblePortalsFor(accessFor([], { isCompanyAdmin: true }), portals))).toContain('company-admin');
  });

  // My Team carries Leave Approvals for deciders who cannot see the HR portal.
  describe('My Team (leave deciders without an HR role)', () => {
    it('is offered to a company admin or line manager who has no HR module', () => {
      expect(ids(visiblePortalsFor(accessFor([], { canDecideLeave: true }), portals))).toContain('my-team');
      expect(ids(visiblePortalsFor(accessFor(['procurement'], { canDecideLeave: true }), portals))).toContain('my-team');
    });

    it('is not offered to someone who cannot decide leave', () => {
      expect(ids(visiblePortalsFor(accessFor([]), portals))).not.toContain('my-team');
    });

    it('is not offered twice: people with the HR module already have Leave Approvals there', () => {
      const v = ids(visiblePortalsFor(accessFor(['hr'], { canDecideLeave: true }), portals));
      expect(v).toContain('human-resources');
      expect(v).not.toContain('my-team');
    });

    it('is not offered to a platform admin viewing as a company, who has the HR portal', () => {
      const v = visiblePortalsFor(accessFor([], { isPlatformAdmin: true, isImpersonating: true, canDecideLeave: true }), portals);
      expect(ids(v)).not.toContain('my-team');
    });

    it('lands on the Leave Approvals screen', () => {
      const portal = portals.find((p) => p.id === 'my-team')!;
      expect(portalLandingPath(portal, accessFor([], { canDecideLeave: true }))).toBe('/hr/leaves/approvals');
    });
  });

  it('offers only the platform console to a platform admin who is not impersonating', () => {
    const v = visiblePortalsFor(accessFor([], { isPlatformAdmin: true }), portals);
    expect(ids(v)).toEqual(['platform-admin']);
  });
});

describe('portalLandingPath', () => {
  it('returns the first screen the user can actually reach in the portal', () => {
    const hr = portals.find((p) => p.id === 'human-resources')!;
    const path = portalLandingPath(hr, accessFor(['hr']));
    expect(path).toMatch(/^\//);
    expect(path?.startsWith('/company-admin')).toBe(false);
  });

  it('returns null for a portal with nothing reachable', () => {
    const hr = portals.find((p) => p.id === 'human-resources')!;
    expect(portalLandingPath(hr, accessFor([]))).toBeNull();
  });
});

describe('Human Resources portal: Leave Approvals node', () => {
  const flat = (nodes: TreeNode[]): string[] => nodes.flatMap((n) => [n.id, ...(n.children ? flat(n.children) : [])]);
  const hr = portals.find((p) => p.id === 'human-resources')!;
  const visibleIds = (access: ModuleAccessState) => flat(filterNodesByAccess(hr.nodes, access, hr.requiredModule));

  it('is hidden from an HR member who cannot decide leave (the page would refuse them)', () => {
    const v = visibleIds(accessFor(['hr']));
    expect(v).toContain('leave-requests');
    expect(v).not.toContain('leave-approvals');
  });

  it('is shown to an HR user who can decide leave', () => {
    expect(visibleIds(accessFor(['hr'], { canDecideLeave: true }))).toContain('leave-approvals');
  });

  it('is shown to a platform admin', () => {
    expect(visibleIds(accessFor(['hr'], { isPlatformAdmin: true, isImpersonating: true }))).toContain('leave-approvals');
  });
});
