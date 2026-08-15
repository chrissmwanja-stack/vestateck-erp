import { useEffect, useState } from 'react';
import { Alert, Box, Button, CircularProgress, Stack, Typography } from '@mui/material';
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';

// Complements the get_my_tenant_id() suspension lockout (backend):
// once a tenant is suspended, every tenant-scoped RLS policy already
// denies that tenant's users -- but without this, they'd just see a
// blank/broken app full of failed queries with no explanation. This
// checks get_my_tenant_status() (which deliberately bypasses
// get_my_tenant_id() so it stays readable even when the user is
// locked out) and shows a clear message instead of the app shell.
//
// Platform admins are never blocked here: their own app_users row
// belongs to a dedicated, always-active platform tenant, so this
// check passes for them regardless of which tenant they're
// impersonating.
function useTenantStatus(session: unknown) {
  const [status, setStatus] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!session) {
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    supabase
      .rpc('get_my_tenant_status')
      .then(({ data, error }) => {
        if (cancelled) return;
        setStatus(error ? null : (data as string | null));
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [session]);

  return { status, loading };
}

export default function RequireAuth() {
  const { session, loading, signOut } = useAuth();
  const location = useLocation();
  const { status: tenantStatus, loading: statusLoading } = useTenantStatus(session);

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (!session) {
    return <Navigate to="/login" state={{ from: location }} replace />;
  }

  if (statusLoading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (tenantStatus === 'suspended') {
    return (
      <Box sx={{ maxWidth: 480, mx: 'auto', mt: 8 }}>
        <Stack spacing={2}>
          <Alert severity="warning">Your company's access has been suspended.</Alert>
          <Typography variant="body2" color="text.secondary">
            Contact your company admin or Vestateck support if you believe this is a mistake.
          </Typography>
          <Button variant="outlined" onClick={() => signOut()} sx={{ alignSelf: 'flex-start' }}>
            Sign out
          </Button>
        </Stack>
      </Box>
    );
  }

  return <Outlet />;
}