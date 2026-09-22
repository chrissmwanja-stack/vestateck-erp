import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';

// Server-side truth for "can this session perform privileged platform
// actions right now". Mirrors require_platform_admin() in
// 20260922160000_platform_audit_and_impersonation_hardening.sql:
//
//   can_act = is_platform_admin AND (no verified TOTP factor OR session is aal2)
//
// The UI uses it to (a) disable suspend/modules/impersonate buttons with a
// "step up with MFA" hint instead of letting the RPC fail, and (b) nag an
// un-enrolled operator to enrol. It is advisory only -- the RPCs enforce
// the same rule regardless of what the client thinks.
export interface PlatformAdminSession {
  isPlatformAdmin: boolean;
  hasMfaFactor: boolean;
  sessionIsMfa: boolean;
  canAct: boolean;
}

const DENIED: PlatformAdminSession = {
  isPlatformAdmin: false,
  hasMfaFactor: false,
  sessionIsMfa: false,
  canAct: false,
};

export function usePlatformAdminSession() {
  const [state, setState] = useState<PlatformAdminSession | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('get_platform_admin_session');
    if (err) {
      setError(err.message);
      setState(DENIED);
      return;
    }
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) {
      setState(DENIED);
      return;
    }
    setError(null);
    setState({
      isPlatformAdmin: Boolean(row.is_platform_admin),
      hasMfaFactor: Boolean(row.has_mfa_factor),
      sessionIsMfa: Boolean(row.session_is_mfa),
      canAct: Boolean(row.can_act),
    });
  }, []);

  useEffect(() => {
    refresh();
    const { data: sub } = supabase.auth.onAuthStateChange(() => {
      refresh();
    });
    return () => sub.subscription.unsubscribe();
  }, [refresh]);

  return { session: state, loading: state === null, error, refresh };
}

// Human copy for the two ways a privileged action can be blocked. Shared
// by buttons' tooltips and by the RPC error mapper below.
export function describeBlockedReason(s: PlatformAdminSession | null): string | null {
  if (!s) return null;
  if (!s.isPlatformAdmin) return 'Platform admin only.';
  if (s.hasMfaFactor && !s.sessionIsMfa) {
    return 'This session was not verified with your authenticator. Sign out and back in with your code to perform privileged actions.';
  }
  return null;
}

// The RPCs raise 'PLATFORM_MFA_REQUIRED: ...' / 'PLATFORM_ADMIN_REQUIRED: ...'.
// Strip the machine prefix for display.
export function friendlyPlatformError(message: string | undefined | null): string {
  if (!message) return 'Something went wrong.';
  return message.replace(/^PLATFORM_(MFA|ADMIN)_REQUIRED:\s*/i, '');
}

export function isMfaRequiredError(message: string | undefined | null): boolean {
  return /^PLATFORM_MFA_REQUIRED/i.test(message ?? '');
}
