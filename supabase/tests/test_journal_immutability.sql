-- Journal immutability, asserted against the REAL tables.
--
-- The previous version of this file attached prevent_journal_mutation() to a
-- temp table that had a `status` column, so it could never see that the
-- function failed on journal_entry_lines (which has none), and it only checked
-- that triggers existed on the real tables. This version:
--   1. checks the trigger SHAPE on both real tables (row-level, BEFORE,
--      UPDATE + DELETE only -- the function ends in `return null`, which would
--      silently cancel an INSERT if it were ever attached to one),
--   2. proves UPDATE/DELETE are blocked with JOURNAL_IMMUTABLE on
--      journal_entries and journal_entry_lines while the void flag is
--      unset / '' / 'false' / junk,
--   3. proves the void flag opens exactly one door: posted -> void on
--      journal_entries. Lines never get a bypass, void -> posted is blocked,
--      and non-status edits on entries are blocked even with the flag on.
--
-- Not repeated here (see test_reapplied_hardening.sql): the void_journal_entry()
-- RPC, its idempotency, the flag-leak check and the posted-invoice amount lock.
-- Catalog-level checks live in check_live_security_drift.sql.
--
-- Everything rolls back. Runs against a fresh/local database only.

\set ON_ERROR_STOP on

begin;

-- Runs a statement that must be blocked by prevent_journal_mutation().
create function pg_temp.expect_journal_immutable(p_sql text, p_label text)
returns void language plpgsql as $$
declare v_n int;
begin
  begin
    execute p_sql;
    get diagnostics v_n = row_count;
    if v_n = 0 then
      raise exception 'FAIL: % -- could not exercise the guard, statement matched 0 rows', p_label;
    end if;
    raise exception 'FAIL: % succeeded but must be blocked', p_label;
  exception when restrict_violation then
    if sqlerrm not like 'JOURNAL_IMMUTABLE:%' then
      raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------
-- Fixture: one posted journal entry, created the real way (a supplier
-- invoice auto-posts). Same shape as test_reapplied_hardening.sql.
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant   uuid := gen_random_uuid();
  v_finance  uuid := gen_random_uuid();
  v_org_id   uuid;
  v_cc_id    uuid;
  v_exp_acct uuid;
  v_ap_acct  uuid;
  v_vat_acct uuid;
