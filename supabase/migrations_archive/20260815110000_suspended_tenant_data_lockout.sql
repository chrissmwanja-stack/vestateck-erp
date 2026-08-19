-- Enforce tenant suspension at the data layer.
--
-- set_tenant_status() (20260815100000) could flip a tenant to
-- 'suspended', but nothing read that column -- 244 RLS policies
-- across the schema funnel through get_my_tenant_id(), and none of
-- them checked tenant status. A "suspended" company's users could
-- log in and use every screen exactly as before.
--
-- Single choke point fix: get_my_tenant_id() is the one function
-- virtually every tenant-scoped RLS policy calls. Making it return
-- NULL for a regular (non-impersonated) member of a suspended tenant
-- makes every `tenant_id = get_my_tenant_id()` policy evaluate false
-- for them, network-wide, with one change -- consistent with how
-- is_platform_admin() already threads through as a bypass elsewhere
-- rather than being re-checked table by table.
--
-- The impersonation branch is deliberately left unfiltered: a
-- platform admin needs to be able to "View as" a suspended tenant for
-- support/review purposes (e.g. to inspect data before reactivating
-- or offboarding them). Suspension blocks the tenant's own users, not
-- platform-admin support access.
--
-- Known caveat: this covers everything gated through
-- get_my_tenant_id()'s RLS policies (244 of them) plus any
-- SECURITY DEFINER function that calls it internally. Any function
-- that looks up app_users.tenant_id directly instead of going through
-- this helper would bypass the lockout -- worth a follow-up grep if
-- suspension needs to be airtight rather than best-effort.
create or replace function public.get_my_tenant_id()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(
    (select tenant_id from impersonation_sessions
     where platform_admin_id = auth.uid()
       and ended_at is null
       and started_at > now() - interval '2 hours'
     limit 1),
    (select u.tenant_id
     from app_users u
     join tenants t on t.id = u.tenant_id
     where u.id = auth.uid()
       and t.status != 'suspended')
  );
$function$;