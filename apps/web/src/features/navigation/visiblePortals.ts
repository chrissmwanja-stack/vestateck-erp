import { filterNodesByAccess } from "./filterNodesByAccess";
import type { ModuleAccessState, Portal, TreeNode } from "./types";

// Which portals (modules) a user is offered. Shared by the ModuleTree
// switcher and the Company Admin rail so the two can never disagree about
// what the user may open.
//
// Whole-portal gates (hr/legal/bd/it/pmo/...) hide a portal entirely when
// the user has no access; mixed portals (purchasing-logistics) and finance
// always show for their tier, with node-level filtering applied separately.
// The platform-admin portal is only ever offered to platform admins who are
// not impersonating; route guards remain the real enforcement.
export function visiblePortalsFor(access: ModuleAccessState | null, portals: Portal[]): Portal[] {
  if (!access) return portals;
  if (access.isPlatformAdmin && !access.isImpersonating) {
    return portals.filter((p) => p.id === "platform-admin");
  }
  return portals.filter((p) => {
    if (access.isPlatformAdmin) return true;
    if (p.requiredModule && !access.modules.has(p.requiredModule)) return false;
    if (p.requiredAccess === "finance" && !access.canAccessFinance) return false;
    if (p.requiredAccess === "company-admin" && !access.isCompanyAdmin) return false;
    if (p.requiredAccess === "platform") return false;
    return true;
  });
}

function firstLink(nodes: TreeNode[]): string | null {
  for (const n of nodes) {
    if (n.disabled) continue;
    if (n.to) return n.to;
    if (n.children) {
      const inner = firstLink(n.children);
      if (inner) return inner;
    }
  }
  return null;
}

// The page a user should land on when they pick a portal: its first screen
// that survives the same access filtering the tree applies. Null when the
// portal is disabled or has nothing reachable.
export function portalLandingPath(portal: Portal, access: ModuleAccessState): string | null {
  if (portal.disabled) return null;
  return firstLink(filterNodesByAccess(portal.nodes, access, portal.requiredModule));
}
