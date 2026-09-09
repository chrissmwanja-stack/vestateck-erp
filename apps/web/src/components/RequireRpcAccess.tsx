import { useEffect, useState } from 'react';
import { Box, CircularProgress, Typography } from '@mui/material';
import { Outlet } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';
import { useAuth } from '../lib/authContext';

type AccessState = 'loading' | 'allowed' | 'denied';

function useRpcAccess(rpcName: string): AccessState {
  const { session, loading: authLoading } = useAuth();
  const [state, setState] = useState<AccessState>('loading');

  useEffect(() => {
    if (authLoading) return;
    if (!session?.user?.id) {
      setState('denied');
      return;
    }
    let cancelled = false;
    setState('loading');
    supabase
      .rpc(rpcName)
      .then(({ data, error }) => {
        if (cancelled) return;
        setState(!error && data ? 'allowed' : 'denied');
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.user?.id, authLoading, rpcName]);

  return state;
}

/**
 * Route guard for access checks that don't fit the module/role shape
 * RequireModule covers -- e.g. a screen that a designated non-module
 * approver should reach (payroll approvals: is_hr_team_member() OR
 * is_payroll_approver(), via can_view_payroll_approvals()).
 *
 * Usage:
 *   <Route element={<RequireRpcAccess rpc="can_view_payroll_approvals" />}>
 *     <Route path="/hr/payroll/approvals" element={<PayrollApprovals />} />
 *   </Route>
 *
 * `rpc` must name a no-argument SECURITY DEFINER function returning
 * boolean.
 */
export default function RequireRpcAccess({ rpc }: { rpc: string }) {
  const access = useRpcAccess(rpc);

  if (access === 'loading') {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (access === 'denied') {
    return (
      <Box sx={{ py: 8, textAlign: 'center' }}>
        <Typography variant="h6" gutterBottom>
          Not available to you
        </Typography>
        <Typography variant="body2" color="text.secondary">
          You don't have access to this page. Contact your company admin if you believe this is a
          mistake.
        </Typography>
      </Box>
    );
  }

  return <Outlet />;
}
