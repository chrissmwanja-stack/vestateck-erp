-- Console read RPCs now enforce the platform-admin MFA step-up (2026-10-02).
--
-- 15 read RPCs authorized with plain is_platform_admin(), so a password-only
-- (aal1) session of an operator with an enrolled authenticator could read
-- cross-tenant data, while writes already went through require_platform_admin(),
-- which raises PLATFORM_MFA_REQUIRED in that case. AUTHORIZATION_ARCHITECTURE.md
-- says is_platform_admin() is only for branching, so the reads are brought in
-- line with the rule.
--
-- Behaviour after this migration:
--   * not a platform admin     -> unchanged (empty set / the function's existing
--                                  'Only platform admins ...' error)
--   * platform admin, no enrolled factor, or aal2 session -> unchanged
--   * platform admin with an enrolled factor on an aal1 session
--                              -> raises 'PLATFORM_MFA_REQUIRED: ...' (42501)
--
-- Only the authorization line of each function changes; bodies are otherwise the
-- latest definitions from the migrations named below. CREATE OR REPLACE keeps
-- each function's owner and grants.

-- Boolean/set-returning SQL functions used `where is_platform_admin()` to return
-- zero rows for non-admins. This gate keeps that behaviour and adds the MFA
-- check for admins. Internal: only these SECURITY DEFINER functions call it.
create or replace function public.platform_admin_mfa_gate(p_action text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_platform_admin() then
    return false;
  end if;
  perform require_platform_admin(p_action);
  return true;
end;
$$;

revoke execute on function public.platform_admin_mfa_gate(text) from public, anon, authenticated;

create or replace function public.get_companies_overview()
returns table (
  tenant_id             uuid,
  name                  text,
  status                text,
  created_at            timestamptz,
  member_count          bigint,
  module_count          bigint,
  request_count_30d     bigint,
  pending_request_count bigint,
  plan                  text,
  subscription_status   text,
  seat_limit            integer,
  trial_ends_at         timestamptz,
  read_only             boolean,
  contact_email         text,
  last_activity_at      timestamptz,
  onboarding_stage      text,
  onboarding_next_step  text,
  onboarding_stalled    boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    t.id,
    t.name,
    t.status,
    t.created_at,
    (select count(*) from app_users u where u.tenant_id = t.id),
    (select count(*) from tenant_modules tm where tm.tenant_id = t.id),
    (select count(*) from requests r where r.tenant_id = t.id and r.created_at >= now() - interval '30 days'),
    (select count(*) from requests r where r.tenant_id = t.id and r.status = 'open'),
    t.plan,
    t.subscription_status,
    t.seat_limit,
    t.trial_ends_at,
    t.read_only,
    t.contact_email,
    o.last_activity_at,
    o.stage_key,
    o.next_step,
    o.stalled
  from tenants t
  left join get_tenant_onboarding_status() o on o.tenant_id = t.id
  where public.platform_admin_mfa_gate('get companies overview')
  order by t.created_at desc;
$$;

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
        'enabled', (m.module in ('procurement', 'finance')
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
          when m.module in ('procurement', 'finance') then (select count(*) from _dash_onb)
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

create or replace function public.get_platform_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
  v_has_cron boolean := exists (select 1 from pg_extension where extname = 'pg_cron');
  v_has_storage boolean := to_regclass('storage.objects') is not null;
  v_storage jsonb := '[]'::jsonb;
  v_cron jsonb := '[]'::jsonb;
  v_migration text;
  v_migration_count integer := 0;
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: platform health is restricted to platform admins' using errcode = '42501';
  end if;
  perform require_platform_admin('get platform health');

  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute 'select max(version), count(*)::int from supabase_migrations.schema_migrations' into v_migration, v_migration_count;
  end if;

  if v_has_storage then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket_id, 'objects', n, 'bytes', bytes) order by bytes desc), '[]'::jsonb)
      from (select bucket_id, count(*) as n, coalesce(sum((metadata ->> 'size')::bigint), 0) as bytes
            from storage.objects group by bucket_id) s
    $q$ into v_storage;
  end if;

  if v_has_cron then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object(
        'jobname', j.jobname, 'schedule', j.schedule, 'active', j.active,
        'last_status', r.status, 'last_start', r.start_time, 'last_end', r.end_time, 'last_message', left(r.return_message, 200)
      ) order by j.jobname), '[]'::jsonb)
      from cron.job j
      left join lateral (select status, start_time, end_time, return_message from cron.job_run_details d
                         where d.jobid = j.jobid order by start_time desc limit 1) r on true
    $q$ into v_cron;
  end if;

  select jsonb_build_object(
    'checked_at', now(),
    'database', jsonb_build_object(
      'version', split_part(version(), ' ', 2),
      'size_bytes', pg_database_size(current_database()),
      'connections', (select count(*) from pg_stat_activity where datname = current_database()),
      'max_connections', current_setting('max_connections')::int
    ),
    'migrations', jsonb_build_object('latest', v_migration, 'count', v_migration_count),
    'cron', jsonb_build_object('installed', v_has_cron, 'jobs', v_cron),
    'jobs', (
      -- Last run per job; the UI decides freshness (sweeps are per tenant
      -- and only run when someone opens the page, so "stale" is a hint
      -- not an alarm; the digest is expected daily).
      select coalesce(jsonb_agg(jsonb_build_object(
        'job', j.job, 'last_run_at', j.last_run_at, 'last_status', j.last_status, 'last_affected', j.last_affected,
        'last_detail', j.last_detail, 'runs_7d', j.runs_7d, 'errors_7d', j.errors_7d, 'tenants_7d', j.tenants_7d
      ) order by j.job), '[]'::jsonb)
      from (
        select r.job,
               max(r.started_at) as last_run_at,
               (array_agg(r.status order by r.started_at desc))[1] as last_status,
               (array_agg(r.affected order by r.started_at desc))[1] as last_affected,
               (array_agg(r.detail order by r.started_at desc))[1] as last_detail,
               count(*) filter (where r.started_at > now() - interval '7 days') as runs_7d,
               count(*) filter (where r.started_at > now() - interval '7 days' and r.status = 'error') as errors_7d,
               count(distinct r.tenant_id) filter (where r.started_at > now() - interval '7 days') as tenants_7d
        from platform_job_runs r
        group by r.job
      ) j
    ),
    'digest', jsonb_build_object(
      'last_generated_at', (select max(generated_at) from platform_digests),
      'failed_7d', (select count(*) from platform_digests where delivery_status = 'failed' and generated_at > now() - interval '7 days'),
      'pending', (select count(*) from platform_digests where delivery_status = 'pending')
    ),
    'stuck_approvals', (
      -- Open requests sitting at a stage for more than 7 days, per company.
      select coalesce(jsonb_agg(jsonb_build_object('tenant_id', s.tenant_id, 'tenant_name', s.name, 'count', s.n, 'oldest_days', s.oldest) order by s.n desc), '[]'::jsonb)
      from (
        select r.tenant_id, t.name, count(*) as n,
               max(extract(epoch from (now() - r.updated_at)) / 86400)::integer as oldest
        from requests r join tenants t on t.id = r.tenant_id
        where r.status = 'open' and r.current_stage_id is not null and r.updated_at < now() - interval '7 days'
        group by r.tenant_id, t.name
        limit 25
      ) s
    ),
    'stale_invites', (
      select coalesce(jsonb_agg(jsonb_build_object('tenant_id', s.tenant_id, 'tenant_name', s.name, 'count', s.n, 'oldest_days', s.oldest) order by s.n desc), '[]'::jsonb)
      from (
        select i.tenant_id, t.name, count(*) as n,
               max(extract(epoch from (now() - i.created_at)) / 86400)::integer as oldest
        from invitations i join tenants t on t.id = i.tenant_id
        where i.status = 'pending' and i.created_at < now() - interval '7 days'
        group by i.tenant_id, t.name
        limit 25
      ) s
    ),
    'read_only_tenants', (select count(*) from tenants where read_only),
    'open_impersonations', (select count(*) from impersonation_sessions where ended_at is null and (expires_at is null or expires_at > now())),
    'storage', jsonb_build_object('available', v_has_storage, 'buckets', v_storage),
    'announcements_live', (select count(*) from platform_announcements a where a.is_active and a.starts_at <= now() and (a.ends_at is null or a.ends_at > now())),
    'feature_flags', (select count(*) from platform_feature_flags)
  ) into v;

  return v;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."get_tenant_modules"("p_tenant_id" "uuid") RETURNS SETOF "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select module from public.tenant_modules
  where tenant_id = p_tenant_id and public.platform_admin_mfa_gate('get tenant modules')
  order by module;
