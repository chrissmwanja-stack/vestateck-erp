// Human Resources: HR module routes and payroll approvals (separate RPC-keyed grant).
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{hrRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';
import RequireRpcAccess from '../components/RequireRpcAccess';

const ApplicationsList = lazy(() => import('../modules/portals/hr/pages/recruitment/ApplicationsList'));
const AppraisalsList = lazy(() => import('../modules/portals/hr/pages/performance/AppraisalsList'));
const AttendanceList = lazy(() => import('../modules/portals/hr/pages/attendance/AttendanceList'));
const AttendanceReport = lazy(() => import('../modules/portals/hr/pages/reports/AttendanceReport'));
const CompensationHistory = lazy(() => import('../modules/portals/hr/pages/payroll/CompensationHistory'));
const EmployeesList = lazy(() => import('../modules/portals/hr/pages/employees/EmployeesList'));
const HRDashboard = lazy(() => import('../modules/portals/hr/pages/HRDashboard'));
const HeadcountReport = lazy(() => import('../modules/portals/hr/pages/reports/HeadcountReport'));
const HrTeamMembersAdmin = lazy(() => import('../modules/portals/hr/pages/admin/HrTeamMembersAdmin'));
const JobPostingsList = lazy(() => import('../modules/portals/hr/pages/recruitment/JobPostingsList'));
const LeaveRequestsList = lazy(() => import('../modules/portals/hr/pages/leaves/LeaveRequestsList'));
const LeaveTypesAdmin = lazy(() => import('../modules/portals/hr/pages/admin/LeaveTypesAdmin'));
const OrgChart = lazy(() => import('../modules/portals/hr/pages/org/OrgChart'));
const PayrollApprovals = lazy(() => import('../modules/portals/hr/pages/payroll/PayrollApprovals'));
const PayrollApproversAdmin = lazy(() => import('../modules/portals/hr/pages/admin/PayrollApproversAdmin'));
const PayrollList = lazy(() => import('../modules/portals/hr/pages/payroll/PayrollList'));
const PositionsAdmin = lazy(() => import('../modules/portals/hr/pages/admin/PositionsAdmin'));
const TrainingList = lazy(() => import('../modules/portals/hr/pages/performance/TrainingList'));

export const hrRoutes = (
  <>
    {/* HUMAN RESOURCES - SHELL WIRED */}
    <Route element={<RequireModule module="hr" />}>
      <Route path="/hr/dashboard" element={<HRDashboard />} />
      <Route path="/hr/employees" element={<EmployeesList />} />
      <Route path="/hr/employees/new" element={<EmployeesList />} />
      <Route path="/hr/org-chart" element={<OrgChart />} />
      <Route path="/hr/attendance" element={<AttendanceList />} />
      <Route path="/hr/leaves" element={<LeaveRequestsList />} />
      <Route path="/hr/leaves/approvals" element={<LeaveRequestsList />} />
      <Route path="/hr/recruitment/jobs" element={<JobPostingsList />} />
      <Route path="/hr/recruitment/applications" element={<ApplicationsList />} />
      <Route path="/hr/payroll" element={<PayrollList />} />
      <Route path="/hr/payroll/compensation-history" element={<CompensationHistory />} />
      <Route path="/hr/performance/appraisals" element={<AppraisalsList />} />
      <Route path="/hr/training" element={<TrainingList />} />
      <Route path="/hr/reports/headcount" element={<HeadcountReport />} />
      <Route path="/hr/reports/attendance" element={<AttendanceReport />} />
      {/* Departments moved to Company Admin (de1f547) -- the old
          HR alias now redirects like every other legacy path. HR
          browses the structure via the Org Chart. */}
      <Route path="/hr/admin/positions" element={<PositionsAdmin />} />
      <Route path="/hr/admin/leave-types" element={<LeaveTypesAdmin />} />
      <Route path="/hr/admin/team-members" element={<HrTeamMembersAdmin />} />
      <Route path="/hr/admin/payroll-approvers" element={<PayrollApproversAdmin />} />
    </Route>

    {/* Payroll approvals: deliberately NOT behind RequireModule
        module="hr" -- payroll_approvers is a separate,
        by-design non-HR grant (see 20260821090000_hr_team_and_
        payroll_approver_admin_rpcs.sql and the RLS fix in
        20260819141503_hr_payroll_approver_select_access.sql),
        so a designated approver who isn't HR staff must still
        reach this page. can_view_payroll_approvals() = is_hr_
        team_member() OR is_payroll_approver(). */}
    <Route element={<RequireRpcAccess rpc="can_view_payroll_approvals" />}>
      <Route path="/hr/payroll/approvals" element={<PayrollApprovals />} />
    </Route>
  </>
);
