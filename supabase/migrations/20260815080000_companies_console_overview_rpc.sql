-- Companies Console analytics: the console could list tenants but had
-- no per-tenant activity signal (headcount, module count, request
-- volume) and no platform-wide onboarding summary. Both were flagged
-- as "not built" -- this closes them with one read-only, platform-
-- admin-gated RPC rather than looser client-side queries that would
-- need new RLS carve-outs on requests/app_users.
create or replace function public.get_companies_overview()
returns table (
  tenant_id uuid,
  name text,
  status text,
  created_at timestamptz,
  member_count bigint,
  module_count bigint,
  request_count_30d bigint,
  pending_request_count bigint
)
language sql
stable security definer
set search_path to 'public'
as $function$
  select
    t.id,
    t.name,
    t.status,
    t.created_at,
    (select count(*) from app_users u where u.tenant_id = t.id),
    (select count(*) from tenant_modules tm where tm.tenant_id = t.id),
    (select count(*) from requests r where r.tenant_id = t.id and r.created_at >= now() - interval '30 days'),
    (select count(*) from requests r where r.tenant_id = t.id and r.status = 'pending')
  from tenants t
  where is_platform_admin()
  order by t.created_at desc;
$function$;