$$;

CREATE OR REPLACE FUNCTION "public"."get_tenant_workflow_stages"("p_tenant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view workflow stage thresholds';
  end if;
  perform require_platform_admin('get tenant workflow stages');

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ws.id,
      'name', ws.name,
      'sequence_order', ws.sequence_order,
      'approver_role', ws.approver_role,
      'threshold_amount', ws.threshold_amount,
      'applies_to', ws.applies_to
    )
    order by ws.applies_to, ws.sequence_order
  ), '[]'::jsonb)
  into v_result
  from workflow_stages ws
  where ws.tenant_id = p_tenant_id;

  return v_result;
end;
$$;

create or replace function public.get_tenant_onboarding_status()
returns table (
  tenant_id            uuid,
  name                 text,
  status               text,
  created_at           timestamptz,
  plan                 text,
  subscription_status  text,
  trial_ends_at        timestamptz,
  contact_email        text,
  is_internal          boolean,
  member_count         bigint,
  stage                integer,
  stage_key            text,
  next_step            text,
  stage_reached_at     timestamptz,
  days_in_stage        integer,
  stalled              boolean,
  admin_invited_at     timestamptz,
  admin_joined_at      timestamptz,
  modules_enabled_at   timestamptz,
  team_invited_at      timestamptz,
  first_activity_at    timestamptz,
  last_activity_at     timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from platform_onboarding_status_all() where public.platform_admin_mfa_gate('get tenant onboarding status');
$$;

create or replace function public.get_tenant_feature_flags(p_tenant_id uuid)
returns table (key text, description text, default_enabled boolean, override boolean, effective boolean, note text, updated_at timestamptz)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.key, f.description, f.default_enabled, tf.enabled, coalesce(tf.enabled, f.default_enabled), tf.note, tf.updated_at
  from platform_feature_flags f
  left join tenant_feature_flags tf on tf.flag_key = f.key and tf.tenant_id = p_tenant_id
  where public.platform_admin_mfa_gate('get tenant feature flags')
  order by f.key;
$$;

create or replace function public.get_tenant_profile(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant tenants;
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: Only platform admins can view company profiles';
  end if;
  perform require_platform_admin('get tenant profile');

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    return null;
  end if;

  select jsonb_build_object(
    'tenant', to_jsonb(v_tenant),
    'seats', jsonb_build_object(
      'limit',           v_tenant.seat_limit,
      'members',         (select count(*) from app_users u where u.tenant_id = p_tenant_id),
      'pending_invites', (select count(*) from invitations i where i.tenant_id = p_tenant_id and i.status = 'pending')
    ),
    'activity', jsonb_build_object(
      'modules',          (select count(*) from tenant_modules tm where tm.tenant_id = p_tenant_id),
      'requests_30d',     (select count(*) from requests r where r.tenant_id = p_tenant_id and r.created_at >= now() - interval '30 days'),
      'last_request_at',  (select max(r.created_at) from requests r where r.tenant_id = p_tenant_id),
      'last_sign_in_at',  (select max(au.last_sign_in_at)
                           from app_users u join auth.users au on au.id = u.id
                           where u.tenant_id = p_tenant_id),
      'company_admins',   (select coalesce(jsonb_agg(jsonb_build_object('name', u.name, 'email', u.email) order by u.name), '[]'::jsonb)
                           from app_users u where u.tenant_id = p_tenant_id and u.is_company_admin)
    ),
    'last_status_event', (
      select to_jsonb(e) from (
        select action, reason, created_at, actor_email
        from platform_audit_events
        where tenant_id = p_tenant_id
          and action in ('tenant.suspend', 'tenant.activate', 'tenant.read_only.on', 'tenant.read_only.off')
        order by created_at desc
        limit 1
      ) e
    ),
    'recent_events', (
      select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc), '[]'::jsonb) from (
        select id, action, reason, created_at, actor_email, mfa_verified
        from platform_audit_events
        where tenant_id = p_tenant_id
        order by created_at desc
        limit 8
      ) e
    ),
    'notes_count', (select count(*) from tenant_notes n where n.tenant_id = p_tenant_id)
  )
  into v_result;

  return v_result;
