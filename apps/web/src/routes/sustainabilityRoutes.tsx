// Sustainability.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{sustainabilityRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';

const AuditsList = lazy(() => import('../modules/portals/sustainability/pages/audits/AuditsList'));
const CarbonMetrics = lazy(() => import('../modules/portals/sustainability/pages/metrics/CarbonMetrics'));
const CertificationsList = lazy(() => import('../modules/portals/sustainability/pages/audits/CertificationsList'));
const EnergyMetrics = lazy(() => import('../modules/portals/sustainability/pages/metrics/EnergyMetrics'));
const ExcellenceReport = lazy(() => import('../modules/portals/sustainability/pages/reports/ExcellenceReport'));
const InitiativeCategoriesAdmin = lazy(() => import('../modules/portals/sustainability/pages/admin/InitiativeCategoriesAdmin'));
const InitiativesList = lazy(() => import('../modules/portals/sustainability/pages/initiatives/InitiativesList'));
const MetricTypesAdmin = lazy(() => import('../modules/portals/sustainability/pages/admin/MetricTypesAdmin'));
const NewInitiative = lazy(() => import('../modules/portals/sustainability/pages/initiatives/NewInitiative'));
const SustainabilityDashboard = lazy(() => import('../modules/portals/sustainability/pages/SustainabilityDashboard'));
const SustainabilityReport = lazy(() => import('../modules/portals/sustainability/pages/reports/SustainabilityReport'));
const WasteMetrics = lazy(() => import('../modules/portals/sustainability/pages/metrics/WasteMetrics'));

export const sustainabilityRoutes = (
  <>
    {/* SUSTAINABILITY - 100% REAL NOW */}
    <Route element={<RequireModule module="sustainability" />}>
      <Route path="/sustainability/dashboard" element={<SustainabilityDashboard />} />
      <Route path="/sustainability/metrics/carbon" element={<CarbonMetrics />} />
      <Route path="/sustainability/metrics/energy" element={<EnergyMetrics />} />
      <Route path="/sustainability/metrics/waste" element={<WasteMetrics />} />
      <Route path="/sustainability/initiatives" element={<InitiativesList />} />
      <Route path="/sustainability/initiatives/new" element={<NewInitiative />} />
      <Route path="/sustainability/audits" element={<AuditsList />} />
      <Route path="/sustainability/certifications" element={<CertificationsList />} />
      <Route path="/sustainability/reports/sustainability" element={<SustainabilityReport />} />
      <Route path="/sustainability/reports/excellence" element={<ExcellenceReport />} />
      <Route path="/sustainability/admin/metric-types" element={<MetricTypesAdmin />} />
      <Route path="/sustainability/admin/categories" element={<InitiativeCategoriesAdmin />} />
    </Route>
  </>
);
