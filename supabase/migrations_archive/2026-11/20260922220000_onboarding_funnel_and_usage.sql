-- =====================================================================
-- Onboarding funnel, "going quiet" detection, per-module usage
-- =====================================================================
--
-- Operator-console item 5 (see ROADMAP Priority 5). Until now the
-- Overview could say how many companies exist and how many procurement
-- requests they raised; it could not say *where each company is on the
-- way to being a live customer*, *which ones have stalled*, *which ones
-- were live and have gone quiet*, or *which modules are switched on but
-- never touched*. Those are the questions an operator asks every
-- morning, so they get first-class, testable SQL:
--
--  1. platform_module_activity_sources -- a data table mapping each
--     module to the tenant-scoped tables whose row creation counts as
--     "using" it. Data, not code, so a new module or table is one INSERT.
--  2. platform_module_activity(p_days) -- per tenant x module: events in
--     the window, events in the previous window (trend), first and last
--     event. Dynamic SQL over the sources table; skips tables that do not
--     exist yet so an older or newer schema never breaks the console.
--  3. get_tenant_onboarding_status() -- one row per tenant: ordered
--     milestones (admin invited -> admin joined -> modules enabled -> team
--     invited -> first activity -> live), the furthest *contiguous*
--     milestone reached (= "stage"), the next step to take, how long it
--     has sat there, and a stalled flag.
--  4. get_platform_dashboard_stats() gains onboarding_funnel,
--     stalled_onboarding, quiet_tenants, module_usage, trial_ending_soon.
--     get_company_analytics() gains module_usage, onboarding,
--     last_activity_at. get_companies_overview() gains onboarding_stage,
--     onboarding_next_step, onboarding_stalled, and its last_activity_at
--     now counts activity in every module, not only procurement requests.
--
-- Additive: new table + functions; existing jsonb keys/columns keep
-- their names, order and meaning.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Which tables count as "activity" for which module
-- ---------------------------------------------------------------------
create table if not exists public.platform_module_activity_sources (
  module      text not null,
  table_name  text not null,
  created_at  timestamptz not null default now(),
  primary key (module, table_name),
  constraint platform_module_activity_sources_module_check check (module in (
    'procurement', 'finance', 'hr', 'legal', 'bd', 'it', 'pmo',
    'machine_operation', 'sustainability'
  ))
);

comment on table public.platform_module_activity_sources is
  'Operator-console metadata: rows created in table_name count as usage of module (platform_module_activity()). Add a row when a module gains a table worth counting; the table must have tenant_id + created_at.';

alter table public.platform_module_activity_sources enable row level security;

drop policy if exists platform_module_activity_sources_select on public.platform_module_activity_sources;
create policy platform_module_activity_sources_select
  on public.platform_module_activity_sources for select
  to authenticated
  using (is_platform_admin());
-- No insert/update/delete policies: maintained by migrations only.

insert into public.platform_module_activity_sources (module, table_name) values
  ('procurement', 'requests'),
  ('procurement', 'material_request_batches'),
  ('procurement', 'goods_issues'),
  ('procurement', 'supplier_invoices'),
  ('finance', 'journal_entries'),
  ('finance', 'cash_bank_transactions'),
  ('finance', 'petty_cash_replenishments'),
  ('finance', 'receivable_invoices'),
  ('finance', 'advance_payments'),
  ('finance', 'expenditure_slips'),
  ('finance', 'invoice_requests'),
  ('hr', 'hr_employees'),
  ('hr', 'hr_leave_requests'),
  ('hr', 'hr_payroll_runs'),
  ('hr', 'hr_attendance'),
  ('hr', 'hr_appraisals'),
  ('legal', 'law_contracts'),
  ('legal', 'law_cases'),
  ('legal', 'law_regulatory_filings'),
  ('legal', 'law_compliance_register'),
  ('bd', 'bd_leads'),
  ('bd', 'bd_opportunities'),
  ('bd', 'bd_proposals'),
  ('bd', 'bd_tenders'),
  ('bd', 'bd_activities'),
  ('it', 'it_tickets'),
  ('it', 'kb_articles'),
  ('it', 'assets'),
  ('it', 'access_requests'),
  ('pmo', 'pmo_projects'),
  ('pmo', 'pmo_tasks'),
  ('pmo', 'pmo_time_entries'),
  ('pmo', 'pmo_cost_entries'),
  ('machine_operation', 'machines'),
  ('machine_operation', 'operation_logs'),
  ('machine_operation', 'fuel_logs'),
  ('machine_operation', 'machine_maintenance_events'),
  ('machine_operation', 'maintenance_requests'),
  ('sustainability', 'sustainability_metrics'),
  ('sustainability', 'sustainability_initiatives'),
  ('sustainability', 'sustainability_audits'),
  ('sustainability', 'sustainability_certifications')
