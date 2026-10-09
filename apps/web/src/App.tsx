import { Suspense } from 'react';
import { Link as RouterLink, Routes, Route, Navigate, useLocation } from 'react-router-dom';
import { AppBar, Box, Button, Container, IconButton, Toolbar, Typography, Tooltip } from '@mui/material';
import { DarkModeOutlined, LightModeOutlined } from '@mui/icons-material';
import { useBranding } from './lib/brandingContext';
import RequireAuth from './features/auth/RequireAuth';
import { useAuth } from './lib/authContext';
import { useThemeMode } from './lib/themeModeContext';
import ModuleTree from './features/navigation/ModuleTree';
import { isConsoleRoute } from './features/admin/consoleRoutes';
import { isCompanyAdminRoute } from './features/company-admin/CompanyAdminLayout';
import NotificationBell from './features/notifications/NotificationBell';
import ImpersonationBanner from './features/admin/ImpersonationBanner';
import AnnouncementBanner from './features/admin/AnnouncementBanner';
import TenantAccessBanner from './features/account/TenantAccessBanner';
import { publicRoutes } from './routes/publicRoutes';
import { coreRoutes } from './routes/coreRoutes';
import { platformAdminRoutes } from './routes/platformAdminRoutes';
import { companyAdminRoutes } from './routes/companyAdminRoutes';
import { legacyRoutes } from './routes/legacyRoutes';
import { financeRoutes } from './routes/financeRoutes';
import { procurementRoutes } from './routes/procurementRoutes';
import { itSupportRoutes } from './routes/itSupportRoutes';
import { businessDevelopmentRoutes } from './routes/businessDevelopmentRoutes';
import { lawComplianceRoutes } from './routes/lawComplianceRoutes';
import { hrRoutes } from './routes/hrRoutes';
import { machineOperationRoutes } from './routes/machineOperationRoutes';
import { pmoRoutes } from './routes/pmoRoutes';
import { sustainabilityRoutes } from './routes/sustainabilityRoutes';
import { insuranceRoutes } from './routes/insuranceRoutes';

function TopNav() {
  const { session, signOut } = useAuth();
  const { resolvedMode, toggle } = useThemeMode();
  const brand = useBranding();

  return (
     <>
    <AppBar position="static">
      <Toolbar sx={{ gap: 2 }}>
        <Box sx={{ flexGrow: 1, display: 'flex', alignItems: 'center', gap: 1.25, minWidth: 0 }}>
          {brand.logoUrl && (
            <Box component="img" src={brand.logoUrl} alt="" sx={{ height: 28, maxWidth: 140, objectFit: 'contain' }} />
          )}
          <Typography variant="h6" noWrap>
            {brand.platformName}
          </Typography>
        </Box>
        <Tooltip title={resolvedMode === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}>
          <IconButton color="inherit" onClick={toggle} aria-label="Toggle dark mode">
            {resolvedMode === 'dark' ? <LightModeOutlined /> : <DarkModeOutlined />}
          </IconButton>
        </Tooltip>
        {session && (
          <>
            <Button color="inherit" component={RouterLink} to="/delegations">
              Delegations
            </Button>
            <NotificationBell userId={session.user.id} />
            <Typography variant="body2" sx={{ opacity: 0.8 }}>
              {session.user.email}
            </Typography>
            <Button color="inherit" onClick={() => signOut()}>
              Sign out
            </Button>
          </>
        )}
      </Toolbar>
    </AppBar>
      {session && <ImpersonationBanner />}
      {session && <AnnouncementBanner />}
      {session && <TenantAccessBanner />}
    </>
  );
}

function RouteFallback() {
  return (
    <Box sx={{ display: 'flex', justifyContent: 'center', mt: 6 }}>
      <Typography variant="body2" sx={{ opacity: 0.6 }}>
        Loading…
      </Typography>
    </Box>
  );
}

export default function App() {
  const { session } = useAuth();
  const location = useLocation();
  // The tenant ModuleTree lists one company's modules -- meaningless
  // outside a company, so it's swapped out (not just hidden) whenever
  // we're inside one of the two admin shells: the platform console
  // (AdminLayout, /admin/*) or Company Admin (CompanyAdminLayout,
  // /company-admin/*). Each shell supplies its own left rail + header;
  // the route lists live with the shells so this check can't drift
  // from the routes that are wrapped.
  const isAdminShellRoute = isConsoleRoute(location.pathname) || isCompanyAdminRoute(location.pathname);
  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', minHeight: '100vh' }}>
      <TopNav />
      <Box sx={{ display: 'flex', flex: 1 }}>
        {session && !isAdminShellRoute && <ModuleTree />}
        <Container
          component="main"
          disableGutters={isAdminShellRoute}
          sx={{ mt: isAdminShellRoute ? 0 : 3, mb: isAdminShellRoute ? 0 : 6, flexGrow: 1, maxWidth: '100%', px: isAdminShellRoute ? 0 : 4 }}
        >
          <Suspense fallback={<RouteFallback />}>
          <Routes>
            {publicRoutes}
            <Route element={<RequireAuth />}>
              {coreRoutes}
              {platformAdminRoutes}
              {companyAdminRoutes}
              {legacyRoutes}
              {financeRoutes}
              {procurementRoutes}
              {itSupportRoutes}
              {businessDevelopmentRoutes}
              {lawComplianceRoutes}
              {hrRoutes}
              {machineOperationRoutes}
              {pmoRoutes}
              {sustainabilityRoutes}
              {insuranceRoutes}
            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
          </Suspense>
        </Container>
      </Box>
    </Box>
  );
}