end;
$$;

create or replace function public.list_feature_flags()
returns table (
  key              text,
  description      text,
  default_enabled  boolean,
  updated_at       timestamptz,
  tenants_on       bigint,
  tenants_off      bigint,
  overrides        jsonb
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.key, f.description, f.default_enabled, f.updated_at,
    (select count(*) from tenant_feature_flags tf where tf.flag_key = f.key and tf.enabled),
    (select count(*) from tenant_feature_flags tf where tf.flag_key = f.key and not tf.enabled),
    (select coalesce(jsonb_agg(jsonb_build_object('tenant_id', tf.tenant_id, 'tenant_name', t.name, 'enabled', tf.enabled, 'note', tf.note, 'updated_at', tf.updated_at) order by t.name), '[]'::jsonb)
       from tenant_feature_flags tf join tenants t on t.id = tf.tenant_id where tf.flag_key = f.key)
  from platform_feature_flags f
  where public.platform_admin_mfa_gate('list feature flags')
  order by f.key;
$$;

create or replace function public.list_impersonation_history(
  p_tenant_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id                      uuid,
  platform_admin_id       uuid,
  platform_admin_email    text,
  tenant_id               uuid,
  tenant_name             text,
  reason                  text,
  started_at              timestamptz,
  ended_at                timestamptz,
  expires_at              timestamptz,
  is_active               boolean,
  impersonated_user_id    uuid,
  impersonated_user_email text,
  total_count             bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    s.id,
    s.platform_admin_id,
    u.email,
    s.tenant_id,
    t.name,
    s.reason,
    s.started_at,
    s.ended_at,
    s.expires_at,
    (s.ended_at is null and s.expires_at > now()) as is_active,
    s.impersonated_user_id,
    iu.email,
    count(*) over () as total_count
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  left join auth.users u on u.id = s.platform_admin_id
  left join app_users iu on iu.id = s.impersonated_user_id
  where public.platform_admin_mfa_gate('list impersonation history')
    and (p_tenant_id is null or s.tenant_id = p_tenant_id)
  order by s.started_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0));
