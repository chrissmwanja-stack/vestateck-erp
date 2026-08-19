-- Extends get_platform_dashboard_stats() with named pending/suspended
-- company lists, following the same pattern already used for
-- pending_invites_list. The dashboard already surfaces the *counts*
-- (totals.pending_companies, totals.suspended_companies) -- this adds
-- the actual tenant rows so the dashboard alert can name them
-- ("Acme Ltd, Nile Traders +1 more") instead of just showing a number.
--
-- Applied 2026-08-19 (version 20260819062312). Also happened to repair
-- schema drift: this function had been recorded as applied since
-- 20260818140000 but was actually missing from the live database (the
-- 20260819054719 remote_schema pull didn't carry it forward) -- the
-- dashboard had been silently running on its get_companies_overview
-- fallback path. Worth checking 20260819054719_remote_schema for what
-- else that pull may have dropped.
create or replace function public.get_platform_dashboard_stats()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view platform dashboard stats';
  end if;

  select jsonb_build_object(
    'totals', jsonb_build_object(
      'total_companies', (select count(*) from tenants),
      'active_companies', (select count(*) from tenants where status = 'active'),
      'pending_companies', (select count(*) from tenants where status = 'pending'),
      'suspended_companies', (select count(*) from tenants where status = 'suspended'),
      'total_members', (select count(*) from app_users),
      'total_pos', (select count(*) from purchase_orders),
      'total_po_value', coalesce((select sum(amount) from purchase_orders), 0),
      'total_requests', (select count(*) from requests),
      'requests_30d', (select count(*) from requests where created_at >= now() - interval '30 days'),
      'pending_requests', (select count(*) from requests where status = 'open'),
      'pending_invites', (select count(*) from invitations where status = 'pending' and role_bundle = 'company_admin')
    ),
    'by_status', (
      select coalesce(jsonb_agg(jsonb_build_object('status', status, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (select status, count(*) as cnt from tenants group by status) s
    ),
    'companies_by_month', (
      select coalesce(jsonb_agg(jsonb_build_object('month', month, 'count', cnt) order by month), '[]'::jsonb)
      from (
        select to_char(date_trunc('month', created_at), 'YYYY-MM') as month, count(*) as cnt
        from tenants
        where created_at >= date_trunc('month', now()) - interval '5 months'
        group by 1
      ) m
    ),
    'requests_by_month', (
      select coalesce(jsonb_agg(jsonb_build_object('month', month, 'count', cnt) order by month), '[]'::jsonb)
      from (
        select to_char(date_trunc('month', created_at), 'YYYY-MM') as month, count(*) as cnt
        from requests
        where created_at >= date_trunc('month', now()) - interval '5 months'
        group by 1
      ) m
    ),
    'module_adoption', (
      select coalesce(jsonb_agg(jsonb_build_object('module', module, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select module, count(distinct tenant_id) as cnt
        from tenant_modules
        group by module
      ) ma
    ),
    'recent_companies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'status', status, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
      from (select id, name, status, created_at from tenants order by created_at desc limit 5) rc
    ),
    'top_companies_by_requests', (
      select coalesce(jsonb_agg(jsonb_build_object('name', name, 'count', cnt, 'tenant_id', tenant_id) order by cnt desc), '[]'::jsonb)
      from (
        select t.name, r.tenant_id, count(*) as cnt
        from requests r join tenants t on t.id = r.tenant_id
        group by t.name, r.tenant_id
        order by cnt desc
        limit 5
      ) tr
    ),
    'pending_invites_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'email', email, 'tenant_id', tenant_id, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
      from (select id, email, tenant_id, created_at from invitations where status = 'pending' and role_bundle = 'company_admin' order by created_at desc limit 10) pi
    ),
    -- NEW: named rows for the two dashboard-alert cases, capped at 25 so
    -- a large platform can't blow up the payload -- the alert widget only
    -- ever names the first few and shows "+N more" past that.
    'pending_companies_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at) order by created_at asc), '[]'::jsonb)
      from (select id, name, created_at from tenants where status = 'pending' order by created_at asc limit 25) pc
    ),
    'suspended_companies_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at) order by created_at asc), '[]'::jsonb)
      from (select id, name, created_at from tenants where status = 'suspended' order by created_at asc limit 25) sc
    )
  ) into v_result;

  return v_result;
end;
$function$;

grant execute on function public.get_platform_dashboard_stats() to authenticated, service_role;
revoke execute on function public.get_platform_dashboard_stats() from anon, public;