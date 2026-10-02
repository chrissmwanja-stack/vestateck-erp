// Unauthenticated routes (outside RequireAuth).
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{publicRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import LoginPage from '../features/auth/LoginPage';

const AcceptInvitePage = lazy(() => import('../features/auth/AcceptInvitePage'));
const BootstrapAdminPage = lazy(() => import('../features/auth/BootstrapAdminPage'));

export const publicRoutes = (
  <>
    <Route path="/login" element={<LoginPage />} />
    <Route path="/accept-invite" element={<AcceptInvitePage />} />
    <Route path="/bootstrap-admin" element={<BootstrapAdminPage />} />
  </>
);
