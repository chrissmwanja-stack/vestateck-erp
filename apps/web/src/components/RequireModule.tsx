import { useEffect, useState } from 'react';
import { Box, CircularProgress, Typography } from '@mui/material';
import { Outlet } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';
import { useAuth } from '../lib/authContext';

// Keep in sync with the staff_roles.module CHECK constraint
// (see 0001_init_core_schema.sql + later module-add migrations).
export type ModuleKey = 'hr' | 'legal' | 'bd' | 'it' | 'pmo' | 'machine_operation' | 'sustainability';

const DEFAULT_ROLES = ['admin', 'manager', 'member'] as const;

type AccessState = 'loading' | 'allowed' | 'denied';

function useModuleAccess(module: ModuleKey, roles: readonly string[]): AccessState {
  const { session, loading: authLoading } = useAuth();
  const [state, setState] = useState<AccessState>('loading');
  const rolesKey = roles.join(',');

  useEffect(() => {
    if (authLoading) return;
    if (!session?.user?.id) {
      setState('denied');
      return;
    }
    let cancelled = false;
    setState('loading');
    // has_module_role is SECURITY DEFINER and already treats
    // app_users.is_platform_admin as an automatic pass -- no need to
    // special-case platform admins here.
    supabase
      .rpc('has_module_role', { p_module: module, p_roles: rolesKey.split(',') })
      .then(({ data, error }) => {
        if (cancelled) return;
        setState(!error && data ? 'allowed' : 'denied');
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.user?.id, authLoading, module, rolesKey]);

  return state;
}

/**
 * Route guard for module-scoped portals (HR, Law & Compliance, Business
 * Development, IT Support, Machine Operation, PMO, Sustainability).
 *
 * Usage — wraps a group of nested routes for one module:
 *   <Route element={<RequireModule module="hr" />}>
 *     <Route path="/hr/dashboard" element={<HRDashboard />} />
 *     ...
 *   </Route>
 *
 * Pass `roles` to require a specific role (e.g. admin-only admin/lookup
 * screens); defaults to "any role in this module".
 */
export default function RequireModule({
  module,
  roles = DEFAULT_ROLES,
}: {
  module: ModuleKey;
  roles?: readonly string[];
}) {
  const access = useModuleAccess(module, roles);

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
          You don't have access to this module in your tenant. Contact your company admin if you
          believe this is a mistake.
        </Typography>
      </Box>
    );
  }

  return <Outlet />;
}