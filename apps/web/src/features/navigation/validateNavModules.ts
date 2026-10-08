import { loadModuleRegistry } from '../../lib/useModuleRegistry';
import type { Portal, TreeNode } from './types';

// Nav nodes and portals gate on `requiredModule` keys. Those keys are free-form
// strings now (ModuleKey is a string alias; the platform_modules registry is the
// source of truth), so a typo would silently hide a node for everyone instead
// of failing to compile. This catches that:
//   - in CI, validateNavModules.test.ts checks the real portal tree and the
//     <RequireModule module="..."> route guards against the registry's seeded keys
//   - in dev, ModuleTree calls warnOnUnknownNavModules() once against the live registry

export interface NavModuleRef {
  /** Where the key was found, e.g. "portal:hr" or "node:new-material-approval". */
  where: string;
  module: string;
}

function walkNodes(nodes: TreeNode[], out: NavModuleRef[]): void {
  for (const n of nodes) {
    if (n.requiredModule) out.push({ where: `node:${n.id}`, module: n.requiredModule });
    if (n.children) walkNodes(n.children, out);
  }
}

export function collectRequiredModules(portals: Portal[]): NavModuleRef[] {
  const out: NavModuleRef[] = [];
  for (const p of portals) {
    if (p.requiredModule) out.push({ where: `portal:${p.id}`, module: p.requiredModule });
    walkNodes(p.nodes, out);
  }
  return out;
}

/** Refs whose module is not in `validKeys` (pass the registry's tenant-entitled keys). */
export function findUnknownNavModules(portals: Portal[], validKeys: Iterable<string>): NavModuleRef[] {
  const valid = new Set(validKeys);
  return collectRequiredModules(portals).filter((r) => !valid.has(r.module));
}

let warned = false;

/** Dev-only: warn (once) about nav gates that reference a module the live registry doesn't grant. */
export async function warnOnUnknownNavModules(portals: Portal[]): Promise<void> {
  if (warned) return;
  warned = true;
  try {
    const registry = await loadModuleRegistry();
    const unknown = findUnknownNavModules(
      portals,
      registry.filter((m) => m.tenant_entitled).map((m) => m.key),
    );
    if (unknown.length > 0) {
      console.warn(
        '[nav] requiredModule values that are not grantable modules in platform_modules:',
        unknown.map((u) => `${u.where} -> "${u.module}"`),
      );
    }
  } catch {
    // Registry unavailable (offline, signed out): nothing useful to check.
  }
}
