-- ============================================================================
-- 01_check_anon_exposure.sql — READ ONLY.
-- Establishes whether RC-1 is a live exposure or just a diff artifact.
-- Run against the post-reset DB (fingerprint B state).
-- ============================================================================
\pset border 2
\set ON_ERROR_STOP on

\echo '### 1. Effective privilege census (this is the truth; raw proacl text is not)'
select
  count(*)                                                                       as total_fns,
  count(*) filter (where p.proacl is null)                                        as null_acl_means_public_exec,
  count(*) filter (where has_function_privilege('anon',           p.oid, 'EXECUTE')) as anon_can_exec,
  count(*) filter (where has_function_privilege('authenticated',  p.oid, 'EXECUTE')) as auth_can_exec,
  count(*) filter (where has_function_privilege('service_role',   p.oid, 'EXECUTE')) as svc_can_exec,
  count(*) filter (where p.prosecdef)                                             as security_definer,
  count(*) filter (where p.prosecdef
                     and has_function_privilege('anon', p.oid, 'EXECUTE'))         as secdef_anon_callable
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind in ('f','p');

\echo ''
\echo '### 2. THE HEADLINE NUMBER: SECURITY DEFINER + anon-callable + owner is privileged'
\echo '###    Every one of these is POST /rest/v1/rpc/<name> with the anon key, running as the owner.'
select count(*) as secdef_anon_callable_privileged_owner
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_roles r on r.oid = p.proowner
where n.nspname = 'public' and p.prokind in ('f','p')
  and p.prosecdef
  and has_function_privilege('anon', p.oid, 'EXECUTE')
  and (r.rolsuper or r.rolname in ('postgres','supabase_admin'));

\echo ''
\echo '### 3. Name them (worst first: superuser owner, then no pinned search_path)'
select r.rolname                                        as owner,
       r.rolsuper,
       p.proname,
       pg_get_function_identity_arguments(p.oid)         as args,
       coalesce(array_to_string(p.proconfig, ','), '')   as proconfig,
       (select count(*) from unnest(p.proconfig) c
          where c like 'search_path%') = 0               as no_pinned_search_path,
       p.proacl is null                                  as acl_is_null_default_public
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_roles r on r.oid = p.proowner
where n.nspname = 'public' and p.prokind in ('f','p')
  and p.prosecdef
  and has_function_privilege('anon', p.oid, 'EXECUTE')
order by r.rolsuper desc, no_pinned_search_path desc, p.proname
limit 80;

\echo ''
\echo '### 4. Cross-check against the archived hardening migrations.'
\echo '###    These are the functions your old state deliberately closed to anon.'
\echo '###    If they appear in section 3, the squash reverted the campaign.'
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef, p.proacl::text
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind in ('f','p')
  and (p.proname in (
        'is_company_admin','platform_has_admin','am_i_finance',
        'can_access_finance','can_access_insurance','can_manage_insurance',
        'can_access_client_master','can_manage_client_master',
        'apply_tenant_read_only_guard','documents_guard','documents_via_rpc',
        'acct_assert_reviewed','assert_tenant_access','can_act_on_stage',
        'delete_empty_tenant','create_access_request','decide_access_request')
    or p.proname like '%\_guard'
    or p.proname like 'ins\_%snapshot%')
order by p.proname;

\echo ''
\echo '### 5. Functions callable by anon whose body is NOT security definer'
\echo '###    (lower risk, but still anonymous RPC surface via PostgREST)'
select count(*) as anon_callable_invoker_fns
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind in ('f','p')
  and not p.prosecdef
  and has_function_privilege('anon', p.oid, 'EXECUTE');

\echo ''
\echo '### 6. PostgREST exposure: is public in the exposed schemas?'
select current_setting('pgrst.db_schemas',  true) as exposed_schemas,
       current_setting('pgrst.db_anon_role', true) as anon_role,
       current_setting('pgrst.db_extra_search_path', true) as extra_search_path;

\echo ''
\echo '### 7. Live proof (run from PowerShell, not psql).'
\echo '###    Pick a side-effect-free name from section 3, e.g. am_i_finance().'
\echo '###    403/permission denied  = closed.  200 with true/false = ANON CAN CALL IT.'
\echo ''
\echo '  $k = (Select-String -Path supabase\.temp\api-keys.json -Pattern "anon").Line'
\echo '  curl.exe -s -o - -w "`nHTTP %{http_code}`n" http://127.0.0.1:54321/rest/v1/rpc/am_i_finance `'
\echo '    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" `'
\echo '    -H "Content-Type: application/json" -d "{}"'
\echo ''
\echo '  # anon key for the local stack is also printed by: npx supabase status'

\echo ''
\echo '### 8. Dependency check BEFORE you re-apply any REVOKE sweep'
\echo '###    Policies and security_invoker views that call these functions need'
\echo '###    EXECUTE for the CALLING role, or RLS fails at query time.'
select distinct
       n.nspname || '.' || c.relname as table_name,
       pol.polname,
       pol.polcmd,
       pol.polroles::regrole[] as roles,
       m[1]                    as fn_called
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
cross join lateral regexp_matches(
       coalesce(pg_get_expr(pol.polqual, pol.polrelid, true), '') || ' ' ||
       coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid, true), ''),
       '(?:public\.)?([a-z_][a-z0-9_$]*)\s*\(', 'gi') as m
where n.nspname in ('public','storage')
order by 1, 2;
