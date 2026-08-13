-- RECONSTRUCTED, NOT ORIGINAL.
--
-- This version+name exists in supabase_migrations.schema_migrations with
-- no corresponding local file. Reconstructed 2026-08-13 by introspecting
-- pg_policies on the live project (xownbroirovedkmqyybc).
--
-- Confidence: HIGH. The single policy below is an exact match for what
-- is currently live -- verified via:
--   select policyname, cmd, qual from pg_policies
--   where schemaname = 'public' and tablename = 'tenants';
--
-- Depends on: is_platform_admin(), created earlier in
-- 20260801132413_platform_admin_and_finance_team.sql (already local).
--
-- Note: applying this again would fail (policy already exists live).
-- This file exists to make local history match remote, not to be re-run
-- as-is against this project.

create policy tenants_select_platform_admin
  on public.tenants
  for select
  using (is_platform_admin());