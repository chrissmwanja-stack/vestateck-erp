import { useEffect, useState } from 'react';
import { Box, CircularProgress, Typography, Button } from '@mui/material';
import { Link as RouterLink } from 'react-router-dom';
import { Outlet } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';
import { useAuth } from '../lib/authContext';

type AccessState = 'loading' | 'allowed' | 'denied';

function usePlatformAdminAccess(): AccessState {
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
      .from('app_users')
      .select('is_platform_admin')
      .eq('id', session.user.id)
      .maybeSingle()
      .then(({ data, error }) => {
        if (cancelled) return;
        setState(!error && data?.is_platform_admin ? 'allowed' : 'denied');
      });
    return () => {
      cancelled = true;
    };
  }, [session?.user?.id, authLoading]);

  return state;
}

export default function RequirePlatformAdmin() {
  const access = usePlatformAdminAccess();

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
          Platform admin only
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
          This area is reserved for the VestaPortal platform team. If you believe this is a mistake, contact your platform admin.
        </Typography>
        <Button component={RouterLink} to="/" variant="outlined">
          Go to my workspace
        </Button>
      </Box>
    );
  }

  return <Outlet />;
}