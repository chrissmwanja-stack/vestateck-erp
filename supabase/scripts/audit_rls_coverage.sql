-- RLS coverage audit.
--
-- Lists every ordinary/partitioned table in `public` with its row level
-- security state, so CI can fail the moment a new table ships without a
-- barrier. This matters here because the baseline sets default privileges
-- that give `authenticated` (and `anon`) full DML on every table: RLS is the
-- ONLY thing between a client and the data (see README "Status").
--
-- CI (foundation-checks.yml) FAILS on:
--   NO-RLS     : row level security is not enabled on the table.
--   NO-POLICY  : RLS is on but there is no policy at all. That denies every
--                client role, which is safe but is almost always a mistake;
--                if a table is meant to be internal (only SECURITY DEFINER
--                functions touch it) add an explicit deny policy, like
--                doc_sequences_no_client_access, so the intent is on record.
--
-- Not failed, printed for review:
--   anon_write : `anon` holds INSERT/UPDATE/DELETE/TRUNCATE on the table.
--                RLS still applies to INSERT/UPDATE/DELETE, but TRUNCATE is
--                never subject to RLS. PostgREST cannot issue TRUNCATE, so
--                this is defence in depth rather than an open hole.
--
-- Tables that belong to an extension are skipped.

with t as (
  select c.oid,
         c.relname,
         c.relrowsecurity,
         (select count(*) from pg_policy p where p.polrelid = c.oid) as policies,
         has_table_privilege('anon', c.oid, 'INSERT')
           or has_table_privilege('anon', c.oid, 'UPDATE')
           or has_table_privilege('anon', c.oid, 'DELETE')
           or has_table_privilege('anon', c.oid, 'TRUNCATE') as anon_write
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and not c.relispartition
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_class'::regclass
        and d.objid = c.oid
        and d.deptype = 'e')
), allow_no_policy(relname) as (
  -- Tables deliberately left without a policy. Keep this empty if you can:
  -- prefer an explicit deny policy. Add as: values ('table_name')
  select null::text where false
)
select relname as table_name,
       relrowsecurity as rls_enabled,
       policies,
       anon_write,
       case
         when not relrowsecurity then 'NO-RLS'
         when policies = 0 and relname not in (select relname from allow_no_policy) then 'NO-POLICY'
         else 'OK'
       end as risk
from t
order by case
           when not relrowsecurity then 0
           when policies = 0 then 1
           else 2
         end,
         relname;
