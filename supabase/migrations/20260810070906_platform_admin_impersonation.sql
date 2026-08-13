-- RECONSTRUCTED, NOT ORIGINAL.
--
-- This version number and name (20260810070906_platform_admin_impersonation)
-- exists in the live project's schema_migrations table but has no
-- corresponding file anywhere in the repo -- it was applied directly
-- (dashboard SQL editor or MCP apply_migration) and never committed.
--
-- The SQL below was NOT recovered from any stored source -- Postgres/
-- Supabase does not retain migration file text, only the version+name in
-- supabase_migrations.schema_migrations. This is a reconstruction built by
-- introspecting the live objects on 2026-08-12 (pg_get_functiondef,
-- information_schema.columns, pg_indexes, pg_constraint, pg_policies,
-- has_function_privilege) and reassembling them into the DDL that would
-- produce the current live state.
--
-- Before committing this to the repo:
--   1. Diff it against a `supabase db pull` if you haven't already --
--      that's the authoritative source, this is a best-effort backfill.
--   2. Confirm the anon/authenticated grants below match your intent --
--      they reflect what's live today, not necessarily what was
--      originally written.
--   3. Applying this file again would fail (objects already exist) --
--      it's meant to make the repo's history match production, not to be
--      re-run. If you do want to re-run it for a fresh environment, add
--      `if not exists` / `create or replace` guards as needed.
--
-- Depends on: is_platform_admin() and app_users/tenants tables, both
-- already present as of 20260810055711_bootstrap_platform_admin.sql.

-- ── impersonation_sessions ────────────────────────────────────────────
create table public.impersonation_sessions (
  id uuid primary key default gen_random_uuid(),
  platform_admin_id uuid not null references public.app_users(id),
  tenant_id uuid not null references public.tenants(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create index impersonation_sessions_active_idx
  on public.impersonation_sessions (platform_admin_id)
  where ended_at is null;

alter table public.impersonation_sessions enable row level security;

create policy impersonation_sessions_select_own
  on public.impersonation_sessions
  for select
  using (platform_admin_id = auth.uid());

-- ── impersonation_logs (audit trail, append-only) ──────────────────────
create table public.impersonation_logs (
  id uuid primary key default gen_random_uuid(),
  platform_admin_id uuid not null,
  platform_admin_email text,
  tenant_id uuid,
  action text not null,
  logged_at timestamptz not null default now()
);

alter table public.impersonation_logs enable row level security;

create policy impersonation_logs_select_platform_admin
  on public.impersonation_logs
  for select
  using (is_platform_admin());

-- ── RPCs ─────────────────────────────────────────────────────────────
create or replace function public.start_impersonation(p_tenant_id uuid)
returns impersonation_sessions
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_session impersonation_sessions;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can start impersonation';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'No such tenant';
  end if;

  -- Close any stale/dangling session for this admin first.
  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_sessions (platform_admin_id, tenant_id)
  values (auth.uid(), p_tenant_id)
  returning * into v_session;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_tenant_id, 'start');

  return v_session;
end;
$function$;

create or replace function public.end_impersonation()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id
  from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null
  limit 1;

  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), v_tenant_id, 'end');
end;
$function$;

create or replace function public.get_active_impersonation()
returns table(tenant_id uuid, tenant_name text)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select t.id, t.name
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  where s.platform_admin_id = auth.uid() and s.ended_at is null
  limit 1;
$function$;

-- ── get_my_tenant_id(): add the impersonation-aware branch ─────────────
-- Pre-existing signature (STABLE SECURITY DEFINER, search_path hardened)
-- retained; only the body changes, to fall through to impersonation_sessions
-- before the ordinary app_users lookup.
create or replace function public.get_my_tenant_id()
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select tenant_id from impersonation_sessions
     where platform_admin_id = auth.uid() and ended_at is null
     limit 1),
    (select tenant_id from app_users where id = auth.uid())
  );
$function$;

-- ── Grants ──────────────────────────────────────────────────────────
-- Live state confirms anon has EXECUTE on none of these -- these
-- functions were not among the 21 caught by the supabase_admin
-- default-privilege gap, which suggests either an explicit revoke here
-- or that they were created under a session role that already had the
-- postgres-role default applied. Included explicitly so a fresh apply
-- doesn't regress it either way.
revoke execute on function public.start_impersonation(uuid) from public, anon;
revoke execute on function public.end_impersonation() from public, anon;
revoke execute on function public.get_active_impersonation() from public, anon;

-- Known gap, fixed separately: this migration's ended_at is null check
-- has no time bound, so a session left open indefinitely stays active.
-- See 20260812093000_bound_impersonation_session_expiry.sql.