-- Phase A, A3 slice 2: transaction currency, rate and base amount on journal lines
-- (migration 20261016150000_journal_base_amounts.sql).
--
-- Covers: existing UGX lines are unchanged; a UGX posting keeps exact amounts; the
-- caller cannot set a rate; a foreign line takes the approved rate; a journal must
-- balance in base currency; a missing rate raises; one company's rate is not used
-- by another; the rate trigger is not executable by clients.
--
-- Run against a fresh local stack. One transaction that ROLLBACKs. Any RAISE
-- EXCEPTION is a real assertion failure.
\set ON_ERROR_STOP on
begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then
      return;
    end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  fin_a uuid := gen_random_uuid(); fin_b uuid := gen_random_uuid();
  bank_a uuid; rev_a uuid; bank_b uuid; reg_id uuid;
  je uuid; n integer; r record; v_ok boolean;
begin
  insert into tenants (id, name) values (ta, 'Base amounts A'), (tb, 'Base amounts B');
  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank', 'asset'), (ta, '4000', 'Income', 'revenue'), (tb, '1000', 'Bank B', 'asset');
  select id into bank_a from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into rev_a  from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into bank_b from gl_accounts where tenant_id = tb and account_code = '1000';

  -- Fixtures as the table owner. A USD rate for company A, approved by someone else.
  -- The rate age limit is an approved regulatory parameter (no default).
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture')
    returning id into reg_id;
  perform set_config('reg.via_rpc', 'on', true);
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  perform set_config('reg.via_rpc', 'off', true);
  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
    values (ta, 'USD', current_date - 1, 3700.1234, 'test fixture') returning id into je;
  perform set_config('fx.via_rpc', 'on', true);
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = je;
  perform set_config('fx.via_rpc', 'off', true);

  -- 1. Existing lines (all UGX) are unchanged: base equals the transaction amount.
  select count(*) into n from journal_entry_lines
   where currency = 'UGX' and (base_debit <> debit or base_credit <> credit or fx_rate <> 1);
  perform pg_temp.assert(n = 0, format('%s existing UGX lines changed base amounts', n));
  raise notice 'PASS: existing UGX lines unchanged';

  -- 2. A UGX posting through the normal path keeps exact amounts (no rounding).
  perform post_journal_entry(ta, 'manual', null, current_date - 1, 'UGX exact',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', bank_a, 'debit', 1000.55),
      jsonb_build_object('gl_account_id', rev_a, 'credit', 1000.55)));
  select count(*) into n from journal_entry_lines l join journal_entries j on j.id = l.journal_entry_id
   where j.tenant_id = ta and j.description = 'UGX exact' and l.fx_rate = 1
     and (l.base_debit = 1000.55 or l.base_credit = 1000.55);
  perform pg_temp.assert(n = 2, format('UGX posting: expected 2 exact lines, found %s', n));
  raise notice 'PASS: UGX posting keeps exact amounts';

  -- 3. The caller cannot choose the rate. A functional line is always rate 1.
  insert into journal_entries (tenant_id, entry_date, source_type, description)
    values (ta, current_date - 1, 'manual', 'caller rate') returning id into je;
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, fx_rate)
    values (je, ta, bank_a, 5, 0, 999), (je, ta, rev_a, 0, 5, 999);
  select min(fx_rate), max(fx_rate) into r from journal_entry_lines where journal_entry_id = je;
  perform pg_temp.assert(r.min = 1 and r.max = 1, 'caller-supplied fx_rate 999 was stored on a functional line');
  raise notice 'PASS: caller cannot set the rate';

  -- 4. A foreign line takes the approved rate and computes base amounts from it.
  insert into journal_entries (tenant_id, entry_date, source_type, description)
    values (ta, current_date - 1, 'manual', 'usd') returning id into je;
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
    (je, ta, bank_a, 1000, 0, 'USD'),
    (je, ta, rev_a,  0, 1000, 'USD');
  select * into r from journal_entry_lines where journal_entry_id = je and debit > 0;
  perform pg_temp.assert(r.fx_rate = 3700.1234 and r.base_debit = 3700123.40 and r.currency = 'USD',
    format('USD line: rate %s base %s currency %s, expected 3700.1234 / 3700123.40 / USD', r.fx_rate, r.base_debit, r.currency));
  raise notice 'PASS: foreign line uses the approved rate';

  -- 5. A journal must balance in base currency. Transaction amounts balance (10 = 10),
  -- base amounts do not (37001.23 against 10).
  insert into journal_entries (tenant_id, entry_date, source_type, description)
    values (ta, current_date - 1, 'manual', 'base unbalanced') returning id into je;
  set constraints all immediate;
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
       (%L, %L, %L, 10, 0, 'USD'), (%L, %L, %L, 0, 10, 'UGX')$q$,
    je, ta, bank_a, je, ta, rev_a),
    'JOURNAL_BASE_UNBALANCED', 'base-unbalanced journal');
  set constraints all deferred;
  raise notice 'PASS: journal must balance in base currency';

  -- 6. A foreign currency with no approved rate raises. No default rate.
  insert into journal_entries (tenant_id, entry_date, source_type, description)
    values (ta, current_date - 1, 'manual', 'eur') returning id into je;
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency)
       values (%L, %L, %L, 10, 0, 'EUR')$q$, je, ta, bank_a),
    'FX_RATE_MISSING', 'EUR line without a rate');
  raise notice 'PASS: missing rate raises';

  -- 7. Company B cannot use company A's USD rate.
  insert into journal_entries (tenant_id, entry_date, source_type, description)
    values (tb, current_date - 1, 'manual', 'tenant b usd') returning id into je;
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency)
       values (%L, %L, %L, 10, 0, 'USD')$q$, je, tb, bank_b),
    'FX_RATE_MISSING', 'company B using company A''s USD rate');
  raise notice 'PASS: a rate is not shared between companies';

  -- 8. The rate trigger is not executable by client roles.
  select has_function_privilege('authenticated', 'public.journal_lines_fx_guard()', 'execute') into v_ok;
  perform pg_temp.assert(not v_ok, 'authenticated can execute journal_lines_fx_guard');
  select has_function_privilege('anon', 'public.journal_lines_fx_guard()', 'execute') into v_ok;
  perform pg_temp.assert(not v_ok, 'anon can execute journal_lines_fx_guard');
  raise notice 'PASS: rate trigger is internal';

  -- 9. The ledger view exposes base amounts and applies the caller's row-level security.
  select coalesce(c.reloptions @> array['security_invoker=true'], false) into v_ok
    from pg_class c where c.relname = 'v_account_ledger' and c.relnamespace = 'public'::regnamespace;
  perform pg_temp.assert(v_ok, 'v_account_ledger does not use security_invoker');
  select count(*) into n from v_account_ledger
   where tenant_id = ta and currency = 'USD' and (base_debit = 3700123.40 or base_credit = 3700123.40) and fx_rate = 3700.1234;
  perform pg_temp.assert(n = 2, format('ledger view: expected 2 USD lines with base 3700123.40, found %s', n));

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'ledger-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{}', '{}', now(), now(), '', ''
    from (values (fin_a), (fin_b)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (fin_a, ta, 'Ledger finance A', 'ledger-' || fin_a || '@test.local'),
    (fin_b, tb, 'Ledger finance B', 'ledger-' || fin_b || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, fin_a, 'finance'), (tb, fin_b, 'finance');

  -- Company B's finance user sees none of company A's ledger rows through the view.
  perform set_config('request.jwt.claims', json_build_object('sub', fin_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from v_account_ledger where tenant_id = ta;
  reset role;
  perform pg_temp.assert(n = 0, format('company B finance user read %s of company A ledger rows', n));

  -- Company A's finance user does see them (positive control, so the zero above means something).
  perform set_config('request.jwt.claims', json_build_object('sub', fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from v_account_ledger where tenant_id = ta;
  reset role;
  perform pg_temp.assert(n > 0, 'company A finance user cannot read company A ledger rows');
  raise notice 'PASS: ledger view exposes base amounts and respects company isolation';
end $$;

rollback;
