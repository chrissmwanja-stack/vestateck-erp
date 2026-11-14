-- Regression test for 20261112090000_revoke_anon_and_excess_table_privileges.sql.
-- Plain psql script in one transaction; RAISEs on the first failed assertion.
begin;

do $$
declare n int; names text;
begin
  -- 1. `anon` holds no privilege on any table, view or sequence in public.
  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, names
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind in ('r','p','v','m','S','f')
    and (has_any_column_privilege('anon', c.oid, 'SELECT')
      or has_table_privilege('anon', c.oid, 'SELECT')
      or has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
      or has_table_privilege('anon', c.oid, 'TRUNCATE')
      or has_table_privilege('anon', c.oid, 'REFERENCES')
      or has_table_privilege('anon', c.oid, 'TRIGGER'));
  if n > 0 then raise exception 'anon still holds privileges on % relation(s): %', n, names; end if;
  raise notice 'PASS: anon holds no privilege on any public table, view or sequence';

  -- 2. `authenticated` keeps DML but not TRUNCATE / REFERENCES / TRIGGER.
  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, names
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind in ('r','p')
    and (has_table_privilege('authenticated', c.oid, 'TRUNCATE')
      or has_table_privilege('authenticated', c.oid, 'REFERENCES')
      or has_table_privilege('authenticated', c.oid, 'TRIGGER'));
  if n > 0 then raise exception 'authenticated still holds TRUNCATE/REFERENCES/TRIGGER on %: %', n, names; end if;
  raise notice 'PASS: authenticated holds no TRUNCATE/REFERENCES/TRIGGER on public tables';

  select count(*) into n
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind = 'r' and c.relname = 'tenants'
    and has_table_privilege('authenticated', c.oid, 'SELECT');
  if n <> 1 then raise exception 'authenticated lost SELECT on tenants (DML must be kept)'; end if;
  raise notice 'PASS: authenticated keeps SELECT on tenants';

  -- 3. Default privileges: nothing for anon, no TRUNCATE for authenticated.
  select count(*) into n
  from pg_default_acl d, lateral aclexplode(d.defaclacl) a
  where d.defaclnamespace = 'public'::regnamespace
    and d.defaclobjtype in ('r','S')
    and ((a.grantee = 'anon'::regrole)
      or (a.grantee = 'authenticated'::regrole and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER')));
  if n > 0 then raise exception 'default privileges would still grant anon/authenticated excess rights on new tables (% entries)', n; end if;
  raise notice 'PASS: default privileges grant anon nothing and authenticated no TRUNCATE/REFERENCES/TRIGGER';

  -- 4. A table created from now on inherits that: anon gets nothing.
  create table public.zz_anon_probe (id int);
  if has_table_privilege('anon', 'public.zz_anon_probe', 'SELECT')
     or has_table_privilege('anon', 'public.zz_anon_probe', 'INSERT') then
    raise exception 'a newly created table is readable/writable by anon';
  end if;
  raise notice 'PASS: a newly created table gives anon nothing';
end $$;

-- 5. Behaviour: as anon, reading or writing a tenant table is refused at the
--    privilege check, before RLS is even consulted.
set local role anon;
do $$
begin
  begin
    perform 1 from public.journal_entries limit 1;
    raise exception 'anon was able to SELECT journal_entries';
  exception when insufficient_privilege then
    raise notice 'PASS: anon SELECT on journal_entries -> permission denied';
  end;
  begin
    insert into public.tenants(id, name) values (gen_random_uuid(), 'x');
    raise exception 'anon was able to INSERT into tenants';
  exception when insufficient_privilege then
    raise notice 'PASS: anon INSERT into tenants -> permission denied';
  end;
end $$;
reset role;

-- 6. The three intentionally public RPCs still work for anon.
set local role anon;
do $$
declare r jsonb;
begin
  perform public.health_check();
  raise notice 'PASS: anon can still call health_check()';
  perform public.get_platform_branding();
  raise notice 'PASS: anon can still call get_platform_branding()';
end $$;
reset role;

rollback;
