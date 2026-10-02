// Platform console (/admin/*). One route table: features/admin/consoleRoutes.tsx.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{platformAdminRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequirePlatformAdmin from '../components/RequirePlatformAdmin';
import { CONSOLE_ROUTES } from '../features/admin/consoleRoutes';

const AdminLayout = lazy(() => import('../features/admin/AdminLayout'));

export const platformAdminRoutes = (
  <>
    {/* PLATFORM ADMIN -- distinct from every company workspace.
        RequirePlatformAdmin is an actual route guard (shows a
        "not allowed" screen), not just a screen-level check --
        the underlying get_platform_dashboard_stats RPC is also
        gated server-side via is_platform_admin(), so this is
        belt-and-braces rather than the only line of defense. */}
    <Route element={<RequirePlatformAdmin />}>
      {/* Every console screen -- Overview included -- renders
          inside AdminLayout's persistent left rail. Tenant-admin
          screens (/setup, /team/*, /admin/approval-workflow) are
          deliberately NOT here: they belong to a customer
          workspace and are reached via View-as. */}
      <Route element={<AdminLayout />}>
        {/* The console's ONE route table lives in
            features/admin/consoleRoutes.tsx -- the same table that
            builds AdminLayout's rail and the ModuleTree portal. */}
        {CONSOLE_ROUTES.map(({ pattern, Component }) => (
          <Route key={pattern} path={pattern} element={<Component />} />
        ))}
      </Route>
    </Route>
  </>
);
