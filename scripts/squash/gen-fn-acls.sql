select stmt from (
  select 1 o, format('REVOKE ALL ON ROUTINE %s FROM PUBLIC;', p.oid::regprocedure) stmt
  from pg_proc p
  where p.pronamespace='public'::regnamespace and p.prokind in ('f','p') and p.proacl is not null
    and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
  union all
  select 2, format('GRANT EXECUTE ON ROUTINE %s TO %s;', p.oid::regprocedure,
         case when a.grantee=0 then 'PUBLIC' else quote_ident(pg_get_userbyid(a.grantee)) end)
  from pg_proc p cross join lateral aclexplode(p.proacl) a
  where p.pronamespace='public'::regnamespace and p.prokind in ('f','p') and p.proacl is not null
    and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
    and a.privilege_type='EXECUTE' and a.grantee <> p.proowner
  union all
  select 3, format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO %s;',
         case when a.grantee=0 then 'PUBLIC' else quote_ident(pg_get_userbyid(a.grantee)) end)
  from pg_default_acl d cross join lateral aclexplode(d.defaclacl) a
  where d.defaclrole='postgres'::regrole and d.defaclnamespace='public'::regnamespace
    and d.defaclobjtype='f' and a.privilege_type='EXECUTE' and a.grantee <> 'postgres'::regrole
) s order by o, stmt;