-- Follow-up to 20260808053905_revoke_anon_execute_on_app_functions.sql.
--
-- That migration correctly revoked anon EXECUTE on all 144 flagged
-- functions and set a default-privilege guard for role `postgres`:
--
--   alter default privileges for role postgres in schema public
--     revoke execute on functions from anon;
--
-- What it missed: Postgres default privileges are keyed to the role that
-- actually executes CREATE FUNCTION, not the function's final owner. Every
-- one of the 144 functions fixed on Aug 8 happened to have been created
-- under the `postgres` role's default-privilege entry, so that fix held
-- for them. But Supabase's own migration/MCP tooling runs DDL as (or
-- through) `supabase_admin`, and `supabase_admin` has its own, separate
-- default-privilege entry in pg_default_acl -- one that was never touched
-- and still auto-grants anon EXECUTE on every function created that way.
--
-- This is why every function added since Aug 8 -- most notably the HR
-- payroll module and the stock/goods-receipt functions around it --
-- came back anon-executable even though the original fix was never
-- reverted.
--
-- CORRECTED 2026-08-13, before first application: the original draft of
-- this migration swept EVERY function in `public` currently anon-
-- executable, with two problems, both confirmed against a fresh live
-- check immediately before this correction:
--
--   1. platform_has_admin() was caught by the blanket sweep. This is
--      INTENTIONAL and must stay anon-executable -- it backs a pre-auth
--      "does this platform need first-run admin setup?" check the
--      frontend needs to run before any login has occurred. Explicitly
--      excluded below.
--   2. The sweep also matched ~185 btree_gist extension support
--      functions (gbt_*, gbtreekey*_in/out, *_dist) -- these are
--      PostgreSQL extension internals invoked by the GiST index
--      machinery itself, not application code, and were never part of
--      the intended scope. Excluded below via pg_depend/pg_extension so
--      the sweep only ever touches functions this project actually
--      wrote.
--
-- Actual risk from the remaining ~26 app functions was already low --
-- every one gates on auth.uid()-based checks that are null-safe for an
-- unauthenticated caller (anon gets `not authorized`, not data) -- but
-- this closes the gap at its root instead of leaving it to reopen with
-- the next function-creating migration.

-- 1. Close the supabase_admin default-privilege gap permanently, same
--    shape as the existing postgres-role guard from Aug 8.
alter default privileges for role supabase_admin in schema public
  revoke execute on functions from anon;

-- 2. Re-sweep every function currently anon-executable, EXCLUDING:
--    - platform_has_admin() (intentional pre-auth check, see above)
--    - any function owned by an extension (e.g. btree_gist), identified
--      via pg_depend's extension-membership dependency rather than a
--      hardcoded name list, so this stays correct if extensions change.
do $$
declare
  r record;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    left join pg_depend d on d.objid = p.oid and d.deptype = 'e'
    where n.nspname = 'public'
      and has_function_privilege('anon', p.oid, 'EXECUTE')
      and d.objid is null                          -- not extension-owned
      and p.proname <> 'platform_has_admin'         -- intentionally anon-callable
  loop
    execute format('revoke execute on function public.%I(%s) from public, anon;', r.proname, r.args);
  end loop;
end $$;

-- Verification after applying:
--   - `set role anon; select platform_has_admin();` should still succeed
--   - `set role anon; select gbt_int4_compress(null);` (or any btree_gist
--     internal) is unaffected either way -- these aren't meaningfully
--     callable directly regardless of grants, included here only to
--     confirm the sweep didn't touch them
--   - `set role authenticated; select is_hr_team_member('any');` should
--     still succeed (authenticated grants are untouched by this migration)
--   - `set role anon; select create_payroll_run('2026-08');` should now
--     fail with `permission denied for function create_payroll_run`
--     rather than reaching the internal is_hr_team_member() check
--
-- Note: this only guards against the supabase_admin/postgres default-
-- privilege split repeating for FUNCTIONS. It does not change table or
-- sequence grants (RLS remains the real guard there, same rationale as
-- the Aug 8 migration). If a future audit finds anon-executable
-- application functions again, check pg_default_acl for a third role
-- entry before assuming this fix regressed -- e.g. if migrations ever
-- get applied via the Supabase dashboard SQL editor under a different
-- session role.