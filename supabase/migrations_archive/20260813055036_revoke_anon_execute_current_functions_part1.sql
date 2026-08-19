-- Part 1 of the anon-execute cleanup (see 20260812090000_revoke_anon_execute_supabase_admin_defaults.sql
-- for the still-blocked part 2). Applied 2026-08-13.
--
-- Part 2 of that migration (ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin)
-- failed with "permission denied to change default privileges" -- the
-- executing role isn't supabase_admin, a member of it, or a superuser.
-- That failure left a false "applied" row in schema_migrations for
-- version 20260812090000 (the tool recorded history independently of
-- whether the SQL succeeded) -- corrected via
-- `supabase migration repair --status reverted 20260812090000`.
--
-- This part -- the actual revoke sweep closing the live gap on the
-- functions currently exposed via anon EXECUTE -- ran as a separate,
-- independent statement and succeeded on its own. Confirmed live
-- afterward: only platform_has_admin() remains anon-executable among
-- non-extension public functions, exactly as intended.
--
-- 20260812090000 remains open, local-only, blocked on Supabase support
-- or an alternate approach for the supabase_admin default-privilege fix.

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
      and d.objid is null
      and p.proname <> 'platform_has_admin'
  loop
    execute format('revoke execute on function public.%I(%s) from public, anon;', r.proname, r.args);
  end loop;
end $$;