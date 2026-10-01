import * as React from "react";
import type { ModuleKey } from "../../components/RequireModule";

export interface TreeNode {
  id: string;
  label: string;
  icon?: React.ReactNode;
  to?: string;
  children?: TreeNode[];
  disabled?: boolean;
  tooltip?: string;
  // Module gate for individual nodes -- used inside portals that mix
  // gated and ungated screens (e.g. "purchasing-logistics", which has
  // procurement-only nodes alongside open request/finance screens).
  // Nodes with no requiredModule are always shown once their portal is
  // shown. This mirrors, but does not replace, the real enforcement in
  // RequireModule at the route level -- this is nav visibility only.
  requiredModule?: ModuleKey;
  // Gate for access checks that aren't staff_roles/tenant_modules-based:
  //   finance       -> can_access_finance(), the OR of
  //                    is_finance_team_member() and has_po_access()
  //                    (enforced by RequireFinanceTeam)
  //   company-admin -> the tenant's company admin or a platform admin
  //                    (enforced by RequireTenantAdmin)
  //   po            -> has_po_access(): the authority tier that can write
  //                    material catalog / classification rows (enforced
  //                    by RequireRpcAccess rpc="has_po_access").
  // Nav visibility only -- mirrors requiredModule but checked against
  // access.canAccessFinance / access.isCompanyAdmin / access.hasPoAccess
  // instead of access.modules. See useMyModuleAccess below.
  requiredAccess?: "finance" | "company-admin" | "po";
  // Role gate on top of requiredModule -- for a node inside a single-module
  // portal (e.g. bd), the module checked is that portal's requiredModule;
  // for a node that also sets its own requiredModule (mixed portals like
  // purchasing-logistics), it's checked against that instead. Mirrors the
  // `roles` prop on RequireModule/has_module_role -- same exact-match
  // semantics, no admin/manager/member hierarchy. Nav visibility only; the
  // route guard is still the real enforcement.
  requiredRoles?: readonly string[];
}

export interface Portal {
  id: string;
  label: string;
  icon: React.ReactNode;
  nodes: TreeNode[];
  disabled?: boolean;
  tooltip?: string;
  // Cosmetic-only: marks preview-maturity modules with a "Preview" badge
  // in the switcher and header. Does NOT restrict access -- gating is
  // still purely requiredModule + useMyModuleAccess, same as before.
  isPreview?: boolean;
  // Module gate for the whole portal -- used for portals that are 100%
  // one module (hr, legal, bd, it, pmo, machine_operation,
  // sustainability). Portals with no requiredModule are always shown;
  // "purchasing-logistics" mixes gated/ungated nodes so it's tagged at
  // the node level instead (see requiredModule on TreeNode).
  requiredModule?: ModuleKey;
  // Whole-portal finance gate -- see requiredAccess on TreeNode. Used for
  // "financial-management", which (unlike purchasing-logistics) is 100%
  // finance-gated routes, so it's simpler to tag at the portal level.
  // "company-admin" works the same way for the Company Administration
  // portal (company admin / platform admin only).
  requiredAccess?: "finance" | "company-admin";
}

export interface ModuleAccessState {
  isPlatformAdmin: boolean;
  modules: Set<string>;
  // Module -> the roles the caller actually holds in staff_roles for it
  // (almost always one row per module, but staff_roles doesn't enforce
  // that). Used for nodes with requiredRoles (e.g. BD's admin lookups /
  // proposal approvals) -- separate from `modules`, which only answers
  // "does this module show up in nav at all".
  rolesByModule: Map<string, Set<string>>;
  isImpersonating: boolean;
  // can_access_finance() is a separate, non-staff_roles-based check
  // (is_finance_team_member() OR has_po_access() -- see
  // RequireFinanceTeam.tsx, which enforces this same check at the
  // route level). Fetched here purely so nav visibility matches what
  // the route guard will actually allow.
  canAccessFinance: boolean;
  // has_po_access() on its own -- the write authority behind the
  // material catalog / classification admin screens (their RLS is
  // keyed to has_po_access(), not to the finance team or the
  // procurement module role). Separate from canAccessFinance so nav
  // can mirror RequireRpcAccess rpc="has_po_access" exactly.
  hasPoAccess: boolean;
  // app_users.is_company_admin for the nav subject (the impersonated
  // user when viewing as one): the tenant's overall company admin, who
  // owns the Company Administration area. Mirrors useTenantAdminAccess
  // / RequireTenantAdmin. Platform admins count while impersonating a
  // company (they administer it through View-as), never in console-only
  // mode.
  isCompanyAdmin: boolean;
}
