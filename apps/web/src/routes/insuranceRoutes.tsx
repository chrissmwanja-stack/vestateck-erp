// Insurance Brokerage.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{insuranceRoutes}`.
// Member screens sit under RequireModule (admin/manager/member, the module default).
// Admin screens add a nested RequireModule restricted to INS_ADMIN_ROLES.
// The server (RPC and RLS) is the enforcement point; these guards only match it.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';
import { INS_ADMIN_ROLES } from '../modules/portals/insurance/access';

const InsuranceDashboard = lazy(() => import('../modules/portals/insurance/pages/InsuranceDashboard'));
const ClientsList = lazy(() => import('../modules/portals/insurance/pages/clients/ClientsList'));
const InsurersList = lazy(() => import('../modules/portals/insurance/pages/insurers/InsurersList'));
const PoliciesList = lazy(() => import('../modules/portals/insurance/pages/policies/PoliciesList'));
const NewPolicy = lazy(() => import('../modules/portals/insurance/pages/policies/NewPolicy'));
const PolicyDetail = lazy(() => import('../modules/portals/insurance/pages/policies/PolicyDetail'));
const RenewalsList = lazy(() => import('../modules/portals/insurance/pages/renewals/RenewalsList'));
const ClaimsList = lazy(() => import('../modules/portals/insurance/pages/claims/ClaimsList'));
const NewClaim = lazy(() => import('../modules/portals/insurance/pages/claims/NewClaim'));
const ClaimDetail = lazy(() => import('../modules/portals/insurance/pages/claims/ClaimDetail'));
const CommissionPage = lazy(() => import('../modules/portals/insurance/pages/commission/CommissionPage'));
const CommissionStatements = lazy(() => import('../modules/portals/insurance/pages/commission/CommissionStatements'));
const ProductLinesAdmin = lazy(() => import('../modules/portals/insurance/pages/admin/ProductLinesAdmin'));
const ExchangeRates = lazy(() => import('../modules/portals/insurance/pages/currency/ExchangeRates'));
const RisksList = lazy(() => import('../modules/portals/insurance/pages/risks/RisksList'));
const CertificateStock = lazy(() => import('../modules/portals/insurance/pages/risks/CertificateStock'));

export const insuranceRoutes = (
  <>
    {/* INSURANCE BROKERAGE */}
    <Route element={<RequireModule module="insurance" />}>
      <Route path="/insurance" element={<InsuranceDashboard />} />
      <Route path="/insurance/clients" element={<ClientsList />} />
      <Route path="/insurance/insurers" element={<InsurersList />} />
      {/* "new" must be declared before ":id" so it is not read as an id. */}
      <Route path="/insurance/policies" element={<PoliciesList />} />
      <Route path="/insurance/policies/new" element={<NewPolicy />} />
      <Route path="/insurance/policies/:id" element={<PolicyDetail />} />
      <Route path="/insurance/renewals" element={<RenewalsList />} />
      <Route path="/insurance/claims" element={<ClaimsList />} />
      <Route path="/insurance/claims/new" element={<NewClaim />} />
      <Route path="/insurance/claims/:id" element={<ClaimDetail />} />
      {/* Any insurance role may read (server: can_access_insurance); the page hides
          transfer/void for non-managers, and the RPCs enforce can_manage_insurance. */}
      <Route path="/insurance/commission" element={<CommissionPage />} />
      <Route path="/insurance/commission/statements" element={<CommissionStatements />} />
      {/* Entry and approval are limited by the server (fx_rates policies and RPCs); the page only shows what each person may do. */}
      <Route path="/insurance/currency" element={<ExchangeRates />} />
      <Route path="/insurance/risks" element={<RisksList />} />
      <Route path="/insurance/certificates" element={<CertificateStock />} />

      <Route element={<RequireModule module="insurance" roles={INS_ADMIN_ROLES} />}>
        <Route path="/insurance/admin/product-lines" element={<ProductLinesAdmin />} />
      </Route>
    </Route>
  </>
);
