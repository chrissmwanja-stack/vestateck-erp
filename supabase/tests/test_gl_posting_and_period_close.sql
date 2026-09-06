-- Workstream A + B functional test: GL auto-posting from a supplier
-- invoice, the debit=credit deferred-constraint invariant, and the
-- accounting-period lock.
--
-- Run against a fresh local stack only (`supabase start` in the
-- db-shadow-replay CI job, or `supabase db reset` locally). Everything
-- here is wrapped in one transaction that ROLLBACKs at the end, so it
-- leaves no fixture data behind -- BUT note that assign_supplier_invoice_oif()
-- and similar doc-numbering triggers may use a real sequence object
-- internally; if so, sequence values consumed here will not roll back.
-- That's a cosmetic gap-in-numbering, not a correctness issue, and is
-- fine on a throwaway local/CI database -- do NOT run this file against
-- a linked/remote project (see supabase/seed.sql's own warning; the
-- same rule applies here).
--
-- Fails loudly: any RAISE EXCEPTION here is a real assertion failure
-- and should fail the CI step (psql -f exits non-zero on an
-- uncaught error, matching the pattern scripts/audit_tenant_fk.sql
-- already uses in .github/workflows/foundation-checks.yml).

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tenant_id uuid := gen_random_uuid();
  v_user_id uuid := gen_random_uuid();
  v_org_id uuid := gen_random_uuid();
  v_cost_center_id uuid;
  v_expense_account uuid;
  v_ap_account uuid;
  v_invoice_id uuid;
  v_entry_id uuid;
  v_line_sum numeric;
  v_line_count int;
  v_period_id uuid;
  v_caught boolean;
begin
  -------------------------------------------------------------------
  -- Fixtures: one tenant, one auth user (finance role), one org,
  -- two GL accounts, and the posting-rule mapping supplier-invoice
  -- posting depends on (ap_control + default_expense).
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_tenant_id, 'GL Posting Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_user_id, 'authenticated', 'authenticated',
    'gl-test-' || v_user_id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );

  insert into app_users (id, tenant_id, name, email)
  values (v_user_id, v_tenant_id, 'GL Test Finance User', 'gl-test-' || v_user_id || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role)
  values (v_tenant_id, v_user_id, 'finance');

  -- Impersonate the finance user from here on, since get_my_tenant_id()/
  -- is_finance_team_member() both read auth.uid() from session-local JWT
  -- claims, not a parameter -- and organizations' set_organization_defaults()
  -- trigger unconditionally overwrites tenant_id via get_my_tenant_id(),
  -- raising if it can't resolve one. So this must happen before the
  -- organizations insert below, not after it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_id)::text, true);
  set local role authenticated;

  insert into organizations (tenant_id, company_code, site_name)
  values (v_tenant_id, 'GLT', 'GL Test Site')
  returning id into v_org_id;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant_id, '5000', 'Test Expense', 'expense')
  returning id into v_expense_account;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant_id, '2000', 'Test AP Control', 'liability')
  returning id into v_ap_account;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
  values
    (v_tenant_id, 'default_expense', v_expense_account),
    (v_tenant_id, 'ap_control', v_ap_account);

  -- cost_centers' INSERT policy requires has_po_access() (a procurement
  -- approval-chain check), which a plain finance-team member legitimately
  -- doesn't have -- so this one fixture row is inserted with RLS bypassed
  -- via reset role. Its own set_cost_center_defaults() trigger still needs
  -- auth.uid() resolvable, which the JWT claims set above already provide
  -- regardless of role.
  reset role;
  insert into cost_centers (tenant_id, name)
  values (v_tenant_id, 'GL Test Cost Center')
  returning id into v_cost_center_id;
  set local role authenticated;

  -------------------------------------------------------------------
  -- 1. A supplier invoice should auto-post a BALANCED journal entry.
  -------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, organization_id, invoice_number, invoice_date,
    amount_incl_vat, vat_amount, wht_amount, cost_center_id
  ) values (
    v_tenant_id, v_org_id, 'INV-TEST-001', current_date,
    118000, 18000, 0, v_cost_center_id
  )
  returning id into v_invoice_id;

  select je.id into v_entry_id
  from journal_entries je
  where je.tenant_id = v_tenant_id and je.source_type = 'supplier_invoice' and je.source_id = v_invoice_id;

  if v_entry_id is null then
    raise exception 'FAIL: supplier invoice insert did not create a journal_entries row';
  end if;

  select count(*), coalesce(sum(debit), 0) - coalesce(sum(credit), 0)
    into v_line_count, v_line_sum
    from journal_entry_lines
    where journal_entry_id = v_entry_id;

  if v_line_count = 0 then
    raise exception 'FAIL: journal entry % has no lines', v_entry_id;
  end if;

  if v_line_sum != 0 then
    raise exception 'FAIL: journal entry % is not balanced (debit-credit = %)', v_entry_id, v_line_sum;
  end if;

  raise notice 'PASS: supplier invoice posted a balanced journal entry (% lines)', v_line_count;

  -------------------------------------------------------------------
  -- 2. The debit=credit deferred constraint trigger must reject a
  --    manual unbalanced entry at COMMIT (not per-row).
  -------------------------------------------------------------------
  v_caught := false;
  begin
    perform post_journal_entry(
      v_tenant_id, 'manual', gen_random_uuid(), current_date, 'Deliberately unbalanced test entry',
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_expense_account, 'debit', 1000),
        jsonb_build_object('gl_account_id', v_ap_account, 'credit', 999)
      )
    );
    -- The imbalance trigger is deferred to end-of-transaction, so it
    -- won't fire on the statement above by itself -- force it now.
    set constraints trg_check_journal_entry_balanced immediate;
  exception when others then
    v_caught := true;
  end;

  if not v_caught then
    raise exception 'FAIL: an unbalanced manual journal entry was NOT rejected';
  end if;
  raise notice 'PASS: unbalanced journal entry correctly rejected';

  -- The exception block above leaves the deferred-trigger setting
  -- changed for the rest of the transaction; reset it before
  -- continuing so entry 3 below still gets checked at commit-time
  -- like production traffic would.
  set constraints trg_check_journal_entry_balanced deferred;

  -------------------------------------------------------------------
  -- 3. A closed accounting period must reject a new posting dated
  --    inside it -- proving Workstream B's guard actually blocks
  --    writes, not just that the admin screen exists.
  -------------------------------------------------------------------
  insert into accounting_periods (tenant_id, period_start, period_end, status)
  values (v_tenant_id, date_trunc('month', current_date)::date, (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 'closed')
  returning id into v_period_id;

  v_caught := false;
  begin
    perform post_journal_entry(
      v_tenant_id, 'manual', gen_random_uuid(), current_date, 'Should be blocked by closed period',
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_expense_account, 'debit', 500),
        jsonb_build_object('gl_account_id', v_ap_account, 'credit', 500)
      )
    );
  exception when others then
    v_caught := true;
  end;

  if not v_caught then
    raise exception 'FAIL: posting into a CLOSED accounting period was NOT rejected';
  end if;
  raise notice 'PASS: closed-period posting correctly rejected';

  raise notice 'ALL GL POSTING + PERIOD CLOSE TESTS PASSED';
end $$;

rollback;
