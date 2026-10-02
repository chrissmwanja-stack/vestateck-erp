// Law & Compliance: member tier and contract approvals (LEGAL_APPROVER_ROLES).
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{lawComplianceRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';
import { LEGAL_APPROVER_ROLES } from '../modules/portals/law-compliance/access';

const CaseDetail = lazy(() => import('../modules/portals/law-compliance/pages/cases/CaseDetail'));
const CaseStatusReport = lazy(() => import('../modules/portals/law-compliance/pages/reports/CaseStatusReport'));
const CaseTypesAdmin = lazy(() => import('../modules/portals/law-compliance/pages/admin/CaseTypesAdmin'));
const CasesList = lazy(() => import('../modules/portals/law-compliance/pages/cases/CasesList'));
const ComplianceRegister = lazy(() => import('../modules/portals/law-compliance/pages/compliance/ComplianceRegister'));
const ContractApprovals = lazy(() => import('../modules/portals/law-compliance/pages/contracts/ContractApprovals'));
const ContractDetail = lazy(() => import('../modules/portals/law-compliance/pages/contracts/ContractDetail'));
const ContractTypesAdmin = lazy(() => import('../modules/portals/law-compliance/pages/admin/ContractTypesAdmin'));
const ContractsList = lazy(() => import('../modules/portals/law-compliance/pages/contracts/ContractsList'));
const ExpiryReport = lazy(() => import('../modules/portals/law-compliance/pages/reports/ExpiryReport'));
const FilingsList = lazy(() => import('../modules/portals/law-compliance/pages/compliance/FilingsList'));
const HearingsList = lazy(() => import('../modules/portals/law-compliance/pages/cases/HearingsList'));
const LawDashboard = lazy(() => import('../modules/portals/law-compliance/pages/LawDashboard'));
const NewCase = lazy(() => import('../modules/portals/law-compliance/pages/cases/NewCase'));
const NewContract = lazy(() => import('../modules/portals/law-compliance/pages/contracts/NewContract'));

export const lawComplianceRoutes = (
  <>
    {/* LAW AND COMPLIANCE - SHELL WIRED */}
    <Route element={<RequireModule module="legal" />}>
      <Route path="/law-compliance/dashboard" element={<LawDashboard />} />
      <Route path="/law-compliance/contracts" element={<ContractsList />} />
      <Route path="/law-compliance/contracts/new" element={<NewContract />} />
      <Route path="/law-compliance/contracts/:id" element={<ContractDetail />} />
      <Route path="/law-compliance/cases" element={<CasesList />} />
      <Route path="/law-compliance/cases/new" element={<NewCase />} />
      <Route path="/law-compliance/cases/hearings" element={<HearingsList />} />
      <Route path="/law-compliance/cases/:id" element={<CaseDetail />} />
      <Route path="/law-compliance/compliance/register" element={<ComplianceRegister />} />
      <Route path="/law-compliance/compliance/filings" element={<FilingsList />} />
      <Route path="/law-compliance/reports/expiry" element={<ExpiryReport />} />
      <Route path="/law-compliance/reports/cases" element={<CaseStatusReport />} />
      <Route path="/law-compliance/admin/contract-types" element={<ContractTypesAdmin />} />
      <Route path="/law-compliance/admin/case-types" element={<CaseTypesAdmin />} />
    </Route>

    {/* Contract approvals sit one tier up from day-to-day legal
        work (admin/manager only, same split as BD proposal
        approvals and IT ticket approvals) -- the route tier is
        enforced again server-side by decide_contract(), and the
        RPC additionally refuses creator self-approval. The screen
        moved from a direct table update to the decide_contract /
        submit_contract_for_approval RPCs on 2026-09-21, with a
        law_contract_decisions audit trail behind it. */}
    <Route element={<RequireModule module="legal" roles={LEGAL_APPROVER_ROLES} />}>
      <Route path="/law-compliance/contracts/approvals" element={<ContractApprovals />} />
    </Route>
  </>
);
