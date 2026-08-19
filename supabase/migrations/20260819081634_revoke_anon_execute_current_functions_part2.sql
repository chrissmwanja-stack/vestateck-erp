-- Part 2 of the anon-execute cleanup (see
-- 20260813055036_revoke_anon_execute_current_functions_part1.sql for
-- part 1, applied 2026-08-13). Re-runs the same sweep: eight
-- platform-admin-only RPCs added since then (companies_console
-- overview/analytics, tenant module entitlements, tenant status,
-- and the workflow-stage threshold editor) were each created with an
-- explicit `grant execute ... to authenticated`, but none of those
-- migrations revoked the implicit EXECUTE-to-PUBLIC grant that
-- CREATE FUNCTION applies by default -- so all eight were reachable
-- pre-auth via /rest/v1/rpc/... despite every one of them having an
-- internal is_platform_admin() guard. Confirmed via get_advisors on
-- 2026-08-19: get_companies_overview, get_company_analytics,
-- get_my_tenant_status, get_tenant_modules, get_tenant_workflow_stages,
-- set_tenant_modules, set_tenant_status, update_workflow_stage_threshold.
--
-- platform_has_admin() is deliberately excluded, same as part 1: it's
-- called pre-login from BootstrapAdminPage.tsx to decide whether to
-- show the first-admin bootstrap flow, returns only a boolean with no
-- tenant data, and has no auth guard by design.
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