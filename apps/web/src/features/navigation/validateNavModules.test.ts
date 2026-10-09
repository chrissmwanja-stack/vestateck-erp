import { describe, expect, it } from 'vitest';
import { REGISTRY_FIXTURE } from '../../test/moduleRegistryMock';
import { portals } from './moduleTreeData';
import { collectRequiredModules, findUnknownNavModules } from './validateNavModules';
import type { Portal } from './types';

// REGISTRY_FIXTURE mirrors the keys seeded by 20261008061315_platform_modules_registry.sql.
// Grantable = tenant_entitled (finance is a core key but is gated via requiredAccess, not requiredModule).
const GRANTABLE = REGISTRY_FIXTURE.filter((m) => m.tenant_entitled).map((m) => m.key);

const portal = (over: Partial<Portal>): Portal => ({
  id: 'p',
  label: 'P',
  icon: null,
  nodes: [],
  ...over,
});

describe('nav requiredModule validation', () => {
  it('every requiredModule in the real portal tree is a grantable registry key', () => {
    expect(collectRequiredModules(portals).length).toBeGreaterThan(0);
    expect(findUnknownNavModules(portals, GRANTABLE)).toEqual([]);
  });

  it('every <RequireModule> / <RequireEntitlement> route guard uses a grantable registry key', () => {
    const files = import.meta.glob('../../routes/*.tsx', { query: '?raw', import: 'default', eager: true }) as Record<
      string,
      string
    >;
    const used = new Set<string>();
    for (const src of Object.values(files)) {
      for (const m of src.matchAll(/<Require(?:Module|Entitlement)\s+module=["']([a-z0-9_]+)["']/g)) used.add(m[1]);
    }
    expect(used.size).toBeGreaterThan(0);
    expect([...used].filter((k) => !GRANTABLE.includes(k))).toEqual([]);
  });

  it('collects portal-level and nested node-level gates', () => {
    const tree = [
      portal({
        id: 'hr',
        requiredModule: 'hr',
        nodes: [{ id: 'a', label: 'A', children: [{ id: 'b', label: 'B', requiredModule: 'procurement' }] }],
      }),
    ];
    expect(collectRequiredModules(tree)).toEqual([
      { where: 'portal:hr', module: 'hr' },
      { where: 'node:b', module: 'procurement' },
    ]);
  });

  it('collects requiredEntitlement gates and flags unknown keys', () => {
    const tree = [
      portal({
        id: 'purchasing',
        nodes: [
          { id: 'po', label: 'PO', requiredEntitlement: 'procurement' },
          { id: 'typo', label: 'Typo', requiredEntitlement: 'procurment' },
        ],
      }),
    ];
    expect(collectRequiredModules(tree)).toEqual([
      { where: 'node:po', module: 'procurement' },
      { where: 'node:typo', module: 'procurment' },
    ]);
    expect(findUnknownNavModules(tree, GRANTABLE)).toEqual([{ where: 'node:typo', module: 'procurment' }]);
  });

  it('flags typos and non-grantable keys such as finance', () => {
    const tree = [
      portal({ id: 'x', requiredModule: 'machine_operations' }),
      portal({ id: 'y', nodes: [{ id: 'n', label: 'N', requiredModule: 'finance' }] }),
    ];
    expect(findUnknownNavModules(tree, GRANTABLE)).toEqual([
      { where: 'portal:x', module: 'machine_operations' },
      { where: 'node:n', module: 'finance' },
    ]);
  });
});
