// Company Admin (/company-admin/*): one customer company's governance.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{companyAdminRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireTenantAdmin from '../components/RequireTenantAdmin';
import CompanyAdminLayout from '../features/company-admin/CompanyAdminLayout';

const ApprovalWorkflowAdmin = lazy(() => import('../features/admin/ApprovalWorkflowAdmin'));
const CompanyAdminDashboard = lazy(() => import('../features/company-admin/CompanyAdminDashboard'));
const CompanySetupChecklist = lazy(() => import('../features/team/CompanySetupChecklist'));
const DepartmentsAdmin = lazy(() => import('../features/admin/DepartmentsAdmin'));
const InviteMember = lazy(() => import('../features/team/InviteMember'));
const OrganizationsAdmin = lazy(() => import('../features/admin/OrganizationsAdmin'));
const TeamMembersAdmin = lazy(() => import('../features/team/TeamMembersAdmin'));

export const companyAdminRoutes = (
  <>
    {/* COMPANY ADMIN -- layer 2 of the administration model:
        one customer company's own governance (organization,
        users & access, approval workflows), distinct from the
        platform console (/admin/*) and from per-module admin
        screens. RequireTenantAdmin is a real route guard
        (company admin or platform admin via View-as); the
        screens' own checks remain as a second layer. */}
    <Route element={<RequireTenantAdmin />}>
      <Route element={<CompanyAdminLayout />}>
        <Route path="/company-admin" element={<CompanyAdminDashboard />} />
        <Route path="/company-admin/organization/departments" element={<DepartmentsAdmin />} />
        <Route path="/company-admin/organization/organizations" element={<OrganizationsAdmin />} />
        <Route path="/company-admin/users/members" element={<TeamMembersAdmin />} />
        <Route path="/company-admin/users/invite" element={<InviteMember />} />
        <Route path="/company-admin/workflows/approvals" element={<ApprovalWorkflowAdmin />} />
        <Route path="/company-admin/setup" element={<CompanySetupChecklist />} />
      </Route>
    </Route>
  </>
);
