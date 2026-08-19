-- Fixes a local-only gap: Supabase's hosted platform grants standard table
-- privileges (SELECT/INSERT/UPDATE/DELETE) to anon/authenticated/service_role
-- automatically outside the migration history whenever a table is created
-- via the hosted pipeline. `supabase db reset` locally runs migrations as
-- the plain `postgres` role and never receives that same automatic
-- treatment, so any table that only ever existed via migrations (i.e.
-- every table in this repo) ends up with RLS enabled but zero base grants
-- on a fresh local reset -- Postgres blocks the query with 42501
-- ("permission denied for table X") before RLS is ever evaluated.
--
-- First surfaced via cost_centers during a local procurement smoke test
-- (2026-08-14), but the same query above (`role_table_grants` diffed
-- against live) confirmed live already has full grants on every table --
-- this is purely a local-reset gap, not a live/production bug. This
-- migration is a safe no-op on live (re-granting an existing privilege
-- does nothing) and fixes local for good, for both this and every future
-- table.
--
-- Table-level GRANT is intentionally broad here, matching Supabase's own
-- standard baseline (confirmed against live: anon/authenticated already
-- hold SELECT/INSERT/UPDATE/DELETE on every existing table) -- RLS is the
-- real gate, not table grants. This migration does not change that model,
-- it just makes local match what live already does.

grant select, insert, update, delete on all tables in schema public
  to anon, authenticated, service_role;

grant usage, select on all sequences in schema public
  to anon, authenticated, service_role;

-- Applies to the `postgres` role specifically, since that's who actually
-- executes `supabase db reset` / `db push` / CI -- the earlier attempt at
-- this (20260812090000) targeted `supabase_admin` and failed with
-- "permission denied to change default privileges" for exactly that reason.
alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  grant usage, select on sequences to anon, authenticated, service_role;