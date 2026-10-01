-- Behavioural regression test for 20260929064635_reapply_skipped_rls_hardening.sql
-- (the reapply of the hardening migrations that were recorded but never ran
-- in production). Exercises the REAL tables -- unlike test_journal_immutability
-- and test_tenant_read_only_guard, which assert against temp tables.
--
-- Covers what no other test does:
--   1. BD lookup-table writes are admin/manager-only (member: insert denied,
--      update/delete affect 0 rows; manager: all three work).
--   2. IT Support lookup SELECT is gated by is_it_support().
--   3. law_contracts status cannot be moved through the approval states by a
--      direct table UPDATE (LAW_STATUS_GUARD); the RPCs still work; lifecycle
--      transitions (active -> expired) stay allowed via direct UPDATE.
--   4. Posted supplier-invoice amounts are locked (POSTED_INVOICE_IMMUTABLE).
--   5. journal_entries / journal_entry_lines reject UPDATE and DELETE for the
--      table owner too (JOURNAL_IMMUTABLE).
--   6. void_journal_entry(): finance-only, marks the original void, posts a
--      balanced swapped-sign reversal, is idempotent, and the void flag does
--      not leak (a second raw UPDATE is blocked again).
--   7. tenant_read_only_guard is attached to `invitations` and fires for an
--      ordinary user when the tenant is read_only.
--
-- For catalog-level drift against a live database use
-- check_live_security_drift.sql instead (this file writes data).
--
-- Run against a fresh local stack only (`supabase start`, then `psql -f`) --
-- never a linked/remote project. Everything rolls back. Fails loudly via
-- RAISE EXCEPTION.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures (as owner)
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant      uuid := gen_random_uuid();
  v_bd_member   uuid := gen_random_uuid();
  v_bd_manager  uuid := gen_random_uuid();
  v_it_user     uuid := gen_random_uuid();
  v_plain       uuid := gen_random_uuid();
  v_creator     uuid := gen_random_uuid();
  v_approver    uuid := gen_random_uuid();
  v_finance     uuid := gen_random_uuid();
  v_org_id      uuid;
  v_cc_id       uuid;
  v_exp_acct    uuid;
  v_ap_acct     uuid;
  v_vat_acct    uuid;
