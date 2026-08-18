import { useEffect, useState } from 'react';
import { supabase } from './supabaseClient';

// Shared across anything that needs to know "is the current user a
// platform admin" -- App.tsx's root redirect and AdminLayout's shell
// switch, in addition to the screen-level gates that already existed
// per-component (CompaniesConsole's usePlatformAdminAccess,
// ModuleTree's useMyModuleAccess). Kept as its own hook rather than
// folding into ModuleTree's version since that one also carries
// tenant module entitlements this call site doesn't need.
//
// app_users' only SELECT policy scopes by tenant_id, not by your own
// id, so this always filters on the caller's own id from the session
// rather than trusting a bare .single() to return just one row.
//
// Returns null while resolving (first paint / auth state still
// settling), then true/false once known.
export function usePlatformAdminAccess() {
  const [isPlatformAdmin, setIsPlatformAdmin] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;

    const fetchAccess = async (userId: string | undefined) => {
      if (!userId) {
        if (!cancelled) setIsPlatformAdmin(false);
        return;
      }
      const { data, error } = await supabase
        .from('app_users')
        .select('is_platform_admin')
        .eq('id', userId)
        .maybeSingle();
      if (cancelled) return;
      setIsPlatformAdmin(error ? false : Boolean(data?.is_platform_admin));
    };

    supabase.auth.getSession().then(({ data: sessionData }) => {
      if (!cancelled) fetchAccess(sessionData.session?.user.id);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (cancelled) return;
      setIsPlatformAdmin(null);
      fetchAccess(session?.user.id);
    });

    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
    };
  }, []);

  return isPlatformAdmin;
}