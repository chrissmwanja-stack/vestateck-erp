-- =====================================================================
-- Phase 1 hardening: every public SECURITY DEFINER function gets a pinned
-- search_path (pg_catalog, public) if it does not already have one.
-- Unpinned definer functions are a privilege-escalation vector (search_path
-- hijack); ALTER FUNCTION ... SET is the non-destructive fix.
-- =====================================================================

do $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select p.oid::regprocedure::text as fn
    from pg_proc p
    join pg_namespace nspace on nspace.oid = p.pronamespace
    where nspace.nspname = 'public'
      and p.prosecdef
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c
        where c like 'search_path=%'
      )
  loop
    execute format('alter function %s set search_path = pg_catalog, public', r.fn);
    n := n + 1;
  end loop;
  raise notice 'pinned search_path on % public security definer functions', n;
end $$;
