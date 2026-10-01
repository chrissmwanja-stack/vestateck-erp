import { Box, CircularProgress, Typography, Button } from '@mui/material';
import { Link as RouterLink, Outlet } from 'react-router-dom';
import { useTenantAdminAccess } from '../features/team/useTenantAdminAccess';
import { useMyModuleAccess } from '../features/navigation/useMyModuleAccess';

// Route guard for the Company Administration area (/company-admin/*):
// the tenant's company admin, or a platform admin who is inside a company
// via View-as. Mirrors RequirePlatformAdmin's shape. This is nav-level
// defense only -- the screens' own checks and the server-side RPC/RLS
// rules (is_tenant_admin() etc.) remain the real enforcement.
//
// A platform admin who is NOT viewing as a company is refused here. These
// screens act on get_my_tenant_id(), which for an operator outside View-as
// is the reserved platform home tenant -- editing it would be meaningless
// at best and would silently change the wrong company's data at worst. The
// nav already hides the portal in that mode (useMyModuleAccess); this makes
// the route agree with the nav, so a pasted URL cannot get around it.
export default function RequireTenantAdmin() {
  const access = useTenantAdminAccess();
  const nav = useMyModuleAccess();

  if (!access || !nav) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (access.isAdmin && nav.isPlatformAdmin && !nav.isImpersonating) {
    return (
      <Box sx={{ py: 8, textAlign: 'center' }}>
        <Typography variant="h6" gutterBottom>
          Open a company first
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2, maxWidth: 480, mx: 'auto' }}>
          Company administration belongs to each customer company. Use <b>View as</b> on a company in the
          platform console to administer it.
        </Typography>
        <Button component={RouterLink} to="/admin/companies" variant="outlined">
          Go to companies
        </Button>
      </Box>
    );
  }

  if (!access.isAdmin) {
    return (
      <Box sx={{ py: 8, textAlign: 'center' }}>
        <Typography variant="h6" gutterBottom>
          Company admin only
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2, maxWidth: 480, mx: 'auto' }}>
          Company administration — organization, users &amp; access, approval workflows — is reserved for your
          company&apos;s admin. Ask them if something here needs changing.
        </Typography>
        <Button component={RouterLink} to="/" variant="outlined">
          Back to my workspace
        </Button>
      </Box>
    );
  }

  return <Outlet />;
}
