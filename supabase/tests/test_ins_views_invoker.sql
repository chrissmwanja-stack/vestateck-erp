-- Catalog test: the two insurance reporting views must run as the caller and
-- must not depend on tables an insurance-only user cannot read.
-- Read-only; safe against production and a replay database.
do $$
declare
  v text;
  f text;
begin
  foreach v in array array['ins_production_book', 'ins_client_statement'] loop
    -- 1. security_invoker
    if not exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral unnest(coalesce(c.reloptions, '{}')) o
      where n.nspname = 'public' and c.relname = v
        and o ~ '^security_invoker=(true|on|1)$'
    ) then
      raise exception 'FAIL: public.% is not security_invoker', v;
    end if;

    -- 2. no direct dependency on finance-only tables or organizations
    if pg_get_viewdef(('public.' || v)::regclass) ~* '\m(fin_open_items|fin_allocations|fin_settlements|organizations)\M' then
      raise exception 'FAIL: public.% reads a table an insurance-only user cannot see; use a helper', v;
    end if;

    -- 3. read-only
    if has_table_privilege('authenticated', ('public.' || v)::regclass, 'INSERT,UPDATE,DELETE,TRUNCATE')
       or has_table_privilege('anon', ('public.' || v)::regclass, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then
      raise exception 'FAIL: public.% has excess privileges', v;
    end if;
  end loop;

  -- 4. helpers: definer, pinned search_path, not anon-executable
  foreach f in array array['ins_policy_endorsement_receipts(uuid)', 'ins_branch_name(uuid)'] loop
    if not exists (
      select 1 from pg_proc p
      where p.oid = ('public.' || f)::regprocedure
        and p.prosecdef
        and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
    ) then
      raise exception 'FAIL: public.% must be SECURITY DEFINER with a pinned search_path', f;
    end if;
    if has_function_privilege('anon', ('public.' || f)::regprocedure, 'EXECUTE') then
      raise exception 'FAIL: public.% is anon-executable', f;
    end if;
  end loop;

  raise notice 'OK: insurance reporting views are security_invoker and self-sufficient';
end $$;
