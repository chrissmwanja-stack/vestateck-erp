import { describe, expect, it } from 'vitest';
import { portals } from './moduleTreeData';
import type { ModuleAccessState } from './types';
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
