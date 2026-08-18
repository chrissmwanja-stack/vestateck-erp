import { Box, Stack, Typography } from '@mui/material';
import { AdminPanelSettings } from '@mui/icons-material';
import { Link as RouterLink, Outlet, useLocation } from 'react-router-dom';

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
export default function AdminLayout() {
  const location = useLocation();
  const isDetail = location.pathname !== '/admin/companies';

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
              Platform Administration
            </Typography>
            {isDetail ? (
              <Typography
                component={RouterLink}
                to="/admin/companies"
                variant="caption"
                color="text.secondary"
                sx={{ textDecoration: 'none', '&:hover': { textDecoration: 'underline' } }}
              >
                ← Back to all companies
              </Typography>
            ) : (
              <Typography variant="caption" color="text.secondary">
                Overseeing every company on VestaPortal
              </Typography>
            )}
          </Box>
        </Stack>
      </Stack>
      <Outlet />
    </Box>
  );
}