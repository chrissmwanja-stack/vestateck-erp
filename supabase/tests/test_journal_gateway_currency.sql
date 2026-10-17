-- Phase A, A3 slice 2c: currency-aware posting gateway and rate-preserving void
-- (post_journal_entry, void_journal_entry, journal_lines_fx_guard).
--
-- Covers: a foreign journal posts through the gateway with the approved rate (a
-- caller-supplied rate is ignored); lines with no currency are functional currency at
-- rate 1 as before; a missing rate posts nothing; rounding works through the gateway;
-- voiding a foreign journal nets to zero in base currency at the ORIGINAL rate even
-- after the rate has changed; a voided journal with a rounding line reverses it and
-- keeps it flagged; a UGX void is unchanged; void stays idempotent; the reversal-mode
-- setting cannot be used to choose an arbitrary rate.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

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

-- Base-currency net (debit minus credit) of every line of the given entries.
create function pg_temp.base_net(p_entries uuid[]) returns numeric language sql as $$
  select coalesce(sum(base_debit - base_credit), 0)
  from journal_entry_lines where journal_entry_id = any (p_entries)
$$;

-- Base-currency net per account over the given entries, as account_code=net text.
create function pg_temp.net_by_account(p_entries uuid[]) returns text language sql as $$
  select coalesce(string_agg(a.account_code || '=' || round(x.net, 2), ',' order by a.account_code), '')
  from (select gl_account_id, sum(base_debit - base_credit) as net
          from journal_entry_lines where journal_entry_id = any (p_entries)
         group by gl_account_id) x
  join gl_accounts a on a.id = x.gl_account_id
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  fin uuid := gen_random_uuid();
  bank uuid; rev1 uuid; rev2 uuid; rnd uuid;
  reg_id uuid; fx_id uuid;
  e1 jsonb; je1 uuid; je2 uuid; je3 uuid; jev1 uuid; jev3 uuid; je_ugx uuid; jev_ugx uuid; je_r uuid;
  r record; n integer;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Gateway Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', fin, 'authenticated', 'authenticated', 'gw-' || fin || '@test.local',
          extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}',
          now(), now(), '', '');
  insert into app_users (id, tenant_id, name, email, is_company_admin)
  values (fin, ta, 'Gateway Finance', 'gw-' || fin || '@test.local', false);
  insert into finance_team_members (tenant_id, user_id, role) values (ta, fin, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank', 'asset'), (ta, '4000', 'Income 1', 'revenue'), (ta, '4100', 'Income 2', 'revenue'),
    (ta, '6999', 'FX rounding', 'expense');
  select id into bank from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into rev1 from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into rev2 from gl_accounts where tenant_id = ta and account_code = '4100';
  select id into rnd  from gl_accounts where tenant_id = ta and account_code = '6999';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values (ta, 'fx_rounding', rnd);

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  -- USD 3700 yesterday; USD 3800 today. A new journal dated yesterday uses 3700; one dated today would use 3800.
  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
    values (ta, 'USD', current_date - 1, 3700, 'test fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
    values (ta, 'USD', current_date, 3800, 'test fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  -------------------------------------------------------------------
  -- 1. A foreign journal posts through the gateway; a supplied rate is ignored
  -------------------------------------------------------------------
  select id into je1 from post_journal_entry(ta, 'manual', null, current_date - 1, 'usd sale', jsonb_build_array(
    jsonb_build_object('gl_account_id', bank, 'debit', 1000, 'credit', 0, 'currency', 'USD', 'fx_rate', 99),
    jsonb_build_object('gl_account_id', rev1, 'debit', 0, 'credit', 1000, 'currency', 'USD', 'fx_rate', 99)));
  set constraints all immediate;
  set constraints all deferred;
  select * into r from journal_entry_lines where journal_entry_id = je1 and gl_account_id = bank;
  perform pg_temp.assert(r.currency = 'USD' and r.fx_rate = 3700 and r.base_debit = 3700000,
    format('foreign line wrong: %s rate %s base %s', r.currency, r.fx_rate, r.base_debit));
  raise notice 'PASS: a foreign journal posts through the gateway at the approved rate; a supplied rate is ignored';

  -------------------------------------------------------------------
  -- 2. Lines with no currency stay functional currency at rate 1
  -------------------------------------------------------------------
  select id into je_ugx from post_journal_entry(ta, 'manual', null, current_date - 1, 'ugx sale', jsonb_build_array(
    jsonb_build_object('gl_account_id', bank, 'debit', 500, 'credit', 0, 'fx_rate', 5),
    jsonb_build_object('gl_account_id', rev1, 'debit', 0, 'credit', 500)));
  set constraints all immediate;
  set constraints all deferred;
  perform pg_temp.assert(not exists (select 1 from journal_entry_lines where journal_entry_id = je_ugx and (currency <> 'UGX' or fx_rate <> 1)),
    'a line with no currency must be UGX at rate 1');
  raise notice 'PASS: lines with no currency are UGX at rate 1, exactly as before';

  -------------------------------------------------------------------
  -- 3. A missing rate posts nothing
  -------------------------------------------------------------------
  perform pg_temp.expect_error(format(
    $q$select post_journal_entry(%L, 'manual', null, current_date - 1, 'missing rate', %L::jsonb)$q$,
    ta, jsonb_build_array(
      jsonb_build_object('gl_account_id', bank, 'debit', 10, 'credit', 0, 'currency', 'KES'),
      jsonb_build_object('gl_account_id', rev1, 'debit', 0, 'credit', 10, 'currency', 'KES'))::text),
    'FX_RATE_MISSING', 'currency with no approved rate');
  perform pg_temp.assert(not exists (select 1 from journal_entries where tenant_id = ta and description = 'missing rate'),
    'a refused posting must leave no journal entry behind');
  raise notice 'PASS: a missing rate raises and leaves nothing behind';

  -------------------------------------------------------------------
  -- 4. Rounding works through the gateway
  -------------------------------------------------------------------
  -- 1.00 = 0.33 + 0.67 in USD at 3700 is exact in base; use a rate that rounds: 1.5 on a second currency.
  perform set_config('fx.via_rpc', 'on', true);
  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
    values (ta, 'EUR', current_date - 1, 1.5, 'test fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('fx.via_rpc', 'off', true);
  select id into je_r from post_journal_entry(ta, 'manual', null, current_date - 1, 'rounding sale', jsonb_build_array(
    jsonb_build_object('gl_account_id', bank, 'debit', 1.00, 'credit', 0, 'currency', 'EUR'),
    jsonb_build_object('gl_account_id', rev1, 'debit', 0, 'credit', 0.33, 'currency', 'EUR'),
    jsonb_build_object('gl_account_id', rev2, 'debit', 0, 'credit', 0.67, 'currency', 'EUR')));
  set constraints all immediate;
  set constraints all deferred;
  perform pg_temp.assert((select count(*) from journal_entry_lines where journal_entry_id = je_r and is_rounding) = 1,
    'the gateway posting needing rounding should carry exactly one rounding line');
  perform pg_temp.assert(pg_temp.base_net(array[je_r]) = 0, 'rounding entry must balance in base');
  raise notice 'PASS: rounding works through the gateway';

  -------------------------------------------------------------------
  -- 5. Void a foreign journal: nets to zero in base at the ORIGINAL rate
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into jev1 from void_journal_entry(je1, 'void the usd sale test');
  reset role;
  set constraints all immediate;
  set constraints all deferred;

  perform pg_temp.assert(pg_temp.net_by_account(array[je1, jev1]) = '1000=0.00,4000=0.00',
    format('after voiding, both accounts must net to zero in base, got %s', pg_temp.net_by_account(array[je1, jev1])));
  perform pg_temp.assert(not exists (
      select 1 from journal_entry_lines where journal_entry_id = jev1 and (currency <> 'USD' or fx_rate <> 3700)),
    'the reversal must keep USD and the original 3700 rate, not today''s 3800');
  perform pg_temp.assert((select status from journal_entries where id = je1) = 'void', 'the original must be marked void');
  raise notice 'PASS: voiding a USD 1,000 sale nets to zero in base at the original rate, although today''s rate is 3800';

  -- Void is idempotent.
  perform set_config('request.jwt.claims', json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into je2 from void_journal_entry(je1, 'void it again please');
  reset role;
  perform pg_temp.assert(je2 = je1, 'a second void must return the already-void original');
  raise notice 'PASS: voiding twice is a no-op';

  -------------------------------------------------------------------
  -- 6. Void a journal that has a rounding line
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into jev3 from void_journal_entry(je_r, 'void the rounding sale test');
  reset role;
  set constraints all immediate;
  set constraints all deferred;
  perform pg_temp.assert(pg_temp.base_net(array[je_r, jev3]) = 0, 'the voided rounding entry and its reversal must net to zero overall');
  perform pg_temp.assert(pg_temp.net_by_account(array[je_r, jev3]) like '%6999=0.00%',
    format('the rounding account must net to zero after the void, got %s', pg_temp.net_by_account(array[je_r, jev3])));
  perform pg_temp.assert((select count(*) from journal_entry_lines where journal_entry_id = jev3 and is_rounding) = 1,
    'the reversal must carry exactly one rounding line (the reversed one), not a new one');
  perform pg_temp.assert(not exists (select 1 from journal_entry_lines where journal_entry_id = jev3 and currency = 'EUR' and fx_rate <> 1.5),
    'EUR lines of the reversal must keep rate 1.5');
  raise notice 'PASS: a rounding line is reversed and stays flagged; rounding nets to zero';

  -------------------------------------------------------------------
  -- 7. A UGX void is unchanged
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into jev_ugx from void_journal_entry(je_ugx, 'void the ugx sale test');
  reset role;
  set constraints all immediate;
  set constraints all deferred;
  perform pg_temp.assert(pg_temp.net_by_account(array[je_ugx, jev_ugx]) = '1000=0.00,4000=0.00', 'UGX void must net to zero');
  perform pg_temp.assert(not exists (select 1 from journal_entry_lines where journal_entry_id = jev_ugx and (currency <> 'UGX' or fx_rate <> 1 or is_rounding)),
    'a UGX reversal must be UGX at rate 1 with no rounding flag');
  raise notice 'PASS: a UGX void is unchanged';

  -------------------------------------------------------------------
  -- 8. The reversal-mode setting cannot pick an arbitrary rate
  -------------------------------------------------------------------
  -- (last: the entry below is deliberately incomplete, so no constraint flush follows)
  select id into je3 from post_journal_entry(ta, 'manual', null, current_date - 1, 'misuse target', jsonb_build_array(
    jsonb_build_object('gl_account_id', bank, 'debit', 1, 'credit', 0, 'currency', 'USD'),
    jsonb_build_object('gl_account_id', rev1, 'debit', 0, 'credit', 1, 'currency', 'USD')));
  perform set_config('fin.reversal_of', je3::text, true);
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency, fx_rate)
       values (%L, %L, %L, 1, 0, 'USD', 1234)$q$, je3, ta, bank),
    'JOURNAL_LINE_RATE', 'reversal mode with a rate the original never used');
  perform set_config('fin.reversal_of', '', true);
  -- Outside reversal mode a supplied rate is simply overwritten by the approved one.
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency, fx_rate)
    values (je3, ta, bank, 2, 0, 'USD', 1234) returning * into r;
  perform pg_temp.assert(r.fx_rate = 3700, format('outside reversal mode the approved rate must win, got %s', r.fx_rate));
  raise notice 'PASS: the reversal setting only accepts rates the original entry already used';
end $$;

do $$ begin raise notice 'PASS: journal gateway currency and reversal (A3 slice 2c) tests'; end $$;

rollback;