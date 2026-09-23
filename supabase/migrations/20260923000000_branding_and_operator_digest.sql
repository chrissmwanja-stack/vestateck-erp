-- Item 6 of the operator-console build order: make platform_settings do
-- something. Until now the Settings page saved branding and notification
-- preferences that nothing read.
--
--  1. get_platform_branding() -- SECURITY DEFINER, callable by anon and
--     authenticated, returns the branding subset of platform_settings
--     with defaults applied and the colour validated. The login page
--     runs before there is a session and platform_settings RLS is
--     platform-admin-only (the same trap get_security_settings() fixed
--     for the security column), so this is the only way the client can
--     ever see the operator's branding.
--
--  2. Internal, ungated variants of two item-5 functions:
--       platform_module_activity_scan(days)  <- platform_module_activity_raw
--       platform_onboarding_status_all()     <- get_tenant_onboarding_status
--     The public functions keep their signatures and gates; they now
--     delegate. Needed because a pg_cron job has no auth.uid(), so the
--     gated versions return nothing to it. Both internals are revoked
--     from every client role.
--
--  3. Operator digest. platform_digests stores one row per run: the
--     period, a jsonb payload (new companies, stalled, quiet, trials
--     ending, pending companies older than
--     notifications.pending_company_threshold_days, open View-as
--     sessions, platform admins without MFA, totals), the intended
--     email recipients (notifications.alert_recipients) and delivery
--     state. platform_run_operator_digest() builds the row and drops an
--     in-app notification (type 'operator_digest') on every platform
--     admin, so the digest reaches the operator with zero email
--     infrastructure. A pg_cron job runs it daily at 04:00 UTC (07:00
--     Kampala) when pg_cron is installed; notifications.digest_enabled
--     (default true) turns it off without touching the schedule.
--     run_operator_digest_now() is the platform-admin RPC behind the
--     "Generate now" button; list_platform_digests() feeds the history
--     panel. Email delivery is the send-operator-digest edge function
--     (Resend), which marks rows delivered via
--     mark_platform_digest_delivered() -- service role only.
--
-- Additive: no drops, no column changes. Passes scripts/check-migration-policy.sh.