begin
  insert into tenants (id, name) values (v_tenant, 'Reapplied Hardening Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values
    (v_bd_member,  'rh-bd-member'),
    (v_bd_manager, 'rh-bd-manager'),
    (v_it_user,    'rh-it-user'),
    (v_plain,      'rh-plain'),
    (v_creator,    'rh-legal-creator'),
    (v_approver,   'rh-legal-approver'),
    (v_finance,    'rh-finance')
  ) as u(id, handle);

  insert into app_users (id, tenant_id, name, email)
  select u.id, v_tenant, u.name, u.email
  from (values
    (v_bd_member,  'BD Member',      'rh-bd-member@test.local'),
    (v_bd_manager, 'BD Manager',     'rh-bd-manager@test.local'),
    (v_it_user,    'IT User',        'rh-it-user@test.local'),
    (v_plain,      'Plain User',     'rh-plain@test.local'),
    (v_creator,    'Legal Creator',  'rh-legal-creator@test.local'),
    (v_approver,   'Legal Approver', 'rh-legal-approver@test.local'),
    (v_finance,    'Finance User',   'rh-finance@test.local')
  ) as u(id, name, email);

  insert into tenant_modules (tenant_id, module)
  select v_tenant, m from (values ('bd'), ('it'), ('legal')) as t(m);

  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_bd_member,  'bd',    'member'),
    (v_tenant, v_bd_manager, 'bd',    'manager'),
    (v_tenant, v_it_user,    'it',    'member'),
    (v_tenant, v_creator,    'legal', 'manager'),
    (v_tenant, v_approver,   'legal', 'manager');

  insert into finance_team_members (tenant_id, user_id, role)
  values (v_tenant, v_finance, 'finance');

  -- Seed rows for the read/write probes
  insert into bd_lead_sources (tenant_id, name) values (v_tenant, 'Seed source');
  insert into support_teams   (tenant_id, name) values (v_tenant, 'Seed team');
  insert into ticket_categories (tenant_id, code, name) values (v_tenant, 'seed', 'Seed category');
  insert into sla_policies    (tenant_id, priority, target_hours) values (v_tenant, 'high', 8);
  insert into priority_levels (tenant_id, code, label) values (v_tenant, 'high', 'High');

  insert into law_contracts (tenant_id, contract_no, title, party_name, status, created_by) values
    (v_tenant, 'RH-DRAFT',   'Draft contract',   'Party A', 'draft',            v_creator),
    (v_tenant, 'RH-PENDING', 'Pending contract', 'Party B', 'pending_approval', v_creator),
    (v_tenant, 'RH-ACTIVE',  'Active contract',  'Party C', 'active',           v_creator);

  -- Finance fixtures (same shape as test_gl_posting_and_period_close.sql):
  -- organizations' defaults trigger needs auth.uid() resolvable, so
  -- impersonate the finance user for those inserts.
  -- Organizations are company-admin owned (20261001120000), so a plain finance-team user can no
  -- longer create one. Give the fixture user the company-admin flag for this single insert only,
  -- then drop it so the rest of the test still runs as a plain finance-team member.
  update app_users set is_company_admin = true where id = v_finance;
  perform set_config('request.jwt.claims', json_build_object('sub', v_finance)::text, true);
  set local role authenticated;

  insert into organizations (tenant_id, company_code, site_name)
  values (v_tenant, 'RHT', 'Hardening Test Site') returning id into v_org_id;
  reset role;
  update app_users set is_company_admin = false where id = v_finance;
  set local role authenticated;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant, '5000', 'Test Expense', 'expense') returning id into v_exp_acct;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant, '2000', 'Test AP Control', 'liability') returning id into v_ap_acct;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_tenant, '1500', 'Test VAT Input', 'asset') returning id into v_vat_acct;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_tenant, 'default_expense', v_exp_acct),
    (v_tenant, 'ap_control',      v_ap_acct),
    (v_tenant, 'vat_input',       v_vat_acct);

  reset role;
  insert into cost_centers (tenant_id, name) values (v_tenant, 'RH Cost Center') returning id into v_cc_id;
  set local role authenticated;

  insert into supplier_invoices (
    tenant_id, organization_id, invoice_number, invoice_date,
    amount_incl_vat, vat_amount, wht_amount, cost_center_id
  ) values (
    v_tenant, v_org_id, 'RH-INV-001', current_date, 118000, 18000, 0, v_cc_id
  );

  reset role;

  -- Plain lookup table so personas can be resolved by handle without
  -- depending on app_users RLS (same pattern as the sibling tests).
  create temp table if not exists test_identities(handle text primary key, id uuid not null) on commit drop;
  insert into test_identities (handle, id) values
    ('rh-bd-member', v_bd_member), ('rh-bd-manager', v_bd_manager), ('rh-it-user', v_it_user),
    ('rh-plain', v_plain), ('rh-legal-creator', v_creator), ('rh-legal-approver', v_approver),
    ('rh-finance', v_finance);
  grant select on test_identities to authenticated;
end $$;

-- ---------------------------------------------------------------------
-- 1. BD lookup tables: admin tier writes only
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-bd-member'), 'role', 'authenticated')::text, true);

do $$
declare v_n int;
begin
  if (select count(*) from bd_lead_sources) <> 1 then
    raise exception 'FAIL: bd/member cannot READ bd_lead_sources (SELECT must stay on flat is_business_dev)';
  end if;

  begin
    insert into bd_lead_sources (tenant_id, name)
    values ((select tenant_id from app_users where id = auth.uid()), 'Member insert');
    raise exception 'FAIL: bd/member INSERT into bd_lead_sources succeeded';
  exception when insufficient_privilege then
    null; -- expected: RLS with-check violation
  end;

  update bd_lead_sources set name = 'hijacked';
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL: bd/member UPDATE affected % row(s)', v_n; end if;

  delete from bd_lead_sources;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL: bd/member DELETE affected % row(s)', v_n; end if;

  raise notice 'PASS: bd/member reads but cannot write BD lookup tables';
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-bd-manager'), 'role', 'authenticated')::text, true);