$$;

create or replace function public.list_industry_templates(p_include_inactive boolean default false)
returns table (
  key              text,
  name             text,
  description      text,
  is_active        boolean,
  is_default       boolean,
  sort_order       integer,
  updated_at       timestamptz,
  department_count integer,
  module_count     integer,
  stage_count      integer,
  tenants_using    bigint,
  items            jsonb
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    t.key, t.name, t.description, t.is_active, t.is_default, t.sort_order, t.updated_at,
    (select count(*) from industry_template_items i where i.template_key = t.key and i.kind = 'department')::integer,
    (select count(*) from industry_template_items i where i.template_key = t.key and i.kind = 'module')::integer,
    (select count(*) from industry_template_items i where i.template_key = t.key and i.kind = 'workflow_stage')::integer,
    (select count(*) from tenants x where x.industry_template = t.key),
    (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'sort_order', i.sort_order, 'name', i.name, 'payload', i.payload)
                                order by i.kind, i.sort_order), '[]'::jsonb)
       from industry_template_items i where i.template_key = t.key)
  from industry_templates t
  where public.platform_admin_mfa_gate('list industry templates')
    and (p_include_inactive or t.is_active)
  order by t.sort_order, t.name;
$$;

create or replace function public.list_platform_announcements(p_include_past boolean default false)
returns table (
  id            uuid,
  title         text,
  body          text,
  severity      text,
  tenant_id     uuid,
  tenant_name   text,
  starts_at     timestamptz,
  ends_at       timestamptz,
  dismissible   boolean,
  link_url      text,
  link_label    text,
  is_active     boolean,
  state         text,          -- scheduled | live | ended | disabled
  dismissals    bigint,
  created_at    timestamptz,
  created_by_email text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select a.id, a.title, a.body, a.severity, a.tenant_id, t.name, a.starts_at, a.ends_at, a.dismissible,
         a.link_url, a.link_label, a.is_active,
         case
           when not a.is_active then 'disabled'
           when a.ends_at is not null and a.ends_at <= now() then 'ended'
           when a.starts_at > now() then 'scheduled'
           else 'live'
         end as state,
         (select count(*) from platform_announcement_dismissals d where d.announcement_id = a.id),
         a.created_at,
         (select email from auth.users u where u.id = a.created_by)
  from platform_announcements a
  left join tenants t on t.id = a.tenant_id
  where public.platform_admin_mfa_gate('list platform announcements')
    and (p_include_past or a.is_active and (a.ends_at is null or a.ends_at > now() - interval '7 days'))
  order by a.is_active desc, a.starts_at desc;
$$;

create or replace function public.list_platform_audit_events(
  p_tenant_id uuid    default null,
  p_actor_id  uuid    default null,
  p_action    text    default null,   -- exact match or prefix with trailing '%'
  p_from      timestamptz default null,
  p_to        timestamptz default null,
  p_limit     integer default 50,
  p_offset    integer default 0
)
returns table (
  id           uuid,
  created_at   timestamptz,
  actor_id     uuid,
  actor_email  text,
  tenant_id    uuid,
  tenant_name  text,
  action       text,
  target_type  text,
  target_id    text,
  reason       text,
  before       jsonb,
  after        jsonb,
  mfa_verified boolean,
  total_count  bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with filtered as (
    select e.*
    from platform_audit_events e
    where public.platform_admin_mfa_gate('list platform audit events')
      and (p_tenant_id is null or e.tenant_id = p_tenant_id)
      and (p_actor_id  is null or e.actor_id  = p_actor_id)
      and (p_action    is null or e.action like p_action)
      and (p_from      is null or e.created_at >= p_from)
      and (p_to        is null or e.created_at <  p_to)
  )
  select
    f.id, f.created_at, f.actor_id, f.actor_email, f.tenant_id, t.name,
    f.action, f.target_type, f.target_id, f.reason, f.before, f.after, f.mfa_verified,
    count(*) over () as total_count
  from filtered f
  left join tenants t on t.id = f.tenant_id
  order by f.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0));
$$;

create or replace function public.list_platform_digests(p_limit integer default 14)
returns setof public.platform_digests
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select d.* from platform_digests d
  where public.platform_admin_mfa_gate('list platform digests')
  order by d.generated_at desc
  limit greatest(1, least(coalesce(p_limit, 14), 90));
$$;