begin
  insert into tenants (id, name) values (v_tenant, 'Journal Immutability Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_finance, 'authenticated', 'authenticated',
    'ji-finance@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );

  insert into app_users (id, tenant_id, name, email)
  values (v_finance, v_tenant, 'Finance User', 'ji-finance@test.local');

  insert into finance_team_members (tenant_id, user_id, role)
  values (v_tenant, v_finance, 'finance');

  perform set_config('request.jwt.claims', json_build_object('sub', v_finance)::text, true);
  set local role authenticated;

  insert into organizations (tenant_id, company_code, site_name)
  values (v_tenant, 'JIT', 'Immutability Test Site') returning id into v_org_id;

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
  insert into cost_centers (tenant_id, name) values (v_tenant, 'JI Cost Center') returning id into v_cc_id;
  set local role authenticated;

  insert into supplier_invoices (
    tenant_id, organization_id, invoice_number, invoice_date,
    amount_incl_vat, vat_amount, wht_amount, cost_center_id
  ) values (
    v_tenant, v_org_id, 'JI-INV-001', current_date, 118000, 18000, 0, v_cc_id
  );

  reset role;

  if not exists (select 1 from journal_entries where source_type = 'supplier_invoice' and status = 'posted') then
    raise exception 'FAIL: fixture invoice did not auto-post a journal entry';
  end if;
  if not exists (
    select 1 from journal_entry_lines l
    join journal_entries e on e.id = l.journal_entry_id
    where e.source_type = 'supplier_invoice' and e.status = 'posted'
  ) then
    raise exception 'FAIL: fixture journal entry has no lines';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Trigger shape on the real tables
-- ---------------------------------------------------------------------
do $$
declare
  t text;
  r record;
begin
  foreach t in array array['journal_entries', 'journal_entry_lines'] loop
    select g.tgtype, g.tgenabled into r
    from pg_trigger g
    where g.tgrelid = to_regclass('public.' || t)
      and g.tgfoid = 'public.prevent_journal_mutation()'::regprocedure
      and not g.tgisinternal;

    if not found then
      raise exception 'FAIL: prevent_journal_mutation() is not attached to %', t;
    end if;
    if r.tgenabled <> 'O' then
      raise exception 'FAIL: prevent_journal_mutation trigger on % is not enabled', t;
    end if;
    -- tgtype bits: 1 = ROW, 2 = BEFORE, 4 = INSERT, 8 = DELETE, 16 = UPDATE
    if (r.tgtype & 1) <> 1 or (r.tgtype & 2) <> 2 then
      raise exception 'FAIL: trigger on % must be BEFORE ... FOR EACH ROW', t;
    end if;
    if (r.tgtype & 8) <> 8 or (r.tgtype & 16) <> 16 then
      raise exception 'FAIL: trigger on % must fire on UPDATE and DELETE', t;
    end if;
    if (r.tgtype & 4) <> 0 then
      raise exception 'FAIL: trigger on % fires on INSERT, but the function ends in return null (would cancel inserts)', t;
    end if;
  end loop;
  raise notice 'PASS: prevent_journal_mutation trigger shape on journal_entries / journal_entry_lines';
end $$;

-- ---------------------------------------------------------------------
-- 2. Blocked with the void flag never set, then '' / 'false' / junk.
--    (The flag is NULL in a fresh session; the first block below runs
--    before anything defines it, which is the case the law guard got wrong.)
-- ---------------------------------------------------------------------
do $$
declare
  v_entry uuid;
  v_state text;
begin
  select id into v_entry from journal_entries where source_type = 'supplier_invoice' and status = 'posted' limit 1;

  perform pg_temp.expect_journal_immutable(
    format('update journal_entries set status = ''void'' where id = %L', v_entry),
    'posted->void with the flag never set');

  foreach v_state in array array['', 'false', '1'] loop
    perform set_config('app.allow_journal_void', v_state, true);

    perform pg_temp.expect_journal_immutable(
      format('update journal_entries set status = ''void'' where id = %L', v_entry),
      format('posted->void with flag = %L', v_state));
    perform pg_temp.expect_journal_immutable(
      format('update journal_entries set description = ''tampered'' where id = %L', v_entry),
      format('journal_entries UPDATE with flag = %L', v_state));
    perform pg_temp.expect_journal_immutable(
      format('update journal_entry_lines set description = ''tampered'' where journal_entry_id = %L', v_entry),
      format('journal_entry_lines UPDATE with flag = %L', v_state));
    perform pg_temp.expect_journal_immutable(
      format('delete from journal_entry_lines where journal_entry_id = %L', v_entry),
      format('journal_entry_lines DELETE with flag = %L', v_state));
    perform pg_temp.expect_journal_immutable(
      format('delete from journal_entries where id = %L', v_entry),
      format('journal_entries DELETE with flag = %L', v_state));
  end loop;

  raise notice 'PASS: journal rows are immutable while the void flag is unset / empty / false / junk';
end $$;

-- ---------------------------------------------------------------------
-- 3. With the flag ON, exactly one transition is allowed
-- ---------------------------------------------------------------------
do $$
declare
  v_entry uuid;
  v_n int;
begin
  select id into v_entry from journal_entries where source_type = 'supplier_invoice' and status = 'posted' limit 1;
  perform set_config('app.allow_journal_void', 'true', true);

  -- Lines never get a bypass. journal_entry_lines has no status column; the
  -- old trigger body raised a column error here instead of JOURNAL_IMMUTABLE.
  perform pg_temp.expect_journal_immutable(
    format('update journal_entry_lines set description = ''tampered'' where journal_entry_id = %L', v_entry),
    'journal_entry_lines UPDATE with the flag ON');
  perform pg_temp.expect_journal_immutable(
    format('delete from journal_entry_lines where journal_entry_id = %L', v_entry),
    'journal_entry_lines DELETE with the flag ON');

  -- Entries: DELETE and non-status edits stay blocked even with the flag ON
  perform pg_temp.expect_journal_immutable(
    format('delete from journal_entries where id = %L', v_entry),
    'journal_entries DELETE with the flag ON');
  perform pg_temp.expect_journal_immutable(
    format('update journal_entries set description = ''tampered'' where id = %L', v_entry),
    'journal_entries non-status UPDATE with the flag ON');

  -- The one allowed transition: posted -> void
  update journal_entries set status = 'void' where id = v_entry;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL: posted->void with the flag ON matched % row(s), expected 1', v_n;
  end if;
  if (select status from journal_entries where id = v_entry) <> 'void' then
    raise exception 'FAIL: posted->void did not take effect';
  end if;

  -- ...and it is one-way
  perform pg_temp.expect_journal_immutable(
    format('update journal_entries set status = ''posted'' where id = %L', v_entry),
    'void->posted with the flag ON');

  raise notice 'PASS: with the flag ON only posted->void on journal_entries is allowed';
end $$;

do $$ begin raise notice 'PASS: journal immutability tests (real tables)'; end $$;

rollback;