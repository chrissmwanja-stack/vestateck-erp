import { useCallback, useEffect, useState } from 'react';
import { Alert, Button, CircularProgress, Typography } from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

interface ActiveImpersonation {
  tenant_id: string;
  tenant_name: string;
  reason?: string | null;
  started_at?: string;
  expires_at?: string | null;
}

// Shown app-wide (mounted in TopNav) whenever the current platform admin
// has an active impersonation session. get_my_tenant_id() already
// resolves to the impersonated tenant server-side for every RLS check,
// so this banner is purely a "you are not looking at your own data"
// signal + an exit hatch -- it isn't what makes impersonation work.
//
// Since 20260922160000 the session carries the operator's reason and a
// hard expires_at; both are shown here so the person acting knows what
// they said they were doing and how long they have. When the clock runs
// out the banner exits the session client-side too, so the UI doesn't
// linger in a "viewing as" state the server has already stopped honouring.
export default function ImpersonationBanner() {
  const [active, setActive] = useState<ActiveImpersonation | null | 'loading'>('loading');
  const [ending, setEnding] = useState(false);
  const [now, setNow] = useState(() => Date.now());

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

  // Tick once a minute while a session is active so the remaining time
  // stays honest without hammering the server.
  useEffect(() => {
    if (!active || active === 'loading') return;
    const id = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(id);
  }, [active]);

  const handleExit = useCallback(async () => {
    setEnding(true);
    await supabase.rpc('end_impersonation');
    setEnding(false);
    // Full reload so every screen re-fetches under the real tenant
    // context rather than trying to reconcile stale impersonated state.
    window.location.href = '/admin/companies';
  }, []);

  const expiresMs = active && active !== 'loading' && active.expires_at ? Date.parse(active.expires_at) : null;
  const remainingMin = expiresMs ? Math.max(0, Math.round((expiresMs - now) / 60_000)) : null;

  useEffect(() => {
    if (remainingMin === 0 && !ending) {
      handleExit();
    }
  }, [remainingMin, ending, handleExit]);

  if (active === 'loading' || active === null) return null;

  const remainingLabel =
    remainingMin === null
      ? null
      : remainingMin >= 60
        ? `${Math.floor(remainingMin / 60)}h ${remainingMin % 60}m left`
        : `${remainingMin}m left`;

  return (
    <Alert
      severity="warning"
      variant="filled"
      sx={{ borderRadius: 0, alignItems: 'center' }}
      action={
        <Button color="inherit" size="small" onClick={handleExit} disabled={ending}>
          {ending ? <CircularProgress size={16} color="inherit" /> : 'Exit'}
        </Button>
      }
    >
      Viewing as <strong>{active.tenant_name}</strong> — actions you take affect this
      company&apos;s data.
      {(active.reason || remainingLabel) && (
        <Typography component="span" variant="body2" sx={{ display: 'block', opacity: 0.9 }}>
          {active.reason ? `Reason: ${active.reason}` : null}
          {active.reason && remainingLabel ? ' · ' : null}
          {remainingLabel}
        </Typography>
      )}
    </Alert>
  );
}
