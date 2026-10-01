-- SECURITY DEFINER exposure audit (report priority 3).
--
-- Lists every public SECURITY DEFINER function that anon, authenticated or
-- PUBLIC can EXECUTE, with signals for how risky that is. Derived purely
-- from PostgreSQL metadata; there is no hand-maintained function list except
-- the explicit allowlist below.
--
-- CI (foundation-checks.yml) FAILS when a row has risk = 'CRITICAL', i.e. a
-- client-executable definer function that takes a tenant id, is not a
-- read-only getter, and whose body never consults get_my_tenant_id(),
-- effective_user_id(), auth.uid(), is_platform_admin() or another permission
-- helper. Everything else is printed for review, not failed.
--
-- Signals (all heuristic, from pg_proc.prosrc):
--   takes_tenant_id : an argument named like *tenant_id*
--   mutates         : body contains insert/update/delete/truncate/alter/drop
--   has_guard       : body references a tenant/identity/permission helper
--   trigger_fn      : returns trigger (cannot be called as an RPC anyway)

with fn as (
  select p.oid,
         p.proname,
         pg_get_function_identity_arguments(p.oid) as args,
         p.prorettype = 'pg_catalog.trigger'::regtype as trigger_fn,
         coalesce(pg_get_function_arguments(p.oid) ~* 'tenant_id', false) as takes_tenant_id,
         p.prosrc ~* '\m(insert\s+into|update\s+\S+\s+set|delete\s+from|truncate|alter\s|drop\s|execute\s+format)' as mutates,
         p.prosrc ~* '(get_my_tenant_id|effective_user_id|auth\.uid|is_platform_admin|require_platform_admin|has_module_role|can_access_finance|is_finance_team_member|is_company_admin|is_tenant_admin|is_hr_team_member|is_it_support|has_po_access|has_receipt_access|is_payroll_approver|platform_admin_bypass|assert_tenant_access|auth\.role|current_user)' as has_guard,
         has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and p.prokind = 'f'
), allow(proname) as (
  -- Intentionally public / pure helpers. Keep this list tiny and justified.
  values ('health_check'), ('get_platform_branding')
), known_open(proname) as (
  -- Confirmed gaps that cannot be fixed by a simple REVOKE and are tracked
  -- separately. Listed so CI stays green while they stay VISIBLE in the
  -- output as KNOWN-OPEN; remove an entry as soon as its fix ships.
  --   (empty) next_doc_number() was closed in
  --   20261001150000_close_next_doc_number_tenant_isolation.sql via
  --   assert_tenant_access(). Add new entries as: values ('fn_name')
  select null::text where false
)
select proname as function,
       args,
       anon_exec,
       auth_exec,
       mutates,
       takes_tenant_id,
       has_guard,
       trigger_fn,
       case
         when proname in (select proname from allow) then 'INTENDED'
         when proname in (select proname from known_open) then 'KNOWN-OPEN'
         when not (anon_exec or auth_exec) then 'INTERNAL'
         when trigger_fn then 'LOW (trigger fn)'
         when takes_tenant_id and mutates and not has_guard then 'CRITICAL'
         when takes_tenant_id and not has_guard then 'HIGH'
         when mutates and not has_guard then 'HIGH'
         else 'REVIEW'
       end as risk
from fn
where anon_exec or auth_exec
order by case
           when takes_tenant_id and mutates and not has_guard and not trigger_fn and proname not in (select proname from allow) and proname not in (select proname from known_open) then 0
           when (takes_tenant_id or mutates) and not has_guard and not trigger_fn then 1
           else 2
         end,
         proname;
