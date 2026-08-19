-- RECONSTRUCTED, NOT ORIGINAL.
--
-- This version+name exists in supabase_migrations.schema_migrations with
-- no corresponding local file. Reconstructed 2026-08-13 by introspecting
-- live objects on the live project (xownbroirovedkmqyybc).
--
-- Confidence: MEDIUM -- the function below is confirmed live and
-- anon-executable (verified via has_function_privilege), but this is
-- likely only PART of what the original migration did.
--
-- What was checked and NOT found live:
--   - No function matching %bootstrap%, %first_user%, or %claim%
--   - No INSERT policy on public.app_users (only one policy exists on
--     that table: app_users_select_tenant, a SELECT policy)
--
-- Implication: the "check-then-insert" first-admin bootstrap flow that
-- the session notes flag as an open race condition is NOT implemented
-- as a database RPC or RLS policy. It is almost certainly implemented
-- in an edge function (e.g. create-tenant) running under service_role,
-- which bypasses RLS entirely and is invisible to schema introspection.
-- That means the actual race lives in application code this migration
-- can't recover. Treat this file as covering only the DB-visible half.
--
-- Depends on: is_platform_admin(), already present as of
-- 20260801132413_platform_admin_and_finance_team.sql (already local).
-- That earlier migration also already added app_users.is_platform_admin
-- (boolean, not null, default false) -- confirmed via
-- information_schema.columns, so it is NOT recreated here.

create or replace function public.platform_has_admin()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (select 1 from app_users where is_platform_admin = true);
$function$;

-- Confirmed live: anon CAN execute this (intentional -- supports a
-- pre-auth "does this platform need first-run admin setup?" check from
-- the frontend before any login has occurred). Do not revoke.
grant execute on function public.platform_has_admin() to anon;

-- Verification:
--   set role anon; select platform_has_admin(); -- should succeed