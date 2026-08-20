// Role tiers for the Business Development module.
//
// staff_roles.role has no built-in hierarchy -- has_module_role() does an
// exact `role = any(p_roles)` match (see has_module_role in the squashed
// baseline migration), so an 'admin' staff_roles row does NOT automatically
// satisfy a 'manager'-only check. Any tier that should include admins must
// list 'admin' explicitly.
//
// BD_ADMIN_ROLES gates the routes below in App.tsx (kept here, not inline,
// so the tier is a single source of truth shared by the route table and
// its tests):
//   - /business-development/proposals/approvals
//   - /business-development/admin/lead-sources
//   - /business-development/admin/lead-statuses
//   - /business-development/admin/opportunity-stages
//   - /business-development/admin/proposal-types
//   - /business-development/admin/proposal-statuses
//   - /business-development/admin/client-categories
//   - /business-development/admin/tender-types
//
// Everything else under /business-development/* (leads, opportunities,
// proposals authoring, clients, tenders, reports) stays on RequireModule's
// default roles (admin/manager/member) -- any BD staff can do the day-to-day
// data entry, only admin/manager can approve proposals or edit the lookup
// tables that back dropdowns tenant-wide.
export const BD_ADMIN_ROLES = ['admin', 'manager'] as const;
