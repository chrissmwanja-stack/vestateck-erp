-- A3 follow-ups F3 + F4: currency column defaults and 8-decimal rates.
--
-- Covers: the journal gateway derives an omitted line currency from the
-- tenant's ledger (a USD-ledger company no longer sees its functional lines
-- labelled UGX; a UGX company is unchanged); the five currency columns carry
-- no default at all, so a writer that omits currency fails loudly; a rate
-- keyed in with more precision is rounded to 8 decimals at approval; and the
-- stored-rate-is-the-used-rate invariant is pinned by check constraints on
-- fx_rates, journal_entry_lines and fin_settlements.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction
-- that ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

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

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  ta       uuid := gen_random_uuid();  -- USD ledger
  tb       uuid := gen_random_uuid();  -- UGX ledger (no settings row)
  ua       uuid := gen_random_uuid();
  ub       uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  reg_id uuid; fx_id uuid;
  g_bank_a uuid; g_income_a uuid; g_bank_b uuid; g_income_b uuid;
  je journal_entries%rowtype;
  n integer; r record;
begin
  -------------------------------------------------------------------
  -- Fixtures: ta's ledger is USD via tenant_ledger_settings (the setter
  -- is platform-only, so the row is seeded directly, as production
  -- would); tb is a plain UGX company. Both get the minimal books.
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'F3 USD Co'), (tb, 'F3 UGX Co');
  insert into tenant_ledger_settings (tenant_id, functional_currency) values (ta, 'USD');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'f34-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (ua), (ub), (approver)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (ua, ta, 'F3 USD Finance', 'f34-' || ua || '@test.local'),
    (ub, tb, 'F3 UGX Finance', 'f34-' || ub || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, ua, 'finance'), (tb, ub, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1000','Bank USD','asset'), (ta,'4000','Income','revenue'),
    (tb,'1000','Bank UGX','asset'), (tb,'4000','Income','revenue');
  select id into g_bank_a   from gl_accounts where tenant_id=ta and account_code='1000';
  select id into g_income_a from gl_accounts where tenant_id=ta and account_code='4000';
  select id into g_bank_b   from gl_accounts where tenant_id=tb and account_code='1000';
  select id into g_income_b from gl_accounts where tenant_id=tb and account_code='4000';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'bank',g_bank_a),(ta,'commission_income',g_income_a),
    (tb,'bank',g_bank_b),(tb,'commission_income',g_income_b);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'F3-BANK-USD','operating','USD',g_bank_a),
    (tb,'F3-BANK-UGX','operating','UGX',g_bank_b);

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  perform set_config('reg.via_rpc', 'off', true);

  -------------------------------------------------------------------
  -- 1. The gateway derives an omitted line currency from the ledger.
  -------------------------------------------------------------------
  je := post_journal_entry(ta, 'manual', null, current_date, 'USD functional lines',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_bank_a,   'debit',  100),
      jsonb_build_object('gl_account_id', g_income_a, 'credit', 100)));
  select count(*) into n from journal_entry_lines where journal_entry_id = je.id and currency = 'USD';
  perform pg_temp.assert(n = 2, format('the USD ledger labels unlabelled lines USD, got %s', n));

  je := post_journal_entry(tb, 'manual', null, current_date, 'UGX functional lines',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_bank_b,   'debit',  100),
      jsonb_build_object('gl_account_id', g_income_b, 'credit', 100)));
  select count(*) into n from journal_entry_lines where journal_entry_id = je.id and currency = 'UGX';
  perform pg_temp.assert(n = 2, format('the UGX ledger is unchanged, got %s', n));

  -- An explicit currency is honoured as before (USD is ta's functional currency
  -- here, so it posts at rate 1 without a rate row).
  je := post_journal_entry(ta, 'manual', null, current_date, 'explicit line currency',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_bank_a,   'debit',  10, 'currency', 'USD'),
      jsonb_build_object('gl_account_id', g_income_a, 'credit', 10, 'currency', 'USD')));
  select count(*) into n from journal_entry_lines where journal_entry_id = je.id and currency = 'USD';
  perform pg_temp.assert(n = 2, format('an explicit line currency is honoured, got %s', n));

  -- F4 fixture: a rate for a genuinely foreign currency, keyed in with 10 decimals.
  perform set_config('fx.via_rpc', 'on', true);
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'EUR', current_date, 4100.1234567891, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('fx.via_rpc', 'off', true);
  raise notice 'PASS: the gateway derives an omitted line currency from the ledger';

  -------------------------------------------------------------------
  -- 2. No currency column guesses UGX by default; omitting one is a
  --    loud not-null failure, not a silent mislabel.
  -------------------------------------------------------------------
  perform pg_temp.assert(
    (select count(*) from information_schema.columns
      where (table_name, column_name) in (
        ('journal_entry_lines','currency'), ('cash_bank_transactions','currency'),
        ('fin_open_items','currency'), ('fin_bank_accounts','currency'),
        ('ins_policies','currency'), ('bank_statement_lines','currency'))
        and column_default is not null) = 0,
    'none of the five currency columns may carry a default');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (%L::uuid, ''NO-CCY'', ''operating'', %L::uuid)',
           tb, g_bank_b),
    'violates not-null constraint', 'a bank account inserted without a currency');
  raise notice 'PASS: the currency defaults are gone and omission fails loudly';

  -------------------------------------------------------------------
  -- 3. F4: a rate keyed in with 10 decimals is rounded to 8 at
  --    approval, and the stored rate is the used rate everywhere.
  -------------------------------------------------------------------
  perform pg_temp.assert(
    (select rate from fx_rates where id = fx_id) = 4100.12345679,
    format('the approved rate is stored at 8 decimals, got %s', (select rate from fx_rates where id = fx_id)));
  perform pg_temp.assert(
    (select count(*) from pg_constraint
      where conname in ('fx_rates_rate_8dp', 'journal_entry_lines_fx_rate_8dp', 'fin_settlements_fx_rate_8dp')
        and convalidated) = 3,
    'the three 8dp check constraints exist');
  perform pg_temp.assert(
    not exists (select 1 from fx_rates where rate <> round(rate, 8))
    and not exists (select 1 from journal_entry_lines where fx_rate <> round(fx_rate, 8))
    and not exists (select 1 from fin_settlements where fx_rate <> round(fx_rate, 8)),
    'every stored rate in the books is 8-decimal');
  raise notice 'PASS: rates are 8-decimal at approval and at rest';

  -------------------------------------------------------------------
  -- 4. The platform rate reads back what was approved -- the rounding
  --    must not differ between storage and use.
  -------------------------------------------------------------------
  perform pg_temp.assert(
    (platform_fx_rate(ta, 'EUR', current_date)).rate = 4100.12345679,
    'the platform rate is the stored (already rounded) rate');
  raise notice 'PASS: the platform rate reads back exactly what was approved';

  raise notice 'ALL PASS: F3 currency defaults and F4 8-decimal rates';
end
$$;

rollback;
