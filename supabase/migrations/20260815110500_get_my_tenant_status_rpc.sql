-- Companion to the get_my_tenant_id() suspension lockout.
--
-- A suspended user's own tenant row is now unreachable through normal
-- RLS -- tenants_select_own is `id = get_my_tenant_id()`, and that
-- returns NULL for them. Without this, a suspended user just hits
-- empty/failed queries everywhere with no way for the frontend to
-- explain why. This looks up their tenant status directly via
-- app_users.tenant_id (not through get_my_tenant_id()) so the one
-- thing a locked-out user CAN learn is that they're locked out.
create or replace function public.get_my_tenant_status()
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select t.status
  from app_users u
  join tenants t on t.id = u.tenant_id
  where u.id = auth.uid();
$function$;