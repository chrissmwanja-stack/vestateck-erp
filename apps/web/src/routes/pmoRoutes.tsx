// PMO: member tier and project approvals (PMO_ADMIN_ROLES).
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{pmoRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';
import { PMO_ADMIN_ROLES } from '../modules/portals/pmo/access';

const BudgetVsActualReport = lazy(() => import('../modules/portals/pmo/pages/reports/BudgetVsActualReport'));
const GanttChart = lazy(() => import('../modules/portals/pmo/pages/tasks/GanttChart'));
const MilestonesList = lazy(() => import('../modules/portals/pmo/pages/tasks/MilestonesList'));
const NewProject = lazy(() => import('../modules/portals/pmo/pages/projects/NewProject'));
const PMOApprovals = lazy(() => import('../modules/portals/pmo/pages/projects/PMOApprovals'));
const PMODashboard = lazy(() => import('../modules/portals/pmo/pages/PMODashboard'));
const ProjectCategoriesAdmin = lazy(() => import('../modules/portals/pmo/pages/admin/ProjectCategoriesAdmin'));
const ProjectDetail = lazy(() => import('../modules/portals/pmo/pages/projects/ProjectDetail'));
const ProjectStatusReport = lazy(() => import('../modules/portals/pmo/pages/reports/ProjectStatusReport'));
const ProjectsList = lazy(() => import('../modules/portals/pmo/pages/projects/ProjectsList'));
const ResourceAllocation = lazy(() => import('../modules/portals/pmo/pages/resources/ResourceAllocation'));
const ResourceUtilization = lazy(() => import('../modules/portals/pmo/pages/resources/ResourceUtilization'));
const TaskTypesAdmin = lazy(() => import('../modules/portals/pmo/pages/admin/TaskTypesAdmin'));
const TasksList = lazy(() => import('../modules/portals/pmo/pages/tasks/TasksList'));

export const pmoRoutes = (
  <>
    {/* PMO - 100% REAL NOW */}
    <Route element={<RequireModule module="pmo" />}>
      <Route path="/pmo/dashboard" element={<PMODashboard />} />
      <Route path="/pmo/projects" element={<ProjectsList />} />
      <Route path="/pmo/projects/new" element={<NewProject />} />
      <Route path="/pmo/projects/:id" element={<ProjectDetail />} />
      <Route path="/pmo/tasks" element={<TasksList />} />
      <Route path="/pmo/milestones" element={<MilestonesList />} />
      <Route path="/pmo/gantt" element={<GanttChart />} />
      <Route path="/pmo/resources/allocation" element={<ResourceAllocation />} />
      <Route path="/pmo/resources/utilization" element={<ResourceUtilization />} />
      <Route path="/pmo/reports/status" element={<ProjectStatusReport />} />
      <Route path="/pmo/reports/budget" element={<BudgetVsActualReport />} />
      <Route path="/pmo/admin/categories" element={<ProjectCategoriesAdmin />} />
      <Route path="/pmo/admin/task-types" element={<TaskTypesAdmin />} />
    </Route>

    {/* Project approvals: admin/manager tier (same split as legal
        contracts and BD proposals), enforced again by
        decide_pmo_project() server-side along with the
        no-self-approval rule. */}
    <Route element={<RequireModule module="pmo" roles={PMO_ADMIN_ROLES} />}>
      <Route path="/pmo/approvals" element={<PMOApprovals />} />
    </Route>
  </>
);
