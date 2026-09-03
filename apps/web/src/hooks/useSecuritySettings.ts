import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabaseClient';

export interface SecuritySettingsValue {
  sessionTimeoutMinutes: number;
  requireMfa: boolean;
  loading: boolean;
}

// Same defaults AdminSettingsPage.tsx assumes when platform_settings has
// no row yet -- keep these two in sync if either one changes.
const DEFAULTS: Omit<SecuritySettingsValue, 'loading'> = {
  sessionTimeoutMinutes: 60,
  requireMfa: false,
};

// Reads via get_security_settings() (SECURITY DEFINER), not a direct
// `.from('platform_settings')` select -- that table's RLS is
// platform-admin-only, so any other user's client would just get 0 rows
// back here and we'd silently be enforcing nothing.
export function useSecuritySettings(): SecuritySettingsValue {
  const [value, setValue] = useState<SecuritySettingsValue>({ ...DEFAULTS, loading: true });

  useEffect(() => {
    let cancelled = false;
    supabase
      .rpc('get_security_settings')
      .single()
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error || !data) {
          setValue({ ...DEFAULTS, loading: false });
          return;
        }
        const row = data as { session_timeout_minutes: number; require_mfa: boolean };
        setValue({
          sessionTimeoutMinutes: row.session_timeout_minutes ?? DEFAULTS.sessionTimeoutMinutes,
          requireMfa: row.require_mfa ?? DEFAULTS.requireMfa,
          loading: false,
        });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return value;
}