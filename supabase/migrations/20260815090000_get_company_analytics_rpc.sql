-- Per-company analytics drill-down for the Companies Console.
-- get_companies_overview() gave platform-wide summary counts; this is
-- the single-tenant detail view: request volume by status and by
-- month, PO value, and a department headcount breakdown. Returned as
-- one jsonb blob rather than several result sets so the frontend can
-- fetch everything for one company in a single RPC call.
create or replace function public.get_company_analytics(p_tenant_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view company analytics';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  select jsonb_build_object(
    'requests_by_status', (
      select coalesce(jsonb_agg(jsonb_build_object('status', status, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select status, count(*) as cnt
        from requests
        where tenant_id = p_tenant_id
        group by status
      ) s
    ),
    'requests_by_month', (
      select coalesce(jsonb_agg(jsonb_build_object('month', month, 'count', cnt) order by month), '[]'::jsonb)
      from (
        select to_char(date_trunc('month', created_at), 'YYYY-MM') as month, count(*) as cnt
        from requests
        where tenant_id = p_tenant_id
          and created_at >= date_trunc('month', now()) - interval '5 months'
        group by 1
      ) m
    ),
    'purchase_orders', (
      select jsonb_build_object(
        'count', count(*),
        'total_value', coalesce(sum(po.amount), 0)
      )
      from purchase_orders po
      join requests r on r.id = po.request_id
      where r.tenant_id = p_tenant_id
    ),
    'members_by_department', (
      select coalesce(jsonb_agg(jsonb_build_object('department', dept, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select coalesce(d.name, 'Unassigned') as dept, count(*) as cnt
        from app_users u
        left join departments d on d.id = u.department_id
        where u.tenant_id = p_tenant_id
        group by 1
      ) dm
    ),
    'top_requesters', (
      select coalesce(jsonb_agg(jsonb_build_object('name', uname, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select u.name as uname, count(*) as cnt
        from requests r
        join app_users u on u.id = r.requester_id
        where r.tenant_id = p_tenant_id
        group by u.name
        order by count(*) desc
        limit 5
      ) tr
    )
  )
  into v_result;

  return v_result;
end;
$function$;