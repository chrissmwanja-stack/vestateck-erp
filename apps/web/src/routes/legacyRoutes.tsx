// Legacy URLs kept as redirects so bookmarks and email links keep working.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{legacyRoutes}`.

import { Navigate, Route } from 'react-router-dom';

export const legacyRoutes = (
  <>
    {/* Moved to Company Admin (2026-09-30) -- org structure is the
        company admin's domain. The /hr/admin/departments alias
        (once HR-module gated, read-only after de1f547) redirects
        here too, so there is exactly one home for the screen. */}
    <Route path="/admin/departments" element={<Navigate to="/company-admin/organization/departments" replace />} />
    <Route path="/hr/admin/departments" element={<Navigate to="/company-admin/organization/departments" replace />} />
    {/* Old homes of the screens above -- redirects only, so
        bookmarks and email links keep working (same pattern as
        the /finance/purchase-orders move). */}
    <Route path="/team/invite" element={<Navigate to="/company-admin/users/invite" replace />} />
    <Route path="/team/members" element={<Navigate to="/company-admin/users/members" replace />} />
    <Route path="/admin/approval-workflow" element={<Navigate to="/company-admin/workflows/approvals" replace />} />
    <Route path="/setup" element={<Navigate to="/company-admin/setup" replace />} />
    {/* Old homes of the module-admin screens above -- redirects
        only, bookmarks keep working. */}
    <Route path="/admin/cost-codes" element={<Navigate to="/financial-management/admin/cost-codes" replace />} />
    <Route path="/admin/cost-codes/new" element={<Navigate to="/financial-management/admin/cost-codes/new" replace />} />
    <Route path="/admin/accounts" element={<Navigate to="/financial-management/admin/accounts" replace />} />
    <Route path="/admin/chart-of-accounts" element={<Navigate to="/financial-management/admin/chart-of-accounts" replace />} />
    <Route path="/admin/accounting-periods" element={<Navigate to="/financial-management/admin/accounting-periods" replace />} />
    <Route path="/admin/statutory-rates" element={<Navigate to="/financial-management/admin/statutory-rates" replace />} />
    <Route path="/admin/account-categories" element={<Navigate to="/financial-management/admin/account-categories" replace />} />
    <Route path="/admin/warehouses" element={<Navigate to="/warehouse/admin/warehouses" replace />} />
    <Route path="/admin/material-lookups" element={<Navigate to="/procurement/admin/material-lookups" replace />} />
    <Route path="/admin/material-catalog" element={<Navigate to="/procurement/admin/material-catalog" replace />} />
    <Route path="/admin/material-receipt" element={<Navigate to="/warehouse/admin/material-receipt" replace />} />
    <Route path="/procurement/admin/material-receipt" element={<Navigate to="/warehouse/admin/material-receipt" replace />} />
    {/* Organizations moved to Company Admin -> Organization. The
        redirect sits out here, not inside RequireFinanceTeam, so
        a company admin who is not on the finance team still
        reaches it. */}
    <Route path="/admin/organizations" element={<Navigate to="/company-admin/organization/organizations" replace />} />
  </>
);
