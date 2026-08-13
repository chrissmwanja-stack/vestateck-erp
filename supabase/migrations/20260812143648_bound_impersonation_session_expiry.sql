-- Follow-up to 20260810070906_platform_admin_impersonation.sql.
--
-- That migration built impersonation correctly except for one gap: the
-- session-resolution branch inside get_my_tenant_id() has no time bound.
-- A platform admin who starts impersonating a tenant and never explicitly
-- ends the session (closes the tab, loses network, forgets) stays
-- impersonating indefinitely, from any device, until someone notices and
-- manually sets ended_at.
--
-- Confirmed against the live function body (pg_get_functiondef) and the
-- live impersonation_sessions schema before writing this fix:
--
--   CREATE OR REPLACE FUNCTION public.get_my_tenant_id()
--    RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
--   AS $function$
--     select coalesce(
--       (select tenant_id from impersonation_sessions
--        where platform_admin_id = auth.uid() and ended_at is null
--        limit 1),
--       (select tenant_id from app_users where id = auth.uid())
--     );
--   $function$
--
--   impersonation_sessions columns: id, platform_admin_id, tenant_id,
--   started_at (timestamptz, default now(), not null), ended_at (timestamptz, nullable)
--
-- Note: the column is `started_at`, not `created_at` -- any fix written
-- against `created_at` will fail outright with
-- `column "created_at" does not exist`. Verify against the live schema
-- before editing this function again; it isn't in the local repo (it's
-- one of the migrations applied outside version control -- see the
-- migration-drift note in the audit report), so there's no local file to
-- cross-check it against.
--
-- Fix, two parts, mirroring the existing expire-approval-delegations
-- pg_cron job already running in this project (5-minute cadence, flips a
-- stale row closed on a timer -- same shape, applied here to sessions
-- instead of delegations):
--
--   1. Bound the impersonation branch of get_my_tenant_id() to sessions
--      started within the last 2 hours, so a stale session stops being
--      honored immediately even before the sweep job runs.
--   2. Add a pg_cron job that explicitly closes (ended_at = now()) any
--      session older than 2 hours, so the audit trail reflects reality
--      and long-idle sessions don't just sit there silently unbounded.
--
-- 2 hours is a starting point, not a magic number -- tighten it if your
-- support/admin workflows don't need sessions that long.

-- 1. Bound the impersonation window inside get_my_tenant_id()
create or replace function public.get_my_tenant_id()
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select tenant_id from impersonation_sessions
     where platform_admin_id = auth.uid()
       and ended_at is null
       and started_at > now() - interval '2 hours'
     limit 1),
    (select tenant_id from app_users where id = auth.uid())
  );
$function$;

-- 2. Explicitly close sessions once they age past the same window, so
--    `ended_at` reflects why a session stopped (timeout, not just "the
--    function silently stopped honoring it"). Matches the existing
--    expire-approval-delegations job's shape and cadence.
select cron.schedule(
  'expire-impersonation-sessions',
  '*/5 * * * *',
  $$
    update public.impersonation_sessions
    set ended_at = now()
    where ended_at is null
      and started_at < now() - interval '2 hours';
  $$
);

-- Verification after applying:
--   - select cron.job where jobname = 'expire-impersonation-sessions';
--     should show one active row, same schedule shape as
--     expire-approval-delegations
--   - start a test impersonation session, backdate started_at to
--     3 hours ago (as a role with UPDATE on the table), then call
--     get_my_tenant_id() as that platform admin -- should now resolve to
--     their own app_users.tenant_id, not the impersonated tenant
--   - wait for (or manually trigger) the next cron tick and confirm
--     ended_at gets set on that same backdated row
--
-- This does not change bootstrap-admin's check-then-insert race
-- (separate, lower-priority issue) or anything in the anon-execute
-- default-privilege fix (20260812090000_revoke_anon_execute_supabase_admin_defaults.sql)
-- -- unrelated surfaces, kept as separate migrations on purpose.