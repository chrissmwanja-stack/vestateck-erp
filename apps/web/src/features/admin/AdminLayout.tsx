import { Box, IconButton, Stack, Tooltip, Typography } from '@mui/material';
import { AdminPanelSettings, ArrowBack, Settings as SettingsIcon } from '@mui/icons-material';
import { Link as RouterLink, Outlet, matchPath, useLocation, useNavigate } from 'react-router-dom';

// The tenant-facing shell (teal top bar, ModuleTree of that company's
// modules) is deliberately the same for every company -- that sameness
// is the point, it's one product. Platform administration isn't inside
// any company, so it gets its own strip rather than borrowing that
// chrome: ochre is reserved elsewhere in the theme purely for
// highlights/active states (see theme.ts), so lighting it up here reads
// as "you've stepped out of a company and into the tower that oversees
// all of them" rather than introducing an unrelated new color.
//
// Kept as a border + text accent, not a filled ochre bar -- a filled
// warm-colored banner is already ImpersonationBanner's job (MUI Alert,
// severity="warning", filled), and this needs to read as a distinct
// permanent section of the app, not a transient alert.
//
// Back nav used to be hardcoded to "always → /admin/companies", which
// was only ever correct for exactly one screen (Company Detail) and
// silently wrong for every other subpage added since (it would have
// told Settings to go "back to all companies"). This is now a single
// route table, so every /admin/* subpage's back target lives in one
// place instead of being reimplemented per-page (CompanyDetail used to
// carry its own separate "Back to Companies" link in-body -- removed,
// this header is now the only back nav for the section).
interface AdminRouteConfig {
  pattern: string;
  label: string;
  backTo?: string; // omit for the section root (no back arrow shown)
}

// Note: /admin itself (PlatformDashboard) isn't wrapped by AdminLayout --
// it has its own header already -- so every route AdminLayout actually
// renders for has a real back target; there's no "root" case in practice.
const ADMIN_ROUTES: AdminRouteConfig[] = [
  { pattern: '/admin/companies', label: 'Companies', backTo: '/admin' },
  { pattern: '/admin/companies/:tenantId', label: 'Company Detail', backTo: '/admin/companies' },
  { pattern: '/admin/settings', label: 'Settings', backTo: '/admin' },
];

function resolveAdminRoute(pathname: string): AdminRouteConfig {
  const match = ADMIN_ROUTES.find((route) => matchPath({ path: route.pattern, end: true }, pathname));
  return match ?? { pattern: pathname, label: 'Platform Administration', backTo: '/admin' };
}

export default function AdminLayout() {
  const location = useLocation();
  const navigate = useNavigate();
  const current = resolveAdminRoute(location.pathname);
  const isRoot = !current.backTo;

  return (
    <Box sx={{ mb: 3 }}>
      <Stack
        direction="row"
        alignItems="center"
        justifyContent="space-between"
        sx={{
          borderBottom: (theme) => `2px solid ${theme.palette.secondary.main}`,
          pb: 1.5,
          mb: 3,
        }}
      >
        <Stack direction="row" alignItems="center" spacing={1}>
          {!isRoot && (
            <IconButton
              size="small"
              aria-label="Back"
              onClick={() => navigate(current.backTo as string)}
              sx={{ border: '1px solid', borderColor: 'divider', mr: 0.5 }}
            >
              <ArrowBack fontSize="small" />
            </IconButton>
          )}
          <AdminPanelSettings sx={{ color: 'secondary.main', fontSize: 20 }} />
          <Box>
            <Typography
              variant="overline"
              sx={{
                color: 'secondary.main',
                fontWeight: 700,
                letterSpacing: 1.2,
                lineHeight: 1.2,
                display: 'block',
              }}
            >
              {isRoot ? 'Platform Administration' : current.label}
            </Typography>
            {isRoot ? (
              <Typography variant="caption" color="text.secondary">
                Overseeing every company on VestaPortal
              </Typography>
            ) : (
              <Typography
                component={RouterLink}
                to={current.backTo as string}
                variant="caption"
                color="text.secondary"
                sx={{ textDecoration: 'none', '&:hover': { textDecoration: 'underline' } }}
              >
                ← Back
              </Typography>
            )}
          </Box>
        </Stack>

        {location.pathname !== '/admin/settings' && (
          <Tooltip title="Platform settings">
            <IconButton size="small" component={RouterLink} to="/admin/settings" aria-label="Platform settings">
              <SettingsIcon fontSize="small" />
            </IconButton>
          </Tooltip>
        )}
      </Stack>
      <Outlet />
    </Box>
  );
}