-- ---------------------------------------------------------------------
-- 1. Branding for everyone
-- ---------------------------------------------------------------------
create or replace function public.get_platform_branding()
returns table (
  platform_name  text,
  logo_url       text,
  primary_color  text,
  support_email  text,
  tagline        text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with b as (
    select coalesce((select branding from platform_settings where id = true), '{}'::jsonb) as j
  )
  select
    coalesce(nullif(btrim(j ->> 'platform_name'), ''), 'VestaPortal'),
    -- Only http(s) URLs; anything else (javascript:, data:) is dropped.
    case when (j ->> 'logo_url') ~* '^https?://' then btrim(j ->> 'logo_url') else '' end,
    -- Must be a 6-digit hex colour or the brand default is used; this
    -- value ends up inside a style attribute and an email template.
    case when (j ->> 'primary_color') ~ '^#[0-9A-Fa-f]{6}$' then upper(j ->> 'primary_color') else '#1B5560' end,
    case when (j ->> 'support_email') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then lower(btrim(j ->> 'support_email')) else '' end,
    coalesce(nullif(btrim(j ->> 'tagline'), ''), 'Multi-department ERP')
  from b;
$$;

revoke all on function public.get_platform_branding() from public;
grant execute on function public.get_platform_branding() to anon, authenticated, service_role;

comment on function public.get_platform_branding() is
  'Operator branding for the whole platform (login page, top bar, PDFs, emails). Safe for anon: returns only the branding subset of platform_settings, with defaults and validation applied.';


-- ---------------------------------------------------------------------
-- 2. Ungated internals for item-5 functions
-- ---------------------------------------------------------------------
-- 2a. Activity scan (body of platform_module_activity_raw minus the gate).
create or replace function public.platform_module_activity_scan(p_days integer default 30)
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

revoke all on function public.platform_module_activity_scan(integer) from public, authenticated, anon;

-- The gated function keeps its contract (raises 42501 for non-admins).
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
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: module activity is restricted to platform admins'
      using errcode = '42501';
  end if;
  return query select * from platform_module_activity_scan(p_days);
end;
$$;

revoke all on function public.platform_module_activity_raw(integer) from public, authenticated, anon;

-- 2b. Onboarding status for all tenants (body of get_tenant_onboarding_status
--     minus the gate; uses the ungated scan).
create or replace function public.platform_onboarding_status_all()
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
    from platform_module_activity_scan(30) a
    group by a.tenant_id
  ),
  base as (
    select
      t.id, t.name, t.status, t.created_at, t.plan, t.subscription_status, t.trial_ends_at, t.contact_email,
      (t.plan = 'internal' or t.id = '00000000-0000-0000-0000-000000000099') as is_internal,
      (select count(*) from app_users u where u.tenant_id = t.id) as member_count,
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
    (k.stage < 5 and k.status <> 'suspended' and not k.is_internal
       and k.stage_reached_at < now() - interval '7 days') as stalled,
    k.admin_invited_at, k.admin_joined_at, k.modules_enabled_at, k.team_invited_at,
    k.first_activity_at, k.last_activity_at
  from keyed k
  order by k.created_at desc;
$$;

revoke all on function public.platform_onboarding_status_all() from public, authenticated, anon;

-- Same signature and gate as before; now a thin wrapper.
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
  select * from platform_onboarding_status_all() where is_platform_admin();
$$;

revoke all on function public.get_tenant_onboarding_status() from public;
grant execute on function public.get_tenant_onboarding_status() to authenticated;


-- ---------------------------------------------------------------------
-- 3. Operator digest
-- ---------------------------------------------------------------------
create table if not exists public.platform_digests (
  id               uuid primary key default gen_random_uuid(),
  period_start     timestamptz not null,
  period_end       timestamptz not null,
  generated_at     timestamptz not null default now(),
  trigger          text not null default 'scheduled',     -- 'scheduled' | 'manual'
  generated_by     uuid,                                   -- auth.uid() for manual runs; null for cron
  attention_count  integer not null default 0,
  payload          jsonb not null,
  recipients       text[] not null default '{}',           -- notifications.alert_recipients at run time
  delivery_status  text not null default 'pending',        -- 'pending' | 'sent' | 'failed' | 'skipped'
  delivered_at     timestamptz,
  delivery_error   text,
  constraint platform_digests_trigger_check check (trigger in ('scheduled', 'manual')),
  constraint platform_digests_delivery_check check (delivery_status in ('pending', 'sent', 'failed', 'skipped'))
);

create index if not exists idx_platform_digests_generated_at on public.platform_digests (generated_at desc);

alter table public.platform_digests enable row level security;

drop policy if exists platform_digests_select_admin on public.platform_digests;
create policy platform_digests_select_admin
  on public.platform_digests for select
  using (is_platform_admin());
-- No insert/update/delete policies: only SECURITY DEFINER functions and
-- service_role write here.

comment on table public.platform_digests is
  'Operator-console daily digest runs (what needs attention across all companies). Built by platform_run_operator_digest(); emailed by the send-operator-digest edge function.';

-- 3a. Build the payload. Ungated (internal): callers gate.
create or replace function public.platform_operator_digest_payload(p_period_start timestamptz, p_period_end timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_threshold integer := coalesce(
    (select (notifications ->> 'pending_company_threshold_days')::integer from platform_settings where id = true), 2);
  v_payload jsonb;
begin
  with onb as materialized (
    select * from platform_onboarding_status_all() where not is_internal
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_period_start, 'to', p_period_end),
    'settings', jsonb_build_object('pending_company_threshold_days', v_threshold),
    'totals', jsonb_build_object(
      'companies', (select count(*) from onb),
      'active',    (select count(*) from onb where status = 'active'),
      'pending',   (select count(*) from onb where status = 'pending'),
      'suspended', (select count(*) from onb where status = 'suspended'),
      'live',      (select count(*) from onb where stage = 6),
      'users',     (select count(*) from app_users u join onb o on o.tenant_id = u.tenant_id)
    ),
    'new_companies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', tenant_id, 'name', name, 'plan', plan, 'status', status, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
      from onb where created_at >= p_period_start and created_at < p_period_end
    ),
    'new_users', (
      select count(*) from app_users u join onb o on o.tenant_id = u.tenant_id
      where u.created_at >= p_period_start and u.created_at < p_period_end
    ),
    'stalled', (
      select coalesce(jsonb_agg(jsonb_build_object('id', tenant_id, 'name', name, 'stage_key', stage_key, 'next_step', next_step, 'days_in_stage', days_in_stage, 'contact_email', contact_email) order by days_in_stage desc), '[]'::jsonb)
      from (select * from onb where stalled order by days_in_stage desc limit 25) s
    ),
    'quiet', (
      select coalesce(jsonb_agg(jsonb_build_object('id', tenant_id, 'name', name, 'plan', plan,
        'days_quiet', greatest(0, extract(epoch from (now() - coalesce(last_activity_at, created_at))) / 86400)::integer,
        'contact_email', contact_email) order by coalesce(last_activity_at, created_at)), '[]'::jsonb)
      from (select * from onb where status = 'active' and stage = 5 and created_at < now() - interval '30 days'
            order by coalesce(last_activity_at, created_at) limit 25) q
    ),
    'trials_ending', (
      select coalesce(jsonb_agg(jsonb_build_object('id', tenant_id, 'name', name, 'trial_ends_at', trial_ends_at,
        'days_left', greatest(0, ceil(extract(epoch from (trial_ends_at - now())) / 86400))::integer,
        'stage_key', stage_key, 'contact_email', contact_email) order by trial_ends_at), '[]'::jsonb)
      from (select * from onb where subscription_status = 'trialing' and trial_ends_at is not null
              and trial_ends_at <= now() + interval '7 days' and status <> 'suspended'
            order by trial_ends_at limit 25) t
    ),
    'pending_over_threshold', (
      select coalesce(jsonb_agg(jsonb_build_object('id', tenant_id, 'name', name, 'stage_key', stage_key,
        'days_pending', greatest(0, extract(epoch from (now() - created_at)) / 86400)::integer,
        'contact_email', contact_email) order by created_at), '[]'::jsonb)
      from (select * from onb where status = 'pending' and created_at < now() - make_interval(days => v_threshold)
            order by created_at limit 25) p
    ),
    'open_impersonations', (
      select coalesce(jsonb_agg(jsonb_build_object('admin_email', au.email, 'tenant_name', t.name,
        'started_at', s.started_at, 'expires_at', s.expires_at, 'reason', s.reason) order by s.started_at), '[]'::jsonb)
      from impersonation_sessions s
      join tenants t on t.id = s.tenant_id
      left join auth.users au on au.id = s.platform_admin_id
      where s.ended_at is null and (s.expires_at is null or s.expires_at > now())
    ),
    'admins_without_mfa', (
      select coalesce(jsonb_agg(u.email order by u.email), '[]'::jsonb)
      from app_users u
      where u.is_platform_admin
        and not exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified')
    )
  ) into v_payload;

  -- Items that need a human today: everything except totals/new.
  v_payload := v_payload || jsonb_build_object('attention_count',
    jsonb_array_length(v_payload -> 'stalled')
    + jsonb_array_length(v_payload -> 'quiet')
    + jsonb_array_length(v_payload -> 'trials_ending')
    + jsonb_array_length(v_payload -> 'pending_over_threshold')
    + jsonb_array_length(v_payload -> 'admins_without_mfa'));

  return v_payload;
end;
$$;

revoke all on function public.platform_operator_digest_payload(timestamptz, timestamptz) from public, authenticated, anon;

-- 3b. One-line summary used for the in-app notification and the email
--     subject. Pure, so the client can reuse the same wording via the RPC.
create or replace function public.platform_digest_summary(p_payload jsonb)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when coalesce((p_payload ->> 'attention_count')::integer, 0) = 0
    then 'All clear - nothing needs attention'
    else concat_ws(' · ',
      nullif(jsonb_array_length(p_payload -> 'stalled'), 0) || ' stalled in setup',
      nullif(jsonb_array_length(p_payload -> 'trials_ending'), 0) || ' trial(s) ending',
      nullif(jsonb_array_length(p_payload -> 'quiet'), 0) || ' gone quiet',
      nullif(jsonb_array_length(p_payload -> 'pending_over_threshold'), 0) || ' pending too long',
      nullif(jsonb_array_length(p_payload -> 'admins_without_mfa'), 0) || ' admin(s) without MFA')
  end;
$$;

grant execute on function public.platform_digest_summary(jsonb) to authenticated, service_role;

-- 3c. Run: store the digest and notify every platform admin in-app.
create or replace function public.platform_run_operator_digest(p_trigger text default 'scheduled')
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_enabled    boolean := coalesce((select (notifications ->> 'digest_enabled')::boolean from platform_settings where id = true), true);
  v_recipients text[]  := coalesce((select array(select jsonb_array_elements_text(notifications -> 'alert_recipients')) from platform_settings where id = true), '{}');
  v_end        timestamptz := now();
  v_start      timestamptz;
  v_payload    jsonb;
  v_id         uuid;
  v_summary    text;
  v_admin      record;
