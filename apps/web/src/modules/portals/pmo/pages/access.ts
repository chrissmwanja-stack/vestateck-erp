// Role tiers for the PMO module (same shape as BD/IT/legal tiers).
//
// PMO_ADMIN_ROLES gates /pmo/approvals in App.tsx and mirrors the
// server-side tier in decide_pmo_project()
// (20260921110000_pmo_project_approval_flow.sql): any pmo role may create,
// submit and log time, only admin/manager may approve a project, reject
// one, or book costs against it (pmo_cost_entries write tier).
export const PMO_ADMIN_ROLES = ['admin', 'manager'] as const;