do $$
declare v_n int;
begin
  insert into bd_lead_sources (tenant_id, name)
  values ((select tenant_id from app_users where id = auth.uid()), 'Manager insert');

  update bd_lead_sources set name = 'Renamed by manager' where name = 'Manager insert';
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'FAIL: bd/manager UPDATE affected % row(s), expected 1', v_n; end if;

  delete from bd_lead_sources where name = 'Renamed by manager';
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'FAIL: bd/manager DELETE affected % row(s), expected 1', v_n; end if;

  raise notice 'PASS: bd/manager can insert, update and delete BD lookup rows';
end $$;

-- ---------------------------------------------------------------------
-- 2. IT Support lookups: gated by is_it_support()
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-plain'), 'role', 'authenticated')::text, true);

do $$
begin
  if (select count(*) from support_teams) > 0
     or (select count(*) from ticket_categories) > 0
     or (select count(*) from sla_policies) > 0
     or (select count(*) from priority_levels) > 0 then
    raise exception 'FAIL: same-tenant user with no IT role can read IT Support lookup tables';
  end if;
  raise notice 'PASS: plain user reads 0 IT Support lookup rows';
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-it-user'), 'role', 'authenticated')::text, true);

do $$
begin
  if (select count(*) from support_teams) <> 1
     or (select count(*) from ticket_categories) <> 1
     or (select count(*) from sla_policies) <> 1
     or (select count(*) from priority_levels) <> 1 then
    raise exception 'FAIL: it/member cannot read IT Support lookup tables (expected 1 row each)';
  end if;
  raise notice 'PASS: it/member reads IT Support lookup tables';
end $$;

-- ---------------------------------------------------------------------
-- 3. law_contracts: direct-UPDATE approval bypass is blocked
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-legal-creator'), 'role', 'authenticated')::text, true);

do $$
declare v_n int;
begin
  -- draft -> pending_approval directly (must use submit_contract_for_approval)
  begin
    update law_contracts set status = 'pending_approval' where title = 'Draft contract';
    get diagnostics v_n = row_count;
    if v_n = 0 then
      raise exception 'FAIL: could not exercise the guard -- UPDATE matched 0 rows (RLS hid the row?)';
    end if;
    raise exception 'FAIL: direct draft->pending_approval UPDATE succeeded';
  exception when restrict_violation then
    if sqlerrm not like 'LAW_STATUS_GUARD:%' then
      raise exception 'FAIL: wrong error on direct submit: %', sqlerrm;
    end if;
  end;

  -- the RPC path still works
  perform submit_contract_for_approval((select id from law_contracts where title = 'Draft contract'));
  if (select status from law_contracts where title = 'Draft contract') <> 'pending_approval' then
    raise exception 'FAIL: submit_contract_for_approval did not move the contract to pending_approval';
  end if;

  -- lifecycle transition stays allowed by direct UPDATE
  update law_contracts set status = 'expired' where title = 'Active contract';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL: direct active->expired lifecycle UPDATE was blocked or matched % rows', v_n;
  end if;

  raise notice 'PASS: direct submit blocked, RPC submit works, lifecycle UPDATE allowed';
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-legal-approver'), 'role', 'authenticated')::text, true);

do $$
declare v_n int;
begin
  -- pending_approval -> active directly (the self-approval bypass this closes)
  begin
    update law_contracts set status = 'active' where title = 'Pending contract';
    get diagnostics v_n = row_count;
    if v_n = 0 then
      raise exception 'FAIL: could not exercise the guard -- UPDATE matched 0 rows (RLS hid the row?)';
    end if;
    raise exception 'FAIL: direct pending_approval->active UPDATE succeeded';
  exception when restrict_violation then
    if sqlerrm not like 'LAW_STATUS_GUARD:%' then
      raise exception 'FAIL: wrong error on direct approve: %', sqlerrm;
    end if;
  end;

  -- decide_contract still works for a different legal manager than the creator
  perform decide_contract((select id from law_contracts where title = 'Pending contract'), 'approved', null);
  if (select status from law_contracts where title = 'Pending contract') <> 'active' then
    raise exception 'FAIL: decide_contract did not activate the contract';
  end if;

  raise notice 'PASS: direct approve blocked, decide_contract works';
