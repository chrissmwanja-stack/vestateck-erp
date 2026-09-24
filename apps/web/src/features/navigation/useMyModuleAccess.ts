import { useState, useEffect } from "react";
import { supabase } from "../../lib/supabaseClient";
import type { ModuleAccessState } from "./types";

// Fetches the current user's own staff_roles modules, intersected with
// the tenant's actual tenant_modules entitlements, plus the
// platform-admin flag -- purely for nav visibility (RequireModule/
// has_module_role is the real enforcement, and already applies this
// same intersection server-side -- see 20260815075105_tenant_module_
// entitlements.sql). Mirrors the query pattern already used in
// InviteMember's useTenantAdminAccess / CompaniesConsole's
// usePlatformAdminAccess: get the caller's id from the session first,
// since RLS on these tables scopes by tenant, not by caller.
//
// Without the tenant_modules intersection, a company_admin (who holds
// a staff_roles admin row for all 8 modules by design, so newly-opened
// modules reach them automatically) would see nav entries for modules
// their company hasn't actually been opened for, only to hit "Not
// available to you" on click. tenant_modules is directly readable here
// (not just via the platform-admin-gated get_tenant_modules RPC) --
// its own SELECT policy already allows tenant_id = get_my_tenant_id().
export function useMyModuleAccess() {
  const [state, setState] = useState<ModuleAccessState | null>(null);

  useEffect(() => {
    let cancelled = false;

    const fetchAccess = async (userId: string | undefined) => {
      if (!userId) {
        if (!cancelled)
          setState({
            isPlatformAdmin: false,
            modules: new Set(),
            rolesByModule: new Map(),
            isImpersonating: false,
            canAccessFinance: false,
          });
        return;
      }
      const { data: appUser } = await supabase
        .from("app_users")
        .select("tenant_id, is_platform_admin")
        .eq("id", userId)
        .maybeSingle();
      if (cancelled) return;
      if (!appUser) {
        setState({
          isPlatformAdmin: false,
          modules: new Set(),
          rolesByModule: new Map(),
          isImpersonating: false,
          canAccessFinance: false,
        });
        return;
      }
      // Whose staff_roles/tenant decide the nav. Normally the signed-in
      // user's own; for a platform admin viewing as a specific user, that
      // user's (the SQL permission helpers do the same via
      // effective_user_id(), so nav and route guards agree).
      let subjectUserId = userId;
      let subjectTenantId = appUser.tenant_id as string;
      if (appUser.is_platform_admin) {
        // Check for an active impersonation session -- when impersonating,
        // get_my_tenant_id() resolves to the target tenant. For nav we need
        // to know: platform-only mode (console only), company-level "View
        // as" (bypass: show every portal), or user-level "View as" (show
        // exactly that user's portals)?
        const { data: impRows } = await supabase.rpc("get_active_impersonation");
        if (cancelled) return;
        const imp = Array.isArray(impRows) ? impRows[0] : impRows;
        if (!imp || !imp.impersonated_user_id) {
          // has_module_role() (and can_access_finance()) treat a platform
          // admin who is not viewing as a user as an automatic pass --
          // mirror that here so nav doesn't hide things the route guard
          // would let them through to anyway.
          setState({
            isPlatformAdmin: true,
            modules: new Set(),
            rolesByModule: new Map(),
            isImpersonating: !!imp,
            canAccessFinance: true,
          });
          return;
        }
        subjectUserId = imp.impersonated_user_id;
        subjectTenantId = imp.tenant_id;
      }
      const [{ data: roles }, { data: entitlements }, { data: financeAccess }] = await Promise.all([
        supabase.from("staff_roles").select("module, role").eq("user_id", subjectUserId).eq("tenant_id", subjectTenantId),
        supabase.from("tenant_modules").select("module").eq("tenant_id", subjectTenantId),
        supabase.rpc("can_access_finance"),
      ]);
      if (cancelled) return;
      const roleRows = roles ?? [];
      const roleModules = new Set(roleRows.map((r) => r.module as string));
      const entitledModules = new Set((entitlements ?? []).map((e) => e.module as string));
      const effectiveModules = new Set([...roleModules].filter((m) => entitledModules.has(m)));
      const rolesByModule = new Map<string, Set<string>>();
      for (const r of roleRows) {
        const m = r.module as string;
        if (!rolesByModule.has(m)) rolesByModule.set(m, new Set());
        rolesByModule.get(m)!.add(r.role as string);
      }
      setState({
        // Deliberately false while viewing as a user: nav must show that
        // user's reality, not the operator's bypass.
        isPlatformAdmin: false,
        modules: effectiveModules,
        rolesByModule,
        isImpersonating: subjectUserId !== userId,
        canAccessFinance: Boolean(financeAccess),
      });
    };

    // Fetch once on mount for the fast path, but also re-fetch on any auth
    // state change. A session can swap within the same tab without a full
    // page reload -- e.g. accepting an invite link while this layout is
    // already mounted -- and a mount-only effect would keep showing the
    // previous session's access (e.g. "Platform Administration") after the
    // underlying user has changed.
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
