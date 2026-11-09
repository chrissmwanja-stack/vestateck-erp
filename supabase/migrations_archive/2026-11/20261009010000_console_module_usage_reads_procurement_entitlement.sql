-- Console module usage no longer reports `procurement` as enabled for every tenant
-- (Phase 0 audit seam 7, residual 2).
--
-- get_company_analytics() and get_platform_dashboard_stats() treated both
-- `procurement` and `finance` as always enabled. `finance` is a core key that
-- cannot be entitled per tenant, so that is right. `procurement` is an optional,
-- entitled module (platform_modules.tenant_entitled = true), so a tenant without
-- a tenant_modules row for it, such as a standalone insurance brokerage, was shown
-- as having Procurement enabled and counted in tenants_enabled.
--
-- Effect on existing tenants: any tenant WITHOUT a `procurement` row in
-- tenant_modules will now show Procurement as not enabled, and drop out of
-- tenants_enabled. Not checked against production here. To see who changes:
--   select t.id, t.name from tenants t
--   where not exists (select 1 from tenant_modules m where m.tenant_id = t.id and m.module = 'procurement');
--
-- Only these two expressions change; the rest of each body is the definition from
-- 20261002090000_console_reads_require_mfa.sql, copied verbatim. CREATE OR REPLACE
-- keeps each function's owner and grants.

create or replace function public.get_company_analytics(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_extra  jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view company analytics';
  end if;
  perform require_platform_admin('get company analytics');

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

  select jsonb_build_object(
    'module_usage', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'module', m.module,
        'enabled', (m.module = 'finance'
                    or exists (select 1 from tenant_modules tm where tm.tenant_id = p_tenant_id and tm.module = m.module)),
        'events_30d', coalesce(a.events, 0),
        'events_prev_30d', coalesce(a.events_prev, 0),
        'first_event_at', a.first_event_at,
        'last_event_at', a.last_event_at
      ) order by m.ord), '[]'::jsonb)
      from (values
        (1, 'procurement'), (2, 'finance'), (3, 'hr'), (4, 'legal'), (5, 'bd'),
        (6, 'it'), (7, 'pmo'), (8, 'machine_operation'), (9, 'sustainability')
      ) as m(ord, module)
      left join (select * from platform_module_activity(30) x where x.tenant_id = p_tenant_id) a on a.module = m.module
    ),
    'onboarding', (
      select to_jsonb(o) - 'tenant_id' - 'name' - 'status' - 'plan' - 'subscription_status'
             - 'trial_ends_at' - 'contact_email' - 'is_internal' - 'member_count'
      from get_tenant_onboarding_status() o
      where o.tenant_id = p_tenant_id
    ),
    'last_activity_at', (
      select o.last_activity_at from get_tenant_onboarding_status() o where o.tenant_id = p_tenant_id
    )
  ) into v_extra;

  return v_result || v_extra;
end;
$$;

create or replace function public.get_platform_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_extra  jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view platform dashboard stats';
  end if;
  perform require_platform_admin('get platform dashboard stats');

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
    'pending_companies_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at) order by created_at asc), '[]'::jsonb)
      from (select id, name, created_at from tenants where status = 'pending' order by created_at asc limit 25) pc
    ),
    'suspended_companies_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at) order by created_at asc), '[]'::jsonb)
      from (select id, name, created_at from tenants where status = 'suspended' order by created_at asc limit 25) sc
    )
  ) into v_result;

  -- Item 5 additions. The onboarding view and the activity scan are
  -- each computed once (MATERIALIZED) and shared by every key below.
  with _dash_onb as materialized (
    select * from get_tenant_onboarding_status() where not is_internal
  ),
  _dash_act as materialized (
    select a.* from platform_module_activity(30) a
    join _dash_onb o on o.tenant_id = a.tenant_id
  )
  select jsonb_build_object(
    'onboarding_funnel', (
      select coalesce(jsonb_agg(jsonb_build_object('stage', st.stage, 'stage_key', st.stage_key, 'count', coalesce(c.cnt, 0)) order by st.stage), '[]'::jsonb)
      from (values
        (0, 'created'), (1, 'admin_invited'), (2, 'admin_joined'), (3, 'modules_enabled'),
        (4, 'team_invited'), (5, 'first_activity'), (6, 'live')
      ) as st(stage, stage_key)
      left join (select stage, count(*) as cnt from _dash_onb where status <> 'suspended' group by stage) c on c.stage = st.stage
    ),
    'stalled_onboarding', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.tenant_id, 'name', o.name, 'status', o.status, 'stage', o.stage, 'stage_key', o.stage_key,
        'next_step', o.next_step, 'days_in_stage', o.days_in_stage, 'created_at', o.created_at,
        'contact_email', o.contact_email
      ) order by o.days_in_stage desc), '[]'::jsonb)
      from (select * from _dash_onb where stalled order by days_in_stage desc limit 25) o
    ),
    'quiet_tenants', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.tenant_id, 'name', o.name, 'plan', o.plan, 'subscription_status', o.subscription_status,
        'member_count', o.member_count, 'last_activity_at', o.last_activity_at,
        'days_quiet', greatest(0, extract(epoch from (now() - coalesce(o.last_activity_at, o.created_at))) / 86400)::integer,
        'contact_email', o.contact_email
      ) order by coalesce(o.last_activity_at, o.created_at) asc), '[]'::jsonb)
      from (
        select * from _dash_onb
        where status = 'active' and stage = 5
          and created_at < now() - interval '30 days'
        order by coalesce(last_activity_at, created_at) asc
        limit 25
      ) o
    ),
    'module_usage', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'module', m.module,
        'tenants_enabled', case
          when m.module = 'finance' then (select count(*) from _dash_onb)
          else (select count(distinct tm.tenant_id) from tenant_modules tm join _dash_onb o on o.tenant_id = tm.tenant_id where tm.module = m.module)
        end,
        'tenants_active_30d', (select count(distinct a.tenant_id) from _dash_act a where a.module = m.module and a.events > 0),
        'events_30d', coalesce((select sum(a.events) from _dash_act a where a.module = m.module), 0),
        'events_prev_30d', coalesce((select sum(a.events_prev) from _dash_act a where a.module = m.module), 0)
      ) order by m.ord), '[]'::jsonb)
      from (values
        (1, 'procurement'), (2, 'finance'), (3, 'hr'), (4, 'legal'), (5, 'bd'),
        (6, 'it'), (7, 'pmo'), (8, 'machine_operation'), (9, 'sustainability')
      ) as m(ord, module)
    ),
    'trial_ending_soon', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.tenant_id, 'name', o.name, 'trial_ends_at', o.trial_ends_at,
        'days_left', greatest(0, ceil(extract(epoch from (o.trial_ends_at - now())) / 86400))::integer,
        'stage_key', o.stage_key, 'member_count', o.member_count, 'contact_email', o.contact_email
      ) order by o.trial_ends_at), '[]'::jsonb)
      from (
        select * from _dash_onb
        where subscription_status = 'trialing' and trial_ends_at is not null
          and trial_ends_at <= now() + interval '14 days'
          and status <> 'suspended'
        order by trial_ends_at
        limit 25
      ) o
    )
  ) into v_extra;

  return v_result || v_extra;
end;
$$;
