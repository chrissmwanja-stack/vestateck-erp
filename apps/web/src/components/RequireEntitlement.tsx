import { Box, CircularProgress, Typography } from '@mui/material';
import { Outlet } from 'react-router-dom';
import { useMyModuleAccess } from '../features/navigation/useMyModuleAccess';
import type { ModuleKey } from './RequireModule';

/**
 * Route guard: the tenant must be entitled to `module` (a tenant_modules row).
 * Unlike RequireModule it does NOT check staff_roles, so it can sit inside
 * another guard (e.g. RequireFinanceTeam) to say "finance access, but only for
 * tenants that have this optional module" without locking out users who reach
 * the screen through a non-module authority.
 *
 * Platform admins pass, matching has_module_role() and the nav. While a
 * platform admin views as a specific user, the nav subject's tenant decides
 * (useMyModuleAccess), so the route and the nav agree. This is visibility and
 * consistency only; RLS remains the real data enforcement.
 *
 * Usage -- wraps a group of nested routes:
 *   <Route element={<RequireEntitlement module="procurement" />}>
 *     <Route path="/financial-management/purchase-orders" element={<PurchaseOrders />} />
 *   </Route>
 */
export default function RequireEntitlement({ module }: { module: ModuleKey }) {
  const access = useMyModuleAccess();

  if (!access) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (!access.isPlatformAdmin && !access.entitledModules.has(module)) {
    return (
      <Box sx={{ py: 8, textAlign: 'center' }}>
        <Typography variant="h6" gutterBottom>
          Not enabled for your company
        </Typography>
        <Typography variant="body2" color="text.secondary">
          This screen is part of a module your company has not opened. Contact your company admin if
          you believe this is a mistake.
        </Typography>
      </Box>
    );
  }

  return <Outlet />;
}
