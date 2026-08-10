import { useCallback, useEffect, useState } from 'react';
import { Alert, Button, CircularProgress } from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

interface ActiveImpersonation {
  tenant_id: string;
  tenant_name: string;
}

// Shown app-wide (mounted in TopNav) whenever the current platform admin
// has an active impersonation session. get_my_tenant_id() already
// resolves to the impersonated tenant server-side for every RLS check,
// so this banner is purely a "you are not looking at your own data"
// signal + an exit hatch -- it isn't what makes impersonation work.
export default function ImpersonationBanner() {
  const [active, setActive] = useState<ActiveImpersonation | null | 'loading'>('loading');
  const [ending, setEnding] = useState(false);

  const refresh = useCallback(async () => {
    const { data, error } = await supabase.rpc('get_active_impersonation');
    if (error) {
      setActive(null);
      return;
    }
    const row = Array.isArray(data) ? data[0] : data;
    setActive(row ?? null);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  if (active === 'loading' || active === null) return null;

  const handleExit = async () => {
    setEnding(true);
    await supabase.rpc('end_impersonation');
    setEnding(false);
    // Full reload so every screen re-fetches under the real tenant
    // context rather than trying to reconcile stale impersonated state.
    window.location.href = '/admin/companies';
  };

  return (
    <Alert
      severity="warning"
      variant="filled"
      sx={{ borderRadius: 0 }}
      action={
        <Button color="inherit" size="small" onClick={handleExit} disabled={ending}>
          {ending ? <CircularProgress size={16} color="inherit" /> : 'Exit'}
        </Button>
      }
    >
      Viewing as <strong>{active.tenant_name}</strong> — actions you take affect this
      company's data.
    </Alert>
  );
}