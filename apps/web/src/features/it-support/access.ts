// Role tiers for the IT Support module.
//
// staff_roles.role has no built-in hierarchy -- has_module_role() does an
// exact `role = any(p_roles)` match (see has_module_role in the squashed
// baseline migration; is_it_support() is just
// has_module_role('it', array['admin','manager','member'])), so an
// 'admin' staff_roles row does NOT automatically satisfy a
// 'manager'-only check. Any tier that should include admins must list
// 'admin' explicitly.
//
// IT_ADMIN_ROLES gates the routes below in App.tsx (kept here, not
// inline, so the tier is a single source of truth shared by the route
// table and its tests -- same shape as BD_ADMIN_ROLES in
// modules/portals/business-development/access.ts):
//   - /it-support/approvals
//   - /it-support/admin/categories
//   - /it-support/admin/slas
//   - /it-support/admin/priorities
//   - /it-support/admin/teams
//
// Everything else under /it-support/* (tickets, problems, dashboard,
// asset inventory, account/group management, reports, KB, FAQ, access
// requests) stays on RequireModule's default roles (admin/manager/member)
// -- any IT staff can do the day-to-day support work, only admin/manager
// can approve tickets or edit the lookup tables (categories, SLA
// policies, priority levels, support teams) that back dropdowns
// tenant-wide.
//
// Before this, all of the above sat under a single flat
// RequireModule module="it" with default roles -- the same gap
// BD_ADMIN_ROLES closed for Business Development.
export const IT_ADMIN_ROLES = ['admin', 'manager'] as const;
