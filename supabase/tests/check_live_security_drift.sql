-- Catalog-level security drift check (READ-ONLY -- safe to run against a
-- linked/remote project, unlike the behavioural tests in this directory).
--
-- Why this exists: the 2026-09-29 incident. Several RLS/trigger hardening
-- migrations were recorded in schema_migrations as applied but their
-- policy/trigger statements never ran in production (the files were edited
-- after their versions were recorded, so the CLI skipped them). Every
-- behavioural test still passed because CI replays the migration FILES onto
-- a fresh database -- it can never see drift in a database that has already
-- recorded those versions. Some older tests also assert against temp tables
-- rather than the real ones, so they cannot see a missing trigger either.
--
-- This script asserts the security-relevant catalog state directly. Run it
-- against production after every migration batch:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/check_live_security_drift.sql
-- (or paste it into the Supabase SQL editor / MCP execute_sql).
-- It collects ALL failures and raises one exception listing them; on
-- success it emits a NOTICE and changes nothing.
--
-- Keep the lists below in sync with the migrations when adding new
-- module-gated tables or guarded triggers.
--
-- Section 9 (added after the law-guard / journal-trigger follow-up) checks
-- function BODIES, not just existence: the first pass of this script passed
-- on both a NULL-bypassable law guard and a journal trigger that errored on
-- journal_entry_lines, because it only asserted that triggers were attached.
--
-- Section 10 (added with security_authorization.sql) checks the payroll
-- separation-of-duties / PO handoff / staff_roles / module-enablement fixes:
-- function bodies, the staff_roles write policies and the payroll
-- attribution columns, so a database that recorded those migrations
-- without running them fails here.

do $$
declare
  v_fail text[] := '{}';
  r record;
  t text;
  v_exempt text[] := array[
    'platform_audit_events', 'impersonation_sessions', 'impersonation_logs',
    'tenant_notes', 'notifications', 'app_users', 'platform_digests', 'platform_job_runs'
  ];
