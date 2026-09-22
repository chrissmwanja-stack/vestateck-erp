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
// Shows:
//   * a persistent warning while the company is in read-only mode, with
//     the operator's reason (every write is refused server-side by
//     tenant_read_only_guard(); this banner explains *why* before the
//     user hits a confusing error);
//   * a soft heads-up during the last 7 days of a trial.
// Suspension is handled earlier, by RequireAuth, so it isn't repeated here.
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

  if (!access) return null;

  const trialDays = trialDaysLeft(access);

  return (
    <>
      {access.read_only && (
        <Alert severity="warning" sx={{ borderRadius: 0 }} data-testid="tenant-read-only-banner">
          <strong>{access.name} is in read-only mode.</strong> You can view everything but changes are not being
          accepted{access.read_only_reason ? ` — ${access.read_only_reason}` : '.'}
        </Alert>
      )}
      {trialDays !== null && (
        <Alert severity="info" sx={{ borderRadius: 0 }} data-testid="tenant-trial-banner">
          {trialDays <= 0
            ? 'Your trial period has ended. Contact your account manager to keep full access.'
            : `Your trial ends in ${trialDays} day${trialDays === 1 ? '' : 's'}.`}
        </Alert>
      )}
    </>
  );
}

// Returns days left when the trial banner should show (≤ 7 days, or
// already over), otherwise null. Exported for tests.
export function trialDaysLeft(access: Pick<TenantAccess, 'subscription_status' | 'trial_ends_at'>, now = new Date()): number | null {
  if (access.subscription_status !== 'trialing' || !access.trial_ends_at) return null;
  const days = Math.ceil((new Date(access.trial_ends_at).getTime() - now.getTime()) / 86_400_000);
  return days <= 7 ? days : null;
}
