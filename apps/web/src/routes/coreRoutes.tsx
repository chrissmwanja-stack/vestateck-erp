// Cross-module routes every signed-in user can reach: landing redirect,
// MFA enrolment, requests, approvals, delegations, multiplexing.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{coreRoutes}`.

import { lazy } from 'react';
import { Box, CircularProgress } from '@mui/material';
import { Navigate, Route } from 'react-router-dom';
import { useAuth } from '../lib/authContext';
import { usePlatformAdminAccess } from '../lib/usePlatformAdminAccess';

const AccountSecurity = lazy(() => import('../features/account/AccountSecurity'));
const ApprovalQueue = lazy(() => import('../features/approvals/ApprovalQueue'));
const DelegationManager = lazy(() => import('../features/delegations/DelegationManager'));
const InvoiceApprovalQueue = lazy(() => import('../features/multiplexing/InvoiceApprovalQueue'));
const InvoiceSubmissionForm = lazy(() => import('../features/multiplexing/InvoiceSubmissionForm'));
const MyApprovals = lazy(() => import('../features/approvals/MyApprovals'));
const MyRequests = lazy(() => import('../features/requests/MyRequests'));
const NewMaterialRequest = lazy(() => import('../features/requests/NewMaterialRequest'));
const RequestSubmissionForm = lazy(() => import('../features/requests/RequestSubmissionForm'));

// Platform admins aren't part of any company, so "submit a material
// request" (everyone else's landing page) isn't a meaningful home for
// them -- they land on the companies dashboard instead. isPlatformAdmin
// is null while the app_users lookup is still in flight; hold the
// redirect until it resolves so an admin never flashes through
// /requests/new first.
function RootRedirect() {
  const isPlatformAdmin = usePlatformAdminAccess();
  if (isPlatformAdmin === null) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', mt: 6 }}>
        <CircularProgress size={24} />
      </Box>
    );
  }
  return <Navigate to={isPlatformAdmin ? '/admin' : '/requests/new'} replace />;
}

function DelegationsRoute() {
  const { session } = useAuth();
  return session ? <DelegationManager userId={session.user.id} /> : null;
}

export const coreRoutes = (
  <>
    <Route path="/" element={<RootRedirect />} />
    {/* MFA enrolment. RequireAuth redirects here when require_mfa
        is on and the user has no verified factor -- this route
        was missing, so that redirect used to fall through to "*"
        and bounce back to "/" in a loop. */}
    <Route path="/account/security" element={<AccountSecurity />} />
    <Route path="/requests/new" element={<RequestSubmissionForm />} />
    <Route path="/approvals" element={<ApprovalQueue />} />
    {/* Cross-module aggregator -- see list_my_approval_surfaces()
        (20260909080000_my_approval_surfaces.sql). Ungated at the
        route level like /approvals: the page itself only ever
        lists surfaces the RPC says this user can already reach,
        so anyone landing here with nothing to approve just sees
        an empty state, not a "not available to you" bounce. */}
    <Route path="/my-approvals" element={<MyApprovals />} />
    <Route
      path="/delegations"
      element={<DelegationsRoute />}
    />
    <Route path="/multiplexing/approvals" element={<InvoiceApprovalQueue />} />
    <Route path="/multiplexing/invoice-new" element={<InvoiceSubmissionForm />} />
    <Route path="/requests/my-requests" element={<MyRequests />} />
    <Route path="/requests/new-material" element={<NewMaterialRequest />} />
  </>
);