on conflict do nothing;


-- ---------------------------------------------------------------------
-- 2. Activity per tenant x module
-- ---------------------------------------------------------------------
-- Internal: one row per (tenant, module, table). Not granted to clients.
create or replace function public.platform_module_activity_raw(p_days integer default 30)
returns table (
  tenant_id      uuid,
  module         text,
  table_name     text,
  events         bigint,
  events_prev    bigint,
  first_event_at timestamptz,
  last_event_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  r        record;
  v_days   integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_since  timestamptz := now() - make_interval(days => v_days);
  v_prev   timestamptz := now() - make_interval(days => 2 * v_days);
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: module activity is restricted to platform admins'
      using errcode = '42501';
  end if;

  for r in
    select s.module, s.table_name
    from platform_module_activity_sources s
    where to_regclass('public.' || quote_ident(s.table_name)) is not null
      and exists (select 1 from pg_attribute a
                  where a.attrelid = to_regclass('public.' || quote_ident(s.table_name))
                    and a.attname = 'tenant_id' and not a.attisdropped)
      and exists (select 1 from pg_attribute a
                  where a.attrelid = to_regclass('public.' || quote_ident(s.table_name))
                    and a.attname = 'created_at' and not a.attisdropped)
    order by s.module, s.table_name
  loop
    return query execute format(
      'select x.tenant_id, %L::text, %L::text,
              count(*) filter (where x.created_at >= $1),
              count(*) filter (where x.created_at >= $2 and x.created_at < $1),
              min(x.created_at), max(x.created_at)
       from public.%I x
       where x.tenant_id is not null
       group by x.tenant_id',
      r.module, r.table_name, r.table_name
    ) using v_since, v_prev;
  end loop;
end;
$$;

revoke all on function public.platform_module_activity_raw(integer) from public, authenticated, anon;

create or replace function public.platform_module_activity(p_days integer default 30)
returns table (
  tenant_id      uuid,
  module         text,
  events         bigint,
  events_prev    bigint,
  first_event_at timestamptz,
  last_event_at  timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select r.tenant_id, r.module,
         sum(r.events)::bigint, sum(r.events_prev)::bigint,
         min(r.first_event_at), max(r.last_event_at)
  from platform_module_activity_raw(p_days) r
  group by r.tenant_id, r.module;
$$;

revoke all on function public.platform_module_activity(integer) from public;
grant execute on function public.platform_module_activity(integer) to authenticated;


-- ---------------------------------------------------------------------
-- 3. Onboarding status per tenant
-- ---------------------------------------------------------------------
-- Stage = furthest *contiguous* milestone, so "modules were switched on
-- at creation but no admin was ever invited" still reads as stage 0
-- with next step "invite the admin" -- the funnel answers "what do I do
-- next for this company", not "how many boxes are ticked".
--
--   0 created         -> invite the company admin
--   1 admin_invited   -> waiting for the admin to accept (an admin invite
--                        exists, or someone already has an account)
--   2 admin_joined    -> enable modules (a company admin, or any
--                        staff_roles admin, has an account)
--   3 modules_enabled -> invite the team
--   4 team_invited    -> waiting for first real activity
--   5 first_activity  -> has been used, but is not "live": either the
--                        tenant is still pending/suspended, or nothing
--                        happened in the last 30 days (gone quiet)
--   6 live            -> status active with activity in the last 30 days
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
  with act as (
    select a.tenant_id, min(a.first_event_at) as first_at, max(a.last_event_at) as last_at
    from platform_module_activity(30) a
    group by a.tenant_id
  ),
  base as (
    select
      t.id, t.name, t.status, t.created_at, t.plan, t.subscription_status, t.trial_ends_at, t.contact_email,
      (t.plan = 'internal' or t.id = '00000000-0000-0000-0000-000000000099') as is_internal,
      (select count(*) from app_users u where u.tenant_id = t.id) as member_count,
      -- Each milestone is satisfied by the invitation OR by the outcome
      -- the invitation would have produced, so companies set up by hand
      -- (seed data, migrated customers) are not stuck at stage 0.
      least(
        (select min(i.created_at) from invitations i where i.tenant_id = t.id and i.role_bundle = 'company_admin'),
        (select min(u.created_at) from app_users u where u.tenant_id = t.id)
      ) as admin_invited_at,
      least(
        (select min(u.created_at) from app_users u where u.tenant_id = t.id and u.is_company_admin),
        (select min(u.created_at) from app_users u join staff_roles sr on sr.user_id = u.id and sr.tenant_id = u.tenant_id
          where u.tenant_id = t.id and sr.role = 'admin')
      ) as admin_joined_at,
      (select min(tm.enabled_at) from tenant_modules tm where tm.tenant_id = t.id) as modules_enabled_at,
      least(
        (select min(i.created_at) from invitations i where i.tenant_id = t.id and i.role_bundle = 'member'),
        (select u.created_at from app_users u where u.tenant_id = t.id order by u.created_at offset 1 limit 1)
      ) as team_invited_at,
      a.first_at as first_activity_at,
      greatest(
        a.last_at,
        (select max(au.last_sign_in_at) from app_users u join auth.users au on au.id = u.id where u.tenant_id = t.id)
      ) as last_activity_at
    from tenants t
    left join act a on a.tenant_id = t.id
    where is_platform_admin()
  ),
  staged as (
    select b.*,
      case
        when b.admin_invited_at   is null then 0
        when b.admin_joined_at    is null then 1
        when b.modules_enabled_at is null then 2
        when b.team_invited_at    is null then 3
        when b.first_activity_at  is null then 4
        when b.status = 'active' and b.last_activity_at >= now() - interval '30 days' then 6
        else 5
      end as stage
    from base b
  ),
  keyed as (
    select s.*,
      case s.stage
        when 0 then 'created'
        when 1 then 'admin_invited'
        when 2 then 'admin_joined'
        when 3 then 'modules_enabled'
        when 4 then 'team_invited'
        when 5 then 'first_activity'
        else 'live'
      end as stage_key,
      case s.stage
        when 0 then 'Invite the company admin'
        when 1 then 'Waiting for the admin to accept the invitation'
        when 2 then 'Enable the modules they bought'
        when 3 then 'Invite the rest of the team'
        when 4 then 'Waiting for the first real activity'
        when 5 then case
          when s.status = 'pending' then 'Activate the company - it is in use but still marked pending'
          when s.status = 'suspended' then 'Suspended'
          else 'No activity in the last 30 days - check in'
        end
        else null
      end as next_step,
      case s.stage
        when 0 then s.created_at
        when 1 then s.admin_invited_at
        when 2 then s.admin_joined_at
        when 3 then s.modules_enabled_at
        when 4 then s.team_invited_at
        when 5 then coalesce(s.last_activity_at, s.first_activity_at)
        else s.last_activity_at
      end as stage_reached_at
    from staged s
  )
  select
    k.id, k.name, k.status, k.created_at, k.plan, k.subscription_status, k.trial_ends_at, k.contact_email,
    k.is_internal, k.member_count,
    k.stage, k.stage_key, k.next_step, k.stage_reached_at,
    greatest(0, extract(epoch from (now() - k.stage_reached_at)) / 86400)::integer as days_in_stage,
    -- Stalled = stuck in SETUP (stages 0-4) for over a week. Stage 5
    -- (used before, quiet now) is a retention signal, surfaced
    -- separately as quiet_tenants, so it is deliberately not "stalled".
    (k.stage < 5 and k.status <> 'suspended' and not k.is_internal
       and k.stage_reached_at < now() - interval '7 days') as stalled,
    k.admin_invited_at, k.admin_joined_at, k.modules_enabled_at, k.team_invited_at,
    k.first_activity_at, k.last_activity_at
  from keyed k
  order by k.created_at desc;
$$;

revoke all on function public.get_tenant_onboarding_status() from public;
grant execute on function public.get_tenant_onboarding_status() to authenticated;


-- ---------------------------------------------------------------------
-- 4a. get_companies_overview(): stage columns, module-aware activity
-- ---------------------------------------------------------------------
drop function if exists public.get_companies_overview();
create function public.get_companies_overview()
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
  where is_platform_admin()
  order by t.created_at desc;
$$;

revoke all on function public.get_companies_overview() from public;
grant execute on function public.get_companies_overview() to authenticated;
grant execute on function public.get_companies_overview() to service_role;


-- ---------------------------------------------------------------------
-- 4b. get_platform_dashboard_stats(): funnel / stalled / quiet / usage
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- 4c. get_company_analytics(): module usage + onboarding for one company
-- ---------------------------------------------------------------------
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