end $$;

-- ---------------------------------------------------------------------
-- 4-6. Finance: posted-amount lock, journal immutability, void RPC
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-finance'), 'role', 'authenticated')::text, true);

do $$
declare v_n int;
begin
  if not exists (select 1 from journal_entries where source_type = 'supplier_invoice') then
    raise exception 'FAIL: fixture invoice did not auto-post a journal entry';
  end if;

  begin
    update supplier_invoices set amount_incl_vat = 1 where amount_incl_vat = 118000;
    get diagnostics v_n = row_count;
    if v_n = 0 then
      raise exception 'FAIL: could not exercise the guard -- UPDATE matched 0 rows (RLS hid the row?)';
    end if;
    raise exception 'FAIL: amount change on a posted supplier invoice succeeded';
  exception when restrict_violation then
    if sqlerrm not like 'POSTED_INVOICE_IMMUTABLE:%' then
      raise exception 'FAIL: wrong error on posted-amount change: %', sqlerrm;
    end if;
  end;

  -- non-amount edits are still fine
  update supplier_invoices set invoice_date = invoice_date where amount_incl_vat = 118000;

  raise notice 'PASS: posted supplier-invoice amount is locked';
end $$;

-- Journal rows reject UPDATE/DELETE even for the table owner
reset role;

do $$
declare v_entry uuid;
begin
  select id into v_entry from journal_entries where source_type = 'supplier_invoice' limit 1;

  begin
    update journal_entries set description = 'tampered' where id = v_entry;
    raise exception 'FAIL: owner UPDATE on journal_entries succeeded';
  exception when restrict_violation then
    if sqlerrm not like 'JOURNAL_IMMUTABLE:%' then raise exception 'FAIL: wrong error: %', sqlerrm; end if;
  end;

  begin
    delete from journal_entries where id = v_entry;
    raise exception 'FAIL: owner DELETE on journal_entries succeeded';
  exception when restrict_violation then
    if sqlerrm not like 'JOURNAL_IMMUTABLE:%' then raise exception 'FAIL: wrong error: %', sqlerrm; end if;
  end;

  begin
    update journal_entry_lines set description = 'tampered' where journal_entry_id = v_entry;
    raise exception 'FAIL: owner UPDATE on journal_entry_lines succeeded';
  exception when restrict_violation then
    if sqlerrm not like 'JOURNAL_IMMUTABLE:%' then raise exception 'FAIL: wrong error: %', sqlerrm; end if;
  end;

  raise notice 'PASS: journal_entries / journal_entry_lines are immutable for the owner';
end $$;

-- void_journal_entry: non-finance user is refused
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-plain'), 'role', 'authenticated')::text, true);

do $$
declare v_entry uuid;
begin
  reset role;
  select id into v_entry from journal_entries where source_type = 'supplier_invoice' limit 1;
  set local role authenticated;
  begin
    perform void_journal_entry(v_entry, 'attempted by a non-finance user');
    raise exception 'FAIL: non-finance user voided a journal entry';
  exception when others then
    if sqlerrm not like '%not authorized%' then
      raise exception 'FAIL: wrong error for non-finance void: %', sqlerrm;
    end if;
  end;
  raise notice 'PASS: non-finance user cannot void';
end $$;

-- void_journal_entry: finance user succeeds, reversal is balanced and swapped
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-finance'), 'role', 'authenticated')::text, true);

do $$
declare
  v_entry     uuid;
  v_reversal  journal_entries;
  v_orig_lines int;
  v_rev_lines  int;
  v_rev_debit  numeric;
  v_rev_credit numeric;
  v_orig_debit numeric;
  v_orig_credit numeric;
  v_count_before int;
