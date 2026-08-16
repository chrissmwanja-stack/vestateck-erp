import { useEffect, useState } from 'react';
import { Box, CircularProgress, Typography } from '@mui/material';
import { Outlet } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';
import { useAuth } from '../lib/authContext';

type AccessState = 'loading' | 'allowed' | 'denied';

function useFinanceAccess(): AccessState {
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
    // can_access_finance() is SECURITY DEFINER and already treats
    // is_platform_admin as an automatic pass on both underlying checks --
    // no need to special-case platform admins here.
    supabase
      .rpc('can_access_finance')
      .then(({ data, error }) => {
        if (cancelled) return;
        setState(!error && data ? 'allowed' : 'denied');
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.user?.id, authLoading]);

  return state;
}

/**
 * Route guard for the finance/admin screens (Financial Management, Purchase
 * Orders, SAP Payment Approvals, and the finance-only admin/lookup screens).
 *
 * Unlike RequireModule, this isn't backed by staff_roles/tenant_modules --
 * finance access is the OR of two pre-existing, independent checks:
 *   - is_finance_team_member(): membership in finance_team_members
 *   - has_po_access(): assigned (or delegated) as approver at the terminal
 *     "Finance" workflow stage
 * See can_access_finance() (20260816_add_can_access_finance_route_guard_fn)
 * for details on why both are OR'd rather than picking one.
 *
 * Usage — wraps a group of nested routes:
 *   <Route element={<RequireFinanceTeam />}>
 *     <Route path="/financial-management/dashboard" element={<FinancialDashboard />} />
 *     ...
 *   </Route>
 */
export default function RequireFinanceTeam() {
  const access = useFinanceAccess();

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
          You don't have finance access in your tenant. Contact your company admin if you
          believe this is a mistake.
        </Typography>
      </Box>
    );
  }

  return <Outlet />;
}