-- Security catalog snapshot (READ-ONLY -- safe against a linked/remote project).
--
-- Prints one deterministic line per security-relevant catalog fact in schema
-- `public`, so CI can diff the replayed migrations against a committed
-- snapshot (supabase/catalog-snapshots/security-catalog.txt) and a human can
-- diff production against the same file.
--
-- Why this exists: the baseline squash was verified to match production's
-- tables, function bodies and policies, but NOT grants or view options. A
-- later check found 15 views had silently lost security_invoker (a
-- CREATE OR REPLACE VIEW without WITH (security_invoker = true) resets it);
-- migration 20261106130000 restored them. No test would have caught that
-- regression, because nothing asserted it. This snapshot makes every change
-- to these facts show up as a diff on the PR that causes it.
--
-- What is captured (effective privileges, i.e. after role membership and the
-- PUBLIC default, for anon / authenticated / service_role / PUBLIC):
--   schema    USAGE and CREATE on public
--   table|partitioned|view|matview
--             RLS enabled / forced, reloptions (security_invoker,
--             security_barrier, check_option, ...), and the privilege string
--             r=SELECT a=INSERT w=UPDATE d=DELETE D=TRUNCATE x=REFERENCES
--             t=TRIGGER ('-' where not held)
--   sequence  USAGE / SELECT / UPDATE (U r w)
--   colacl    column-level grants
--   function  SECURITY DEFINER flag, proconfig (search_path pin), and
--             EXECUTE for each role above (x or -)
--   defacl    default privileges that apply to objects created later
--
-- Extension-owned objects are skipped. Only privileges that exist on every
-- supported PostgreSQL version are checked (no MAINTAIN), so the output does
-- not depend on the server version.
--
-- Usage (see scripts/catalog-snapshot.sh):
--   psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -f supabase/scripts/catalog_security_snapshot.sql

with roles(r) as (
  values ('anon'), ('authenticated'), ('service_role'), ('public')
), rel as (
  select c.oid, c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity, c.reloptions
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p', 'v', 'm', 'S')
    and not c.relispartition
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
), lines as (

  -- schema ---------------------------------------------------------------
  select 'schema|public|' || string_agg(
           format('%s=%s%s', r,
                  case when has_schema_privilege(r, 'public', 'USAGE') then 'U' else '-' end,
                  case when has_schema_privilege(r, 'public', 'CREATE') then 'C' else '-' end),
           '|' order by r) as line
  from roles

  union all

  -- tables, views, materialized views -----------------------------------
  select format('%s|%s|rls=%s|force=%s|opts=%s|%s',
           case rel.relkind when 'r' then 'table' when 'p' then 'partitioned'
                            when 'v' then 'view' else 'matview' end,
           rel.relname,
           case when rel.relkind in ('r', 'p') then rel.relrowsecurity::text else '-' end,
           case when rel.relkind in ('r', 'p') then rel.relforcerowsecurity::text else '-' end,
           coalesce((select string_agg(o, ',' order by o) from unnest(rel.reloptions) o), '-'),
           (select string_agg(format('%s=%s', r,
                    (select string_agg(case when has_table_privilege(r, rel.oid, p.priv)
                                            then p.letter else '-' end, '' order by p.ord)
                     from (values (1, 'SELECT', 'r'), (2, 'INSERT', 'a'), (3, 'UPDATE', 'w'),
                                  (4, 'DELETE', 'd'), (5, 'TRUNCATE', 'D'),
                                  (6, 'REFERENCES', 'x'), (7, 'TRIGGER', 't')) p(ord, priv, letter))),
                   '|' order by r)
            from roles))
  from rel
  where rel.relkind <> 'S'

  union all

  -- sequences ----------------------------------------------------------
  select format('sequence|%s|%s', rel.relname,
           (select string_agg(format('%s=%s', r,
                    (select string_agg(case when has_sequence_privilege(r, rel.oid, p.priv)
                                            then p.letter else '-' end, '' order by p.ord)
                     from (values (1, 'USAGE', 'U'), (2, 'SELECT', 'r'), (3, 'UPDATE', 'w')) p(ord, priv, letter))),
                   '|' order by r)
            from roles))
  from rel
  where rel.relkind = 'S'

  union all

  -- column-level grants ------------------------------------------------
  select format('colacl|%s.%s|%s', rel.relname, a.attname,
           string_agg(format('%s=%s', coalesce(g.rolname, 'PUBLIC'), x.privilege_type),
                      ',' order by coalesce(g.rolname, 'PUBLIC'), x.privilege_type))
  from rel
  join pg_attribute a on a.attrelid = rel.oid and a.attnum > 0 and not a.attisdropped
                     and a.attacl is not null
  cross join lateral aclexplode(a.attacl) x
  left join pg_roles g on g.oid = x.grantee
  group by rel.relname, a.attname

  union all

  -- functions and procedures -------------------------------------------
  select format('function|public.%s(%s)|definer=%s|config=%s|%s',
           p.proname,
           pg_get_function_identity_arguments(p.oid),
           p.prosecdef,
           coalesce((select string_agg(c, ',' order by c) from unnest(p.proconfig) c), '-'),
           (select string_agg(format('%s=%s', r,
                    case when has_function_privilege(r, p.oid, 'EXECUTE') then 'x' else '-' end),
                   '|' order by r)
            from roles))
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind in ('f', 'p')
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')

  union all

  -- default privileges for objects created later -----------------------
  select format('defacl|%s|%s|%s|%s',
           pg_get_userbyid(d.defaclrole),
           coalesce(n.nspname, '*'),
           d.defaclobjtype,
           (select string_agg(format('%s=%s', coalesce(g.rolname, 'PUBLIC'), x.privilege_type),
                              ',' order by coalesce(g.rolname, 'PUBLIC'), x.privilege_type)
            from aclexplode(d.defaclacl) x
            left join pg_roles g on g.oid = x.grantee))
  from pg_default_acl d
  left join pg_namespace n on n.oid = d.defaclnamespace
  where d.defaclnamespace = 0 or n.nspname = 'public'
)
select line from lines order by line collate "C";