begin
  if p_trigger not in ('scheduled', 'manual') then
    raise exception 'trigger must be scheduled or manual';
  end if;

  -- Scheduled runs respect the switch; a manual "Generate now" always runs.
  if p_trigger = 'scheduled' and not v_enabled then
    return null;
  end if;

  -- Period = since the previous run (any trigger), capped at 7 days so a
  -- long gap does not produce a "new companies" list going back months.
  v_start := greatest(
    coalesce((select max(period_end) from platform_digests), v_end - interval '1 day'),
    v_end - interval '7 days');

  v_payload := platform_operator_digest_payload(v_start, v_end);
  v_summary := platform_digest_summary(v_payload);

  insert into platform_digests (period_start, period_end, trigger, generated_by, attention_count, payload, recipients, delivery_status)
  values (v_start, v_end, p_trigger, auth.uid(), coalesce((v_payload ->> 'attention_count')::integer, 0), v_payload, v_recipients,
          case when cardinality(v_recipients) = 0 then 'skipped' else 'pending' end)
  returning id into v_id;

  -- In-app: one notification per platform admin. notifications.tenant_id
  -- is NOT NULL, so use the admin's own tenant (the home/internal one).
  for v_admin in select id, tenant_id from app_users where is_platform_admin loop
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (
      v_admin.tenant_id, v_admin.id, 'operator_digest',
      case when coalesce((v_payload ->> 'attention_count')::integer, 0) = 0
        then 'Operator digest: all clear'
        else format('Operator digest: %s item(s) need attention', v_payload ->> 'attention_count') end,
      v_summary
    );
  end loop;

  perform log_platform_event(
    'platform.digest.run', null, 'platform_digest', v_id::text, null, null,
    jsonb_build_object('trigger', p_trigger, 'attention_count', v_payload -> 'attention_count',
                       'recipients', cardinality(v_recipients), 'period_start', v_start, 'period_end', v_end)
  );

  return v_id;
end;
$$;

revoke all on function public.platform_run_operator_digest(text) from public, authenticated, anon;

-- 3d. Platform-admin RPCs.
create or replace function public.run_operator_digest_now()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  perform require_platform_admin('Generating the operator digest');
  v_id := platform_run_operator_digest('manual');
  return (select to_jsonb(d) from platform_digests d where d.id = v_id);
end;
$$;

revoke all on function public.run_operator_digest_now() from public;
grant execute on function public.run_operator_digest_now() to authenticated;

create or replace function public.list_platform_digests(p_limit integer default 14)
returns setof public.platform_digests
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select d.* from platform_digests d
  where is_platform_admin()
  order by d.generated_at desc
  limit greatest(1, least(coalesce(p_limit, 14), 90));
$$;

revoke all on function public.list_platform_digests(integer) from public;
grant execute on function public.list_platform_digests(integer) to authenticated;

-- 3e. Delivery bookkeeping for the edge function (service role only).
create or replace function public.mark_platform_digest_delivered(p_id uuid, p_status text, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', current_user) <> 'service_role'
     and current_user not in ('postgres', 'supabase_admin') then
    raise exception 'PLATFORM_ADMIN_REQUIRED: digest delivery is recorded by the service role only'
      using errcode = '42501';
  end if;
  if p_status not in ('sent', 'failed', 'skipped') then
    raise exception 'status must be sent, failed or skipped';
  end if;
  update platform_digests
     set delivery_status = p_status,
         delivered_at    = case when p_status = 'sent' then now() else delivered_at end,
         delivery_error  = nullif(btrim(p_error), '')
   where id = p_id;
end;
$$;

revoke all on function public.mark_platform_digest_delivered(uuid, text, text) from public, authenticated, anon;
grant execute on function public.mark_platform_digest_delivered(uuid, text, text) to service_role;

-- Pending digests for the mailer (service role reads platform_digests
-- directly -- RLS does not apply to it -- so no RPC is needed there).

-- 3f. Schedule. pg_cron is present on hosted Supabase and in the local
--     stack; guard anyway so a bare Postgres replay still succeeds.
do $$
declare
  v_job bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    select jobid into v_job from cron.job where jobname = 'platform_operator_digest_daily';
    if v_job is not null then
      perform cron.unschedule(v_job);
    end if;
    perform cron.schedule('platform_operator_digest_daily', '0 4 * * *', 'select public.platform_run_operator_digest(''scheduled'');');
  else
    raise notice 'pg_cron not installed: operator digest not scheduled (run platform_run_operator_digest() manually).';
  end if;
end $$;

-- 3g. Default the new notification switch on the singleton so the
--     Settings page shows the real state rather than an implicit default.
update public.platform_settings
   set notifications = notifications || jsonb_build_object('digest_enabled', true)
 where id = true
   and not (notifications ? 'digest_enabled');
