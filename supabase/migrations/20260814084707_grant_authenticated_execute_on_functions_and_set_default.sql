-- Same root cause as 20260814081409_grant_standard_table_privileges_and_set_default.sql,
-- one layer deeper: that migration fixed table/sequence grants for local `db reset`
-- but did not touch functions.
--
-- Confirmed live behaviour (2026-08-14): all 172 non-extension public functions
-- have EXECUTE granted to `authenticated` and `service_role`, even though the
-- three revoke_anon_execute_* migrations (20260808053905, 20260812090000,
-- 20260813055036) only ever REVOKE (from PUBLIC/anon) -- none of them contain a
-- single explicit GRANT to authenticated. Checking pg_proc.proacl directly
-- confirms authenticated holds its own explicit grant entry, not an inherited
-- one from PUBLIC (PUBLIC's entry is absent, consistent with the revoke sweeps).
--
-- Root cause: Supabase's hosted platform sets a default-privilege rule for
-- functions created under `supabase_admin` (confirmed via pg_default_acl) that
-- auto-grants EXECUTE to postgres/anon/authenticated/service_role -- baked in
-- at project provisioning, outside migration history, same mechanism already
-- identified for table grants. A local `supabase db reset` runs entirely as
-- `postgres`, which never received an equivalent default for authenticated
-- (the Aug 8/12/13 migrations only ever set `postgres`'s function default to
-- REVOKE from anon -- they never added a GRANT to authenticated). Since
-- ALTER DEFAULT PRIVILEGES never applies retroactively, this also means
-- pre-existing functions like get_my_tenant_id (created in 0001, long before
-- any default-privilege migration existed) need an explicit backfill grant,
-- not just a forward-looking default rule.

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
      and d.objid is null
  loop
    execute format('grant execute on function public.%I(%s) to authenticated, service_role;', r.proname, r.args);
  end loop;
end $$;

alter default privileges for role postgres in schema public
  grant execute on functions to authenticated, service_role;