begin
  select id into v_entry from journal_entries where source_type = 'supplier_invoice' limit 1;
  select count(*), coalesce(sum(debit),0), coalesce(sum(credit),0)
    into v_orig_lines, v_orig_debit, v_orig_credit
    from journal_entry_lines where journal_entry_id = v_entry;
  select count(*) into v_count_before from journal_entries;

  begin
    perform void_journal_entry(v_entry, 'no');
    raise exception 'FAIL: void accepted a too-short reason';
  exception when others then
    if sqlerrm not like '%reason%' then raise exception 'FAIL: wrong error for short reason: %', sqlerrm; end if;
  end;

  v_reversal := void_journal_entry(v_entry, 'Test reversal of posted invoice');

  if (select status from journal_entries where id = v_entry) <> 'void' then
    raise exception 'FAIL: original entry not marked void';
  end if;
  if v_reversal.id is null or v_reversal.id = v_entry then
    raise exception 'FAIL: void_journal_entry did not return a new reversal entry';
  end if;

  select count(*), coalesce(sum(debit),0), coalesce(sum(credit),0)
    into v_rev_lines, v_rev_debit, v_rev_credit
    from journal_entry_lines where journal_entry_id = v_reversal.id;

  if v_rev_lines <> v_orig_lines then
    raise exception 'FAIL: reversal has % lines, original has %', v_rev_lines, v_orig_lines;
  end if;
  if v_rev_debit <> v_orig_credit or v_rev_credit <> v_orig_debit then
    raise exception 'FAIL: reversal did not swap debit/credit (rev D/C % / %, orig D/C % / %)',
      v_rev_debit, v_rev_credit, v_orig_debit, v_orig_credit;
  end if;
  if v_rev_debit <> v_rev_credit then
    raise exception 'FAIL: reversal is unbalanced (% vs %)', v_rev_debit, v_rev_credit;
  end if;

  -- idempotent: voiding an already-void entry posts nothing new
  perform void_journal_entry(v_entry, 'Second void attempt is a no-op');
  if (select count(*) from journal_entries) <> v_count_before + 1 then
    raise exception 'FAIL: second void posted another reversal';
  end if;

  raise notice 'PASS: void_journal_entry posts a balanced swapped reversal and is idempotent';
end $$;

-- The void bypass flag must not leak: a raw status UPDATE is blocked again
reset role;

do $$
declare v_entry uuid;
begin
  select id into v_entry from journal_entries where status = 'void' limit 1;
  begin
    update journal_entries set status = 'posted' where id = v_entry;
    raise exception 'FAIL: raw UPDATE succeeded after void (app.allow_journal_void leaked)';
  exception when restrict_violation then
    null;
  end;
  raise notice 'PASS: void bypass flag does not leak';
end $$;

-- ---------------------------------------------------------------------
-- 7. Read-only guard fires on invitations (newly guarded table)
-- ---------------------------------------------------------------------
update tenants set read_only = true, read_only_reason = 'test', read_only_since = now()
where id = (select tenant_id from app_users where id = (select id from test_identities where handle = 'rh-plain'));

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'rh-plain'), 'role', 'authenticated')::text, true);

do $$
begin
  begin
    insert into invitations (tenant_id, email, invited_by)
    values ((select tenant_id from app_users where id = auth.uid()), 'blocked@example.com', auth.uid());
    raise exception 'FAIL: invitation insert succeeded for a read_only tenant';
  exception when insufficient_privilege then
    -- BEFORE ROW triggers run ahead of the RLS with-check, so this message
    -- can only come from the guard, not from a missing INSERT policy.
    if sqlerrm not like 'TENANT_READ_ONLY:%' then
      raise exception 'FAIL: invitations blocked, but not by the read-only guard: %', sqlerrm;
    end if;
  end;
  raise notice 'PASS: read-only guard blocks ordinary invitation inserts';
end $$;

reset role;

do $$ begin raise notice 'PASS: reapplied hardening behavioural tests'; end $$;

rollback;