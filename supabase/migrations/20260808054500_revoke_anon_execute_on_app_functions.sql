-- Security audit: 144 app functions (owned by postgres, in the public
-- schema) were EXECUTE-granted to anon -- both via an explicit anon grant
-- AND via a blanket PUBLIC grant (Postgres's implicit default combined
-- with Supabase's own ALTER DEFAULT PRIVILEGES setup for the postgres
-- role, which auto-grants anon/authenticated/service_role on every new
-- function). This included all 120 SECURITY DEFINER RPCs flagged by the
-- Supabase security advisor (edit_purchase_order, decide_access_request,
-- cancel_request, record_approval_decision, etc.) plus ~24 trigger/helper
-- functions not directly flagged but equally unnecessary to expose.
--
-- This ERP is invite-only with no public signup and no pre-auth RPC calls
-- anywhere in the frontend (verified against apps/web/src/features/auth/*
-- and App.tsx). There is no legitimate reason for an unauthenticated
-- client to call ANY app function. RLS checks inside these functions
-- (auth.uid() = ...) are defense-in-depth, not a substitute for actually
-- restricting who can invoke the function in the first place.
--
-- Revoking from PUBLIC is required, not optional: anon inherits from
-- PUBLIC, so revoking only the explicit anon grant would leave anon with
-- access anyway via the PUBLIC entry.
--
-- authenticated and service_role grants are left fully intact.
--
-- Verified live after applying:
--   - 0/144 functions remain anon-executable, 144/144 remain
--     authenticated-executable
--   - `set role authenticated; select get_my_tenant_id();` succeeds
--   - `set role anon; select get_my_tenant_id();` -> permission denied
--   - Security advisor's 120 anon_security_definer_function_executable
--     warnings are gone; authenticated_security_definer_function_executable
--     warnings remain (expected -- that's the normal, intended RPC surface)

do $$
declare
  r record;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proowner = 'postgres'::regrole
      and has_function_privilege('anon', p.oid, 'EXECUTE')
  loop
    execute format('revoke execute on function public.%I(%s) from public, anon;', r.proname, r.args);
  end loop;
end $$;

-- Future-proofing: prevent every subsequent apply_migration-created
-- function from automatically re-granting anon EXECUTE. Table/sequence
-- default privileges are deliberately left untouched -- RLS is the real
-- guard on tables, and Supabase's client libraries expect table-level
-- grants to exist for RLS-gated access to work at all.
alter default privileges for role postgres in schema public
  revoke execute on functions from anon;