begin
  ---------------------------------------------------------------------
  -- 1. Required functions exist
  ---------------------------------------------------------------------
  foreach t in array array[
    'public.prevent_journal_mutation()',
    'public.prevent_posted_invoice_update()',
    'public.void_journal_entry(uuid,text)',
    'public.is_business_dev_admin()',
    'public.prevent_law_contract_direct_approval()',
    'public.tenant_read_only_guard()',
    'public.apply_tenant_read_only_guard()',
    'public.decide_contract(uuid,text,text)',
    'public.submit_contract_for_approval(uuid)'
  ] loop
    if to_regprocedure(t) is null then
      v_fail := v_fail || format('missing function %s', t);
    end if;
  end loop;

  ---------------------------------------------------------------------
  -- 2. Required triggers exist and are enabled (tgenabled = 'O')
  ---------------------------------------------------------------------
  for r in
    select * from (values
      ('journal_entries',        'no_update_journal_entries'),
      ('journal_entry_lines',    'no_update_journal_entry_lines'),
      ('supplier_invoices',      'trg_prevent_posted_supplier_invoice_update'),
      ('receivable_invoices',    'trg_prevent_posted_receivable_invoice_update'),
      ('cash_bank_transactions', 'trg_prevent_posted_cash_bank_update'),
      ('fuel_logs',              'trg_prevent_posted_fuel_cost_update'),
      ('maintenance_requests',   'trg_prevent_posted_maintenance_cost_update'),
      ('law_contracts',          'trg_prevent_law_contract_direct_approval')
    ) as x(tbl, trg)
  loop
    if not exists (
      select 1 from pg_trigger
      where tgrelid = to_regclass('public.' || r.tbl) and tgname = r.trg
        and not tgisinternal and tgenabled = 'O'
    ) then
      v_fail := v_fail || format('trigger %s missing/disabled on %s', r.trg, r.tbl);
    end if;
  end loop;

  ---------------------------------------------------------------------
  -- 3. tenant_read_only_guard attached to EVERY tenant_id table
  --    (catches newly added tenant tables nobody re-ran the sweep for)
  ---------------------------------------------------------------------
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
    where n.nspname = 'public' and c.relkind = 'r' and c.relname <> all (v_exempt)
      and not exists (
        select 1 from pg_trigger g
        where g.tgrelid = c.oid and g.tgname = 'tenant_read_only_guard'
          and not g.tgisinternal and g.tgenabled = 'O')
  loop
    v_fail := v_fail || format('tenant_read_only_guard missing on %s (run select public.apply_tenant_read_only_guard())', r.relname);
  end loop;

  ---------------------------------------------------------------------
  -- 4. Module-gated SELECT: every SELECT policy on these tables must
  --    contain has_module_role (permissive policies OR together, so ONE
  --    leftover tenant-wide policy defeats the gate -- check all of them)
  ---------------------------------------------------------------------
  foreach t in array array[
    'law_cases','law_case_hearings','law_case_types','law_contracts','law_contract_types',
    'law_compliance_register','law_regulatory_filings',
    'pmo_projects','pmo_project_categories','pmo_tasks','pmo_task_types','pmo_milestones',
    'pmo_resource_allocations','pmo_task_dependencies',
    'machines','machine_types','machine_assignments','maintenance_requests','maintenance_types','fuel_logs',
    'sustainability_metrics','sustainability_metric_types','sustainability_initiatives',
    'sustainability_initiative_categories','sustainability_audits','sustainability_certifications',
    'hr_job_applications','hr_trainings'
  ] loop
    if not exists (select 1 from pg_policies where schemaname='public' and tablename=t and cmd in ('SELECT','ALL')) then
      v_fail := v_fail || format('%s has no SELECT policy', t);
    end if;
    for r in
      select policyname from pg_policies
      where schemaname='public' and tablename=t and cmd in ('SELECT','ALL')
        and coalesce(qual,'') !~* 'has_module_role'
    loop
      v_fail := v_fail || format('%s.%s is not module-gated (no has_module_role)', t, r.policyname);
    end loop;
  end loop;

  ---------------------------------------------------------------------
  -- 5. BD lookup tables: every write policy must use the admin tier
  ---------------------------------------------------------------------
  foreach t in array array[
    'bd_lead_sources','bd_client_categories','bd_lead_statuses','bd_opportunity_stages',
    'bd_proposal_types','bd_proposal_statuses','bd_tender_types'
  ] loop
    for r in
      select policyname from pg_policies
      where schemaname='public' and tablename=t and cmd in ('INSERT','UPDATE','DELETE','ALL')
        and coalesce(qual,'') || coalesce(with_check,'') !~* 'is_business_dev_admin'
    loop
      v_fail := v_fail || format('%s.%s write policy not admin-tier', t, r.policyname);
    end loop;
  end loop;

  ---------------------------------------------------------------------
  -- 6. IT Support lookup SELECT gated by is_it_support()
  ---------------------------------------------------------------------
  foreach t in array array['support_teams','ticket_categories','sla_policies','priority_levels','support_team_members'] loop
    for r in
      select policyname from pg_policies
      where schemaname='public' and tablename=t and cmd in ('SELECT','ALL')
        and coalesce(qual,'') !~* 'is_it_support'
    loop
      v_fail := v_fail || format('%s.%s not gated by is_it_support()', t, r.policyname);
    end loop;
  end loop;

  ---------------------------------------------------------------------
  -- 7. Missing verb: hr_attendance must have a DELETE policy
  ---------------------------------------------------------------------
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='hr_attendance' and cmd in ('DELETE','ALL')) then
    v_fail := v_fail || 'hr_attendance has no DELETE policy'::text;
  end if;

  ---------------------------------------------------------------------
  -- 8. Definer lockdown: none of the hardening helpers is anon-executable
  ---------------------------------------------------------------------
  for r in
    select p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('prevent_journal_mutation','prevent_posted_invoice_update','void_journal_entry',
                        'prevent_law_contract_direct_approval','apply_tenant_read_only_guard',
                        'decide_contract','submit_contract_for_approval','is_business_dev_admin')
      and has_function_privilege('anon', p.oid, 'execute')
  loop
    v_fail := v_fail || format('%s is executable by anon', r.sig);
  end loop;

  ---------------------------------------------------------------------
  -- 9. Guard function BODIES (existence alone is not enough)
  ---------------------------------------------------------------------
  -- 9a. Specific guards must contain their fixes.
  if to_regprocedure('public.prevent_law_contract_direct_approval()') is not null
     and pg_get_functiondef(to_regprocedure('public.prevent_law_contract_direct_approval()'))
           !~* 'coalesce\(\s*current_setting\(\s*''app\.allow_law_status_change''\s*,\s*true\s*\)' then
    v_fail := v_fail || 'prevent_law_contract_direct_approval() is not NULL-safe (no coalesce around current_setting)'::text;
  end if;

  if to_regprocedure('public.prevent_journal_mutation()') is not null
     and pg_get_functiondef(to_regprocedure('public.prevent_journal_mutation()'))
           !~* 'tg_table_name\s*=\s*''journal_entries''' then
    v_fail := v_fail || 'prevent_journal_mutation() does not branch on tg_table_name (fails on journal_entry_lines)'::text;
  end if;

  -- 9b. Generic scan: any public function that blocks on an app.* flag with
  --     an un-coalesced != / <> (or NOT (... = ...)) is skipped when the flag
  --     is unset, because current_setting(name, true) returns NULL then.
  for r in
    select p.oid::regprocedure::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind in ('f', 'p')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and (
        pg_get_functiondef(p.oid) ~* 'current_setting\(\s*''app\.[a-z_]+''\s*,\s*true\s*\)\s*(!=|<>)'
        or pg_get_functiondef(p.oid) ~* 'not\s*\(\s*current_setting\(\s*''app\.[a-z_]+''\s*,\s*true\s*\)'
      )
  loop
    v_fail := v_fail || format('%s compares an app.* setting to a value without coalesce (NULL bypass when the flag is unset)', r.sig);
  end loop;

  ---------------------------------------------------------------------
  -- 10. Authorization hardening from security_authorization.sql
  --     (payroll separation of duties, PO handoff, staff_roles policies,
  --     module enablement, payroll impersonation attribution)
  ---------------------------------------------------------------------
  -- 10a. Functions must exist and contain their fixes.
  foreach t in array array[
    'public.approve_payroll_run(uuid)',
    'public.reject_payroll_run(uuid,text)',
    'public.revise_payroll_run(uuid)',
    'public.can_manage_po_handoff(uuid)',
    'public.set_staff_module_role(uuid,text,text)'
  ] loop
    if to_regprocedure(t) is null then
      v_fail := v_fail || format('missing function %s', t);
    end if;
  end loop;

  if to_regprocedure('public.approve_payroll_run(uuid)') is not null then
    if pg_get_functiondef(to_regprocedure('public.approve_payroll_run(uuid)'))
         !~* 'prepared_by\s*=\s*(v_effective|effective_user_id\(\))' then
      v_fail := v_fail || 'approve_payroll_run() does not block the preparer (separation of duties)'::text;
    end if;
    if pg_get_functiondef(to_regprocedure('public.approve_payroll_run(uuid)'))
         !~* 'prepared_by\s*=\s*auth\.uid\(\)' then
      v_fail := v_fail || 'approve_payroll_run() does not also block the real actor (impersonated separation of duties)'::text;
    end if;
    if pg_get_functiondef(to_regprocedure('public.approve_payroll_run(uuid)'))
         !~* 'effective_user_id\s*=\s*v_effective' then
      v_fail := v_fail || 'approve_payroll_run() does not record effective_user_id'::text;
    end if;
    if pg_get_functiondef(to_regprocedure('public.approve_payroll_run(uuid)'))
         !~* 'impersonation_session_id\s*=\s*v_session' then
      v_fail := v_fail || 'approve_payroll_run() does not record impersonation_session_id'::text;
    end if;
  end if;

  if to_regprocedure('public.reject_payroll_run(uuid,text)') is not null
     and (pg_get_functiondef(to_regprocedure('public.reject_payroll_run(uuid,text)')) !~* 'effective_user_id\s*=\s*v_effective'
          or pg_get_functiondef(to_regprocedure('public.reject_payroll_run(uuid,text)')) !~* 'impersonation_session_id\s*=\s*v_session') then
    v_fail := v_fail || 'reject_payroll_run() does not record effective_user_id/impersonation_session_id'::text;
  end if;

  if to_regprocedure('public.revise_payroll_run(uuid)') is not null
     and pg_get_functiondef(to_regprocedure('public.revise_payroll_run(uuid)'))
           !~* 'effective_user_id\s*=\s*null' then
    v_fail := v_fail || 'revise_payroll_run() does not clear the decision attribution columns'::text;
  end if;

  if to_regprocedure('public.can_manage_po_handoff(uuid)') is not null then
    if pg_get_functiondef(to_regprocedure('public.can_manage_po_handoff(uuid)')) ~* 'approval_actions' then
      v_fail := v_fail || 'can_manage_po_handoff() still grants handoff to approval-chain members (approval_actions)'::text;
    end if;
    if pg_get_functiondef(to_regprocedure('public.can_manage_po_handoff(uuid)')) !~* 'has_po_access\(\)'
       or pg_get_functiondef(to_regprocedure('public.can_manage_po_handoff(uuid)')) !~* 'effective_user_id\(\)' then
      v_fail := v_fail || 'can_manage_po_handoff() must allow only the offer submitter (effective user) and has_po_access()'::text;
    end if;
  end if;

  if to_regprocedure('public.set_staff_module_role(uuid,text,text)') is not null
     and pg_get_functiondef(to_regprocedure('public.set_staff_module_role(uuid,text,text)'))
           !~* 'tenant_modules' then
    v_fail := v_fail || 'set_staff_module_role() does not check the module is enabled for the tenant'::text;
  end if;

  -- 10b. staff_roles write policies: all three verbs present, gated by
  --      platform_admin_bypass(), none on the raw is_platform_admin flag.
  foreach t in array array['INSERT', 'UPDATE', 'DELETE'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'staff_roles' and cmd = t) then
      v_fail := v_fail || format('staff_roles has no %s policy', t);
    end if;
  end loop;
  for r in
    select policyname, cmd from pg_policies
    where schemaname = 'public' and tablename = 'staff_roles' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      and (coalesce(qual, '') || coalesce(with_check, '') !~* 'platform_admin_bypass'
           or coalesce(qual, '') || coalesce(with_check, '') ~* 'is_platform_admin')
  loop
    v_fail := v_fail || format('staff_roles.%s (%s) is not gated by platform_admin_bypass() alone', r.policyname, r.cmd);
  end loop;

  -- 10c. hr_payroll_runs attribution columns.
  foreach t in array array['effective_user_id', 'impersonation_session_id'] loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'hr_payroll_runs' and column_name = t
    ) then
      v_fail := v_fail || format('hr_payroll_runs.%s column is missing', t);
    end if;
  end loop;

  -- 10d. None of the payroll / role RPCs is anon-executable.
  for r in
    select p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('approve_payroll_run', 'reject_payroll_run', 'revise_payroll_run', 'set_staff_module_role')
      and has_function_privilege('anon', p.oid, 'execute')
  loop
    v_fail := v_fail || format('%s is executable by anon', r.sig);
  end loop;

  -- 11. departments / organizations belong to the company admin
  --     (20261001120000): every write policy must be keyed to
  --     is_tenant_admin() and must not still admit the finance team or any
  --     module admin; organizations_select must also admit the company admin.
  foreach t in array array['departments', 'organizations'] loop
    for r in select c as cmd from unnest(array['INSERT', 'UPDATE', 'DELETE']) as c loop
      if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and cmd = r.cmd) then
        v_fail := v_fail || format('%s has no %s policy', t, r.cmd);
      end if;
    end loop;
    for r in
      select policyname, cmd from pg_policies
      where schemaname = 'public' and tablename = t and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        and (coalesce(qual, '') || coalesce(with_check, '') !~* 'is_tenant_admin'
             or coalesce(qual, '') || coalesce(with_check, '') ~* 'is_finance_team_member'
             or coalesce(qual, '') || coalesce(with_check, '') ~* 'is_any_module_admin')
    loop
      v_fail := v_fail || format('%s.%s (%s) is not keyed to is_tenant_admin() alone', t, r.policyname, r.cmd);
    end loop;
  end loop;
  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organizations' and cmd = 'SELECT'
      and coalesce(qual, '') !~* 'is_tenant_admin'
  ) then
    v_fail := v_fail || 'organizations SELECT policy does not admit the company admin (is_tenant_admin())'::text;
  end if;

  ---------------------------------------------------------------------
  -- 12. Document-numbering tenant isolation (20261001150000)
  ---------------------------------------------------------------------
  if to_regprocedure('public.assert_tenant_access(uuid)') is null then
    v_fail := v_fail || 'missing function public.assert_tenant_access(uuid)'::text;
  else
    foreach t in array array['anon', 'authenticated', 'public'] loop
      if has_function_privilege(t, 'public.assert_tenant_access(uuid)', 'EXECUTE') then
        v_fail := v_fail || format('role %s can EXECUTE assert_tenant_access', t);
      end if;
    end loop;
  end if;
  foreach t in array array[
    'public.next_doc_number(uuid,text,text,integer)',
    'public.next_asset_tag(uuid)',
    'public.next_mr_number(uuid)',
    'public.next_ticket_number(uuid)',
    'public.next_problem_number(uuid)',
    'public.next_material_catalog_code(uuid)'
  ] loop
    if to_regprocedure(t) is null then
      v_fail := v_fail || format('missing function %s', t);
    else
      if (select prosrc !~* 'assert_tenant_access' from pg_proc where oid = to_regprocedure(t)) then
        v_fail := v_fail || format('%s does not call assert_tenant_access', t);
      end if;
      -- numbering triggers are SECURITY INVOKER: authenticated must keep EXECUTE
      if not has_function_privilege('authenticated', to_regprocedure(t), 'EXECUTE') then
        v_fail := v_fail || format('authenticated lost EXECUTE on %s', t);
      end if;
      if has_function_privilege('anon', to_regprocedure(t), 'EXECUTE') then
        v_fail := v_fail || format('anon can EXECUTE %s', t);
      end if;
    end if;
  end loop;

  if array_length(v_fail, 1) is not null then
    raise exception E'SECURITY DRIFT DETECTED (% problem(s)):\n - %',
      array_length(v_fail, 1), array_to_string(v_fail, E'\n - ');
  end if;
  raise notice 'PASS: live security catalog matches expectations';
end $$;