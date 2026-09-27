import { useEffect, useState } from 'react';
import { Alert } from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

interface TenantAccess {
  tenant_id: string;
  name: string;
  status: string;
  read_only: boolean;
  read_only_reason: string | null;
  plan: string;
  subscription_status: string;
  trial_ends_at: string | null;
}

// Customer-facing counterpart to the platform operator's lifecycle
// controls (Company Detail → Lifecycle). Mounted app-wide under the top
// bar. Reads get_my_tenant_access(), which resolves through
// get_my_tenant_id() -- so a platform admin using View-as sees exactly
// the banner the customer sees.
//
// Shows a persistent warning while the company is in read-only mode,
// with the operator's reason (every write is refused server-side by
// tenant_read_only_guard(); this banner explains *why* before the user
// hits a confusing error). Suspension is handled earlier, by RequireAuth,
// so it isn't repeated here.
//
// There is no self-serve trial in this product -- access is granted or
// revoked by the platform operator against an annual invoice, not a
// subscription clock -- so this deliberately does not surface
// trial_ends_at/subscription_status to the customer. Company Detail can
// still record those fields for the operator's own bookkeeping.
export default function TenantAccessBanner() {
  const [access, setAccess] = useState<TenantAccess | null>(null);

  useEffect(() => {
    let cancelled = false;
    supabase.rpc('get_my_tenant_access').then(({ data, error }) => {
      if (cancelled || error || !data) return;
      setAccess(data as unknown as TenantAccess);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  if (!access?.read_only) return null;

  return (
    <Alert severity="warning" sx={{ borderRadius: 0 }} data-testid="tenant-read-only-banner">
      <strong>{access.name} is in read-only mode.</strong> You can view everything but changes are not being
      accepted{access.read_only_reason ? ` — ${access.read_only_reason}` : '.'}
    </Alert>
  );
}
