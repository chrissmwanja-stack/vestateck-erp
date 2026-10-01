import { Box, CircularProgress, Typography, Button } from '@mui/material';
import { Link as RouterLink, Outlet } from 'react-router-dom';
import { useTenantAdminAccess } from '../features/team/useTenantAdminAccess';

// Route guard for the Company Administration area (/company-admin/*):
// the tenant's company admin, or a platform admin (who reaches it via
// View-as). Mirrors RequirePlatformAdmin's shape. This is nav-level
// defense only -- the screens' own checks and the server-side RPC/RLS
// rules (is_tenant_admin() etc.) remain the real enforcement.
export default function RequireTenantAdmin() {
  const access = useTenantAdminAccess();

  if (!access) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
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
