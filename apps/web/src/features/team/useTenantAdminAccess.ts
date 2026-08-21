import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';

// Gate: you need to be your tenant's company admin (or a platform admin)
// to reach the Invite / Manage Team screens -- module-only admins (e.g.
// HR-only) can't invite or edit access, since they had no business
// granting access to modules they don't run, including finance. Real
// enforcement is server-side (invite-user, the invitations RLS policies,
// and is_tenant_admin() backing every Team Members Admin RPC) -- this
// just keeps the screens from rendering for people every call on them
// would fail for.
//
// Shared by InviteMember.tsx and TeamMembersAdmin.tsx. Keep this as the
// single source of truth -- don't fork a second copy, the impersonation
// handling and re-fetch-on-auth-change behavior below are easy to get
// subtly wrong twice.
//
// app_users' only SELECT policy scopes by tenant_id, not by your own id,
// so a query without .eq('id', ...) can return every user in your tenant
// and .single() throws on more than one row. Get the caller's own id
// from the session first, then filter on it.
export function useTenantAdminAccess() {
  const [state, setState] = useState<{ isAdmin: boolean; tenantId: string | null } | null>(null);
  useEffect(() => {
    let cancelled = false;

    const fetchAccess = async (userId: string | undefined) => {
      if (!userId) {
        if (!cancelled) setState({ isAdmin: false, tenantId: null });
        return;
      }
      const { data: appUser, error: appUserError } = await supabase
        .from('app_users')
        .select('tenant_id, is_platform_admin, is_company_admin')
        .eq('id', userId)
        .maybeSingle();
      if (cancelled || appUserError || !appUser) {
        if (!cancelled) setState({ isAdmin: false, tenantId: null });
        return;
      }
      // app_users.tenant_id is the caller's real (home) tenant and doesn't
      // move during impersonation. get_my_tenant_id() resolves to the
      // impersonated tenant server-side, so it's the one that actually
      // matches what invitations/staff_roles/RLS are scoped to right now.
      const { data: effectiveTenantId, error: tenantIdError } = await supabase.rpc('get_my_tenant_id');
      if (cancelled) return;
      const tenantId = tenantIdError || !effectiveTenantId ? appUser.tenant_id : effectiveTenantId;
      // Platform admins get full access to every module while impersonating
      // a tenant (view mode included) -- they don't need a staff_roles admin
      // row in that company to manage it.
      if (appUser.is_platform_admin) {
        setState({ isAdmin: true, tenantId });
        return;
      }
      // Mirrors invite-user's / is_tenant_admin()'s server-side check:
      // only the tenant's company admin (not any single-module admin)
      // may invite or edit members. See 20260817125405_add_is_company_admin_flag.
      setState({ isAdmin: !!appUser.is_company_admin, tenantId });
    };

    // Fetch once on mount for the fast path, but also re-fetch on any auth
    // state change. A session can swap within the same tab without a full
    // page reload -- e.g. accepting an invite link while this screen is
    // already mounted -- and a mount-only effect would keep showing the
    // previous session's access after the underlying user has changed.
    supabase.auth.getSession().then(({ data: sessionData }) => {
      if (!cancelled) fetchAccess(sessionData.session?.user.id);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (cancelled) return;
      setState(null);
      fetchAccess(session?.user.id);
    });

    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
    };
  }, []);
  return state;
}