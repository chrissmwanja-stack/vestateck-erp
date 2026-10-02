// IT Support: member tier and admin/manager tier (IT_ADMIN_ROLES).
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{itSupportRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';
import { IT_ADMIN_ROLES } from '../features/it-support/access';

const AccessRequests = lazy(() => import('../features/it-support/access/AccessRequests'));
const AccountManagement = lazy(() => import('../features/it-support/access/AccountManagement'));
const AllTickets = lazy(() => import('../features/it-support/AllTickets'));
const AssetAssignments = lazy(() => import('../features/it-support/assets/AssetAssignments'));
const AssetReport = lazy(() => import('../features/it-support/reports/AssetReport'));
const AssetRequest = lazy(() => import('../features/it-support/assets/AssetRequest'));
const Faq = lazy(() => import('../features/it-support/Faq'));
const GroupManagement = lazy(() => import('../features/it-support/access/GroupManagement'));
const HardwareInventory = lazy(() => import('../features/it-support/assets/HardwareInventory'));
const ItSupportDashboard = lazy(() => import('../features/it-support/ItSupportDashboard'));
const KnowledgeBase = lazy(() => import('../features/it-support/KnowledgeBase'));
const LicenseTracking = lazy(() => import('../features/it-support/assets/LicenseTracking'));
const MyTickets = lazy(() => import('../features/it-support/MyTickets'));
const NewTicket = lazy(() => import('../features/it-support/NewTicket'));
const PriorityLevelsAdmin = lazy(() => import('../features/it-support/admin/PriorityLevelsAdmin'));
const ProblemManagement = lazy(() => import('../features/it-support/ProblemManagement'));
const SlaPerformanceReport = lazy(() => import('../features/it-support/reports/SlaPerformanceReport'));
const SlaPoliciesAdmin = lazy(() => import('../features/it-support/admin/SlaPoliciesAdmin'));
const SoftwareInventory = lazy(() => import('../features/it-support/assets/SoftwareInventory'));
const SupportTeamsAdmin = lazy(() => import('../features/it-support/admin/SupportTeamsAdmin'));
const TicketApprovals = lazy(() => import('../features/it-support/TicketApprovals'));
const TicketCategoriesAdmin = lazy(() => import('../features/it-support/admin/TicketCategoriesAdmin'));
const TicketTrackingReport = lazy(() => import('../features/it-support/reports/TicketTrackingReport'));

export const itSupportRoutes = (
  <>
    {/* IT SUPPORT - split into two tiers (2026-08-20), same shape
        as the BD split above: day-to-day support work stays on
        RequireModule's default admin/manager/member roles, while
        ticket approvals and the lookup-table admin screens are
        admin/manager only (see IT_ADMIN_ROLES in
        features/it-support/access.ts for why). Previously all of
        this sat under a single flat RequireModule module="it" with
        default roles, so any it member could approve tickets or
        edit categories/SLAs/priorities/teams tenant-wide. */}
    <Route element={<RequireModule module="it" />}>
      <Route path="/it-support/new-ticket" element={<NewTicket />} />
      <Route path="/it-support/my-tickets" element={<MyTickets />} />
      <Route path="/it-support/all-tickets" element={<AllTickets />} />
      <Route path="/it-support/problems" element={<ProblemManagement />} />
      <Route path="/it-support/dashboard" element={<ItSupportDashboard />} />
      <Route path="/it-support/assets/hardware" element={<HardwareInventory />} />
      <Route path="/it-support/assets/software" element={<SoftwareInventory />} />
      <Route path="/it-support/assets/licenses" element={<LicenseTracking />} />
      <Route path="/it-support/assets/assignments" element={<AssetAssignments />} />
      <Route path="/it-support/assets/request" element={<AssetRequest />} />
      <Route path="/it-support/access/accounts" element={<AccountManagement />} />
      <Route path="/it-support/access/groups" element={<GroupManagement />} />
      <Route path="/it-support/reports/ticket-tracking" element={<TicketTrackingReport />} />
      <Route path="/it-support/reports/sla" element={<SlaPerformanceReport />} />
      <Route path="/it-support/reports/assets" element={<AssetReport />} />
      <Route path="/it-support/kb" element={<KnowledgeBase />} />
      <Route path="/it-support/faq" element={<Faq />} />
      <Route path="/it-support/access/requests" element={<AccessRequests />} />
    </Route>

    <Route element={<RequireModule module="it" roles={IT_ADMIN_ROLES} />}>
      <Route path="/it-support/approvals" element={<TicketApprovals />} />
      <Route path="/it-support/admin/categories" element={<TicketCategoriesAdmin />} />
      <Route path="/it-support/admin/slas" element={<SlaPoliciesAdmin />} />
      <Route path="/it-support/admin/priorities" element={<PriorityLevelsAdmin />} />
      <Route path="/it-support/admin/teams" element={<SupportTeamsAdmin />} />
    </Route>
  </>
);
