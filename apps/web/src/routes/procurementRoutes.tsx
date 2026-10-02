// Procurement: admin screens (has_po_access) and the procurement module routes.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{procurementRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';
import RequireRpcAccess from '../components/RequireRpcAccess';

const GoodsIssue = lazy(() => import('../features/requests/GoodsIssue'));
const MaterialCatalogAdmin = lazy(() => import('../features/admin/MaterialCatalogAdmin'));
const MaterialLookupsAdmin = lazy(() => import('../features/admin/MaterialLookupsAdmin'));
const MaterialQuantity = lazy(() => import('../features/requests/MaterialQuantity'));
const MaterialRequestApproval = lazy(() => import('../features/approvals/MaterialRequestApproval'));
const MaterialRequestReport = lazy(() => import('../features/requests/MaterialRequestReport'));
const OfferApprovalPO = lazy(() => import('../features/offers/OfferApprovalPO'));
const OfferEntry = lazy(() => import('../features/offers/OfferEntry'));
const ProcurementInfo = lazy(() => import('../features/procurement/ProcurementInfo'));
const ProcurementTrack = lazy(() => import('../features/procurement/ProcurementTrack'));
const PurchasingDashboard = lazy(() => import('../features/procurement/PurchasingDashboard'));
const RequestTracking = lazy(() => import('../features/procurement/RequestTracking'));
const StockBalances = lazy(() => import('../features/reports/StockBalances'));
const VendorEvaluationReport = lazy(() => import('../features/procurement/VendorEvaluationReport'));

export const procurementRoutes = (
  <>
    {/* PROCUREMENT ADMIN (material classification / catalog) -- moved out of /admin/* and out of the finance
        gate: these tables' RLS writes are keyed to
        has_po_access(), not to the finance team, so the route
        guard now mirrors the write authority exactly
        (RequireRpcAccess, same pattern as payroll approvals).
        Material classification / catalog live here; warehouses
        and material-receipt access keep the finance gate
        because their write authority is finance-team-keyed. */}
    <Route element={<RequireRpcAccess rpc="has_po_access" />}>
      <Route path="/procurement/admin/material-lookups" element={<MaterialLookupsAdmin />} />
      <Route path="/procurement/admin/material-catalog" element={<MaterialCatalogAdmin />} />
    </Route>
    {/* PROCUREMENT - gated by staff_roles module="procurement" (added
        2026-08-15). These were previously reachable by any
        authenticated tenant user with no module check at all. */}
    <Route element={<RequireModule module="procurement" />}>
      <Route path="/procurement/track" element={<ProcurementTrack />} />
      <Route path="/procurement/request-tracking" element={<RequestTracking />} />
      <Route path="/procurement/info" element={<ProcurementInfo />} />
      <Route path="/procurement/vendor-evaluation" element={<VendorEvaluationReport />} />
      <Route path="/purchasing/dashboard" element={<PurchasingDashboard />} />
      <Route path="/offers/entry" element={<OfferEntry />} />
      <Route path="/offers/approval-po" element={<OfferApprovalPO />} />
      <Route path="/approvals/material-requests" element={<MaterialRequestApproval />} />
      <Route path="/requests/material-quantity" element={<MaterialQuantity />} />
      <Route path="/requests/material-request-report" element={<MaterialRequestReport />} />
      <Route path="/warehouse/goods-issue" element={<GoodsIssue />} />
      <Route path="/warehouse/stock-balances" element={<StockBalances />} />
    </Route>
  </>
);
