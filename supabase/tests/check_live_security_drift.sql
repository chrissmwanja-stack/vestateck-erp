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
    v_fail := v_fail || 'hr_attendance has no DELETE policy';
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

  if array_length(v_fail, 1) is not null then
    raise exception E'SECURITY DRIFT DETECTED (% problem(s)):\n - %',
      array_length(v_fail, 1), array_to_string(v_fail, E'\n - ');
  end if;
  raise notice 'PASS: live security catalog matches expectations';
end $$;