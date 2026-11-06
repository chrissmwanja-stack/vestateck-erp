-- Catalog invariants that must hold on every environment (tier 0 hardening).
-- Read-only: it only queries the catalog and changes nothing, so it is safe
-- to run against a linked project as well as the CI replay database.
--
--   1. Every base table in public has row level security enabled.
--   2. Every function in public pins search_path. check_live_security_drift.sql
--      section 15 covers SECURITY DEFINER functions; this extends it to
--      SECURITY INVOKER ones (the advisor flags both).
--   3. The only SECURITY DEFINER functions anon can execute are the three
--      intentional ones. A new anon-executable definer function fails here.
--   4. Views must be security_invoker. There are no known exceptions now; an entry
--      added to v_known_gap is reported as a GAP notice (they never fail the run, per the convention in
--      security_authorization.sql); any OTHER non-invoker view fails.
--      Remove an entry from v_known_gap when its view is fixed.
--
-- Run: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/test_production_invariants.sql

do $$
declare
  v_fail text[] := '{}';
  v_known_gap text[] := '{}';
  v_anon_ok text[] := array['health_check', 'get_platform_branding', 'keepalive_ping'];
  r record;
begin
  -- 1. RLS on every base table
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and not c.relispartition
       and not c.relrowsecurity
       and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
     order by 1
  loop
    v_fail := v_fail || format('table public.%s has row level security disabled', r.relname);
  end loop;

  -- 2. Every function pins search_path
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind in ('f', 'p')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
       and not exists (
         select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
          where cfg like 'search_path=%')
     order by 1, 2
  loop
    v_fail := v_fail || format('function public.%s(%s) does not pin search_path', r.proname, r.args);
  end loop;

  -- 3. anon-executable SECURITY DEFINER functions are an explicit allowlist
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and p.prosecdef
       and has_function_privilege('anon', p.oid, 'EXECUTE')
       and not (p.proname = any (v_anon_ok))
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     order by 1, 2
  loop
    v_fail := v_fail || format('function public.%s(%s) is SECURITY DEFINER and executable by anon', r.proname, r.args);
  end loop;

  -- 4. Views must be security_invoker (known gaps are notices, not failures)
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'v'
       and not coalesce(c.reloptions @> array['security_invoker=true'], false)
       and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
     order by 1
  loop
    if r.relname = any (v_known_gap) then
      raise notice 'GAP: view public.% is not security_invoker (known gap)', r.relname;
    else
      v_fail := v_fail || format('view public.%s is not security_invoker', r.relname);
    end if;
  end loop;

  if cardinality(v_fail) > 0 then
    raise exception E'FAIL: production invariants violated:\n  - %', array_to_string(v_fail, E'\n  - ');
  end if;
  raise notice 'PASS: production invariants hold (RLS on all tables, pinned search_path, anon allowlist, view invoker ratchet)';
end $$;
