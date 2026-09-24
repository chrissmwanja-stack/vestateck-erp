import type { ModuleKey } from "../../components/RequireModule";
import type { TreeNode, ModuleAccessState } from "./types";

// Strips nodes the current user has no module/role access to. "Access" here
// is access.modules, which is already the staff_roles ∩ tenant_modules
// intersection (see useMyModuleAccess) -- so a node also disappears if
// the tenant simply doesn't have that module opened, not just if the
// user lacks a role in it. Nodes without a requiredModule are always
// kept (for the module check); a parent with children is kept if it has
// any surviving child, or if it's directly accessible itself. This is nav
// visibility only -- RequireModule/has_module_role is what actually
// enforces access if someone still hits the URL directly.
//
// portalModule is the enclosing single-module portal's requiredModule
// (e.g. "bd"), used as the module context for a node's requiredRoles when
// the node itself doesn't set its own requiredModule -- which is the
// normal case for single-module portals like BD, where only the portal
// carries requiredModule and individual nodes just add requiredRoles on
// top of it.
export function filterNodesByAccess(
  nodes: TreeNode[],
  access: ModuleAccessState,
  portalModule?: ModuleKey,
): TreeNode[] {
  const canSee = (n: TreeNode) => {
    const m = n.requiredModule ?? portalModule;
    if (m && !access.isPlatformAdmin && !access.modules.has(m)) return false;
    if (n.requiredAccess === "finance" && !access.isPlatformAdmin && !access.canAccessFinance) return false;
    if (n.requiredRoles && !access.isPlatformAdmin) {
      const myRoles = (m && access.rolesByModule.get(m)) || new Set<string>();
      if (!n.requiredRoles.some((r) => myRoles.has(r))) return false;
    }
    return true;
  };
  const walk = (list: TreeNode[]): TreeNode[] =>
    list
      .map((n) => {
        if (!canSee(n)) return null;
        if (n.children) {
          const children = walk(n.children);
          if (children.length === 0 && !n.to) return null;
          return { ...n, children };
        }
        return n;
      })
      .filter(Boolean) as TreeNode[];
  return walk(nodes);
}
