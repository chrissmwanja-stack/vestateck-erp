// Business Development: member tier and admin/manager tier (BD_ADMIN_ROLES).
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{businessDevelopmentRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';
import { BD_ADMIN_ROLES } from '../modules/portals/business-development/access';

const ActivitiesList = lazy(() => import('../modules/portals/business-development/pages/clients/ActivitiesList'));
const BDDashboard = lazy(() => import('../modules/portals/business-development/pages/BDDashboard'));
const ClientCategoriesAdmin = lazy(() => import('../modules/portals/business-development/pages/admin/ClientCategoriesAdmin'));
const ClientsList = lazy(() => import('../modules/portals/business-development/pages/clients/ClientsList'));
const ContactsList = lazy(() => import('../modules/portals/business-development/pages/clients/ContactsList'));
const ImportLeads = lazy(() => import('../modules/portals/business-development/pages/leads/ImportLeads'));
const LeadDetail = lazy(() => import('../modules/portals/business-development/pages/leads/LeadDetail'));
const LeadSourceReport = lazy(() => import('../modules/portals/business-development/pages/reports/LeadSourceReport'));
const LeadSourcesAdmin = lazy(() => import('../modules/portals/business-development/pages/admin/LeadSourcesAdmin'));
const LeadStatusesAdmin = lazy(() => import('../modules/portals/business-development/pages/admin/LeadStatusesAdmin'));
const LeadsList = lazy(() => import('../modules/portals/business-development/pages/leads/LeadsList'));
const NewLead = lazy(() => import('../modules/portals/business-development/pages/leads/NewLead'));
const NewOpportunity = lazy(() => import('../modules/portals/business-development/pages/opportunities/NewOpportunity'));
const NewProposal = lazy(() => import('../modules/portals/business-development/pages/proposals/NewProposal'));
const NewTender = lazy(() => import('../modules/portals/business-development/pages/tenders/NewTender'));
const OpportunitiesList = lazy(() => import('../modules/portals/business-development/pages/opportunities/OpportunitiesList'));
const OpportunityStagesAdmin = lazy(() => import('../modules/portals/business-development/pages/admin/OpportunityStagesAdmin'));
const PipelineBoard = lazy(() => import('../modules/portals/business-development/pages/opportunities/PipelineBoard'));
const PipelineReport = lazy(() => import('../modules/portals/business-development/pages/reports/PipelineReport'));
const ProposalApprovals = lazy(() => import('../modules/portals/business-development/pages/proposals/ProposalApprovals'));
const ProposalDetail = lazy(() => import('../modules/portals/business-development/pages/proposals/ProposalDetail'));
const ProposalStatusReport = lazy(() => import('../modules/portals/business-development/pages/reports/ProposalStatusReport'));
const ProposalStatusesAdmin = lazy(() => import('../modules/portals/business-development/pages/admin/ProposalStatusesAdmin'));
const ProposalTemplates = lazy(() => import('../modules/portals/business-development/pages/proposals/ProposalTemplates'));
const ProposalTracking = lazy(() => import('../modules/portals/business-development/pages/proposals/ProposalTracking'));
const ProposalTypesAdmin = lazy(() => import('../modules/portals/business-development/pages/admin/ProposalTypesAdmin'));
const ProposalsList = lazy(() => import('../modules/portals/business-development/pages/proposals/ProposalsList'));
const QualifiedLeads = lazy(() => import('../modules/portals/business-development/pages/leads/QualifiedLeads'));
const RevenueForecast = lazy(() => import('../modules/portals/business-development/pages/reports/RevenueForecast'));
const SubmissionsList = lazy(() => import('../modules/portals/business-development/pages/tenders/SubmissionsList'));
const TenderDetail = lazy(() => import('../modules/portals/business-development/pages/tenders/TenderDetail'));
const TenderTracking = lazy(() => import('../modules/portals/business-development/pages/tenders/TenderTracking'));
const TenderTypesAdmin = lazy(() => import('../modules/portals/business-development/pages/admin/TenderTypesAdmin'));
const TendersList = lazy(() => import('../modules/portals/business-development/pages/tenders/TendersList'));
const WinLossReport = lazy(() => import('../modules/portals/business-development/pages/reports/WinLossReport'));

export const businessDevelopmentRoutes = (
  <>
    {/* BUSINESS DEVELOPMENT - NOW CONNECTED - Full 32-route shell.
        Split into two tiers (2026-08-20): day-to-day BD work stays
        on RequireModule's default admin/manager/member roles,
        while proposal approvals and the lookup-table admin screens
        are admin/manager only (see BD_ADMIN_ROLES in
        modules/portals/business-development/access.ts for why). */}
    <Route element={<RequireModule module="bd" />}>
      <Route path="/business-development/dashboard" element={<BDDashboard />} />

      {/* Lead Management */}
      <Route path="/business-development/leads" element={<LeadsList />} />
      <Route path="/business-development/leads/new" element={<NewLead />} />
      <Route path="/business-development/leads/qualified" element={<QualifiedLeads />} />
      <Route path="/business-development/leads/import" element={<ImportLeads />} />
      <Route path="/business-development/leads/:id" element={<LeadDetail />} />

      {/* Opportunity Management */}
      <Route path="/business-development/opportunities" element={<OpportunitiesList />} />
      <Route path="/business-development/opportunities/pipeline" element={<PipelineBoard />} />
      <Route path="/business-development/opportunities/new" element={<NewOpportunity />} />

      {/* Proposals */}
      <Route path="/business-development/proposals" element={<ProposalsList />} />
      <Route path="/business-development/proposals/new" element={<NewProposal />} />
      <Route path="/business-development/proposals/templates" element={<ProposalTemplates />} />
      <Route path="/business-development/proposals/tracking" element={<ProposalTracking />} />
      <Route path="/business-development/proposals/:id" element={<ProposalDetail />} />

      {/* Client Management */}
      <Route path="/business-development/clients" element={<ClientsList />} />
      <Route path="/business-development/clients/contacts" element={<ContactsList />} />
      <Route path="/business-development/clients/activities" element={<ActivitiesList />} />

      {/* Tender Management */}
      <Route path="/business-development/tenders" element={<TendersList />} />
      <Route path="/business-development/tenders/new" element={<NewTender />} />
      <Route path="/business-development/tenders/submissions" element={<SubmissionsList />} />
      <Route path="/business-development/tenders/tracking" element={<TenderTracking />} />
      <Route path="/business-development/tenders/:id" element={<TenderDetail />} />

      {/* Reports */}
      <Route path="/business-development/reports/pipeline" element={<PipelineReport />} />
      <Route path="/business-development/reports/win-loss" element={<WinLossReport />} />
      <Route path="/business-development/reports/proposal-status" element={<ProposalStatusReport />} />
      <Route path="/business-development/reports/lead-source" element={<LeadSourceReport />} />
      <Route path="/business-development/reports/forecast" element={<RevenueForecast />} />
    </Route>

    {/* BUSINESS DEVELOPMENT - admin/manager tier: proposal
        approvals + the lookup tables backing BD dropdowns
        tenant-wide. See BD_ADMIN_ROLES for rationale. */}
    <Route element={<RequireModule module="bd" roles={BD_ADMIN_ROLES} />}>
      <Route path="/business-development/proposals/approvals" element={<ProposalApprovals />} />
      <Route path="/business-development/admin/lead-sources" element={<LeadSourcesAdmin />} />
      <Route path="/business-development/admin/lead-statuses" element={<LeadStatusesAdmin />} />
      <Route path="/business-development/admin/opportunity-stages" element={<OpportunityStagesAdmin />} />
      <Route path="/business-development/admin/proposal-types" element={<ProposalTypesAdmin />} />
      <Route path="/business-development/admin/proposal-statuses" element={<ProposalStatusesAdmin />} />
      <Route path="/business-development/admin/client-categories" element={<ClientCategoriesAdmin />} />
      <Route path="/business-development/admin/tender-types" element={<TenderTypesAdmin />} />
    </Route>
  </>
);
