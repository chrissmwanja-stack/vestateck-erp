-- Phase A, A3 slice 3e: period-end FX revaluation
-- (the fx_gain_unrealised / fx_loss_unrealised roles, fx_revaluation_runs,
-- fin_revalue_fx and fin_void_fx_revaluation).
--
-- Covers: a run revalues every foreign monetary balance -- an AR item, an AP item, a
-- foreign bank account and the unearned-commission residue -- at the closing rate in one
-- balanced functional-currency journal; a second run the same day is refused; voiding
-- reverses the journal exactly; a run date without approved rates is all-or-nothing; the
-- run after a void posts fresh; a later run supersedes the live journal; original item
-- rates are never overwritten; a company without foreign balances gets a journal-free
-- run; cross-tenant reads and non-finance calls are refused.
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

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.gl_net(p_account uuid, p_ccy text, out ccy_net numeric, out base_net numeric)
language sql as $$
  select coalesce(sum(l.debit - l.credit) filter (where l.currency = p_ccy), 0),
         coalesce(sum(l.base_debit - l.base_credit), 0)
  from journal_entry_lines l where l.gl_account_id = p_account
$$;

do $$
declare
  ta       uuid := gen_random_uuid();
  tb       uuid := gen_random_uuid();
  u        uuid := gen_random_uuid();
  ub       uuid := gen_random_uuid();
  out_     uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  g_ops uuid; g_usd uuid; g_ar uuid; g_ap uuid; g_exp uuid; g_unearned uuid; g_income uuid;
  g_ugain uuid; g_uloss uuid;
  reg_id uuid; fx_id uuid;
  b_usd uuid;
  v_client uuid; v_vendor uuid;
  v_je journal_entries%rowtype;
  ar1 uuid; ap1 uuid;
  run fx_revaluation_runs%rowtype;
  run2 fx_revaluation_runs%rowtype;
  r record; n integer;
  je_count integer;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Reval Co'), (tb, 'Plain UGX Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'rv-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (u), (ub), (out_)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (u,   ta, 'RV Finance', 'rv-' || u   || '@test.local'),
    (ub,  tb, 'Plain Finance', 'rv-' || ub  || '@test.local'),
    (out_, ta, 'RV Outsider', 'rv-' || out_ || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, u, 'finance'), (tb, ub, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1000','Operating UGX','asset'), (ta,'1030','Bank USD','asset'),
    (ta,'1100','AR','asset'), (ta,'2000','AP','liability'),
    (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue'),
    (ta,'5000','Expense','expense'), (ta,'4999','Other income','revenue'),
    (ta,'4901','Unrealised FX gain','revenue'), (ta,'5911','Unrealised FX loss','expense');
  select id into g_ops     from gl_accounts where tenant_id=ta and account_code='1000';
  select id into g_usd     from gl_accounts where tenant_id=ta and account_code='1030';
  select id into g_ar      from gl_accounts where tenant_id=ta and account_code='1100';
  select id into g_ap      from gl_accounts where tenant_id=ta and account_code='2000';
  select id into g_unearned from gl_accounts where tenant_id=ta and account_code='2020';
  select id into g_income  from gl_accounts where tenant_id=ta and account_code='4000';
  select id into g_exp     from gl_accounts where tenant_id=ta and account_code='5000';
  select id into g_ugain   from gl_accounts where tenant_id=ta and account_code='4901';
  select id into g_uloss   from gl_accounts where tenant_id=ta and account_code='5911';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'bank',g_ops),(ta,'ar_control',g_ar),(ta,'ap_control',g_ap),
    (ta,'unearned_commission',g_unearned),(ta,'commission_income',g_income),
    (ta,'fx_gain_unrealised',g_ugain),(ta,'fx_loss_unrealised',g_uloss);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'RV-OPS-UGX','operating','UGX',g_ops);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'RV-BANK-USD','operating','USD',g_usd) returning id into b_usd;

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3750, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  -- Parties, as the finance user.
  perform pg_temp.jwt(u);
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (ta, 'C-RV', 'RV Client', 'client') returning id into v_client;
  insert into accounts (tenant_id, account_code, name, account_type) values (ta, 'V-RV', 'RV Vendor', 'vendor') returning id into v_vendor;
  reset role;

  -- Foreign exposures, booked yesterday at 3700. The unearned residue deliberately mixes
  -- a 3750 debit (today) with a 3700 credit (yesterday): the currency nets to zero,
  -- the base keeps a 5,000 debit.
  v_je := post_journal_entry(ta, 'manual', null, current_date - 1, 'USD exposure',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_usd,    'debit',  500,  'currency', 'USD', 'description', 'bank funding'),
      jsonb_build_object('gl_account_id', g_ar,     'debit',  1000, 'currency', 'USD', 'description', 'INV-USD-1'),
      jsonb_build_object('gl_account_id', g_income, 'credit', 1500, 'currency', 'USD', 'description', 'funding and invoice')));
  ar1 := (fin_create_open_item_fx(ta, v_client, 'ar_control', 'test', null, 'INV-USD-1', current_date - 1, null, 1000,
                                  'USD 1,000 due', 'USD', v_je.id)).id;
  v_je := post_journal_entry(ta, 'manual', null, current_date - 1, 'USD payable',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_exp, 'debit',  400, 'currency', 'USD', 'description', 'BILL-USD-1'),
      jsonb_build_object('gl_account_id', g_ap,  'credit', 400, 'currency', 'USD', 'description', 'BILL-USD-1')));
  ap1 := (fin_create_open_item_fx(ta, v_vendor, 'ap_control', 'test', null, 'BILL-USD-1', current_date - 1, null, 400,
                                  'USD 400 owed', 'USD', v_je.id)).id;
  v_je := post_journal_entry(ta, 'manual', null, current_date, 'Unearned clawback at 3750',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_unearned, 'debit',  100, 'currency', 'USD', 'description', 'clawback timing'),
      jsonb_build_object('gl_account_id', g_income,   'credit', 100, 'currency', 'USD', 'description', 'clawback timing')));
  v_je := post_journal_entry(ta, 'manual', null, current_date - 1, 'Unearned clawback at 3700',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_income,   'debit',  100, 'currency', 'USD', 'description', 'clawback timing'),
      jsonb_build_object('gl_account_id', g_unearned, 'credit', 100, 'currency', 'USD', 'description', 'clawback timing')));

  select count(*) into n from journal_entries where tenant_id = ta;
  perform pg_temp.assert(n = 4, format('four fixture journals expected, got %s', n));

  -------------------------------------------------------------------
  -- 1. The run at today's 3750 revalues everything in one journal.
  -------------------------------------------------------------------
  perform pg_temp.jwt(u);
  set local role authenticated;
  run := fin_revalue_fx(current_date);
  reset role;
  perform pg_temp.assert(run.status = 'posted' and run.journal_entry_id is not null, 'the run posts a journal');
  perform pg_temp.assert(jsonb_array_length(run.detail) = 4,
    format('four balances must be revalued, got %s', jsonb_array_length(run.detail)));
  select coalesce(sum(base_debit - base_credit), 0) into n from journal_entry_lines where journal_entry_id = run.journal_entry_id;
  perform pg_temp.assert(n = 0, 'the revaluation journal must balance');
  perform pg_temp.assert(
    not exists (select 1 from journal_entry_lines where journal_entry_id = run.journal_entry_id and (currency <> 'UGX' or fx_rate <> 1)),
    'the revaluation journal must be functional-currency at rate 1');
  -- AR +50,000 and bank +25,000 are gains of 75,000; AP -20,000 and unearned -5,000 are losses of 25,000.
  select * into r from pg_temp.gl_net(g_ar, 'USD');
  perform pg_temp.assert(r.base_net = 3750000 and r.ccy_net = 1000, format('AR must sit at the closing-rate base, got %s / %s', r.base_net, r.ccy_net));
  select * into r from pg_temp.gl_net(g_usd, 'USD');
  perform pg_temp.assert(r.base_net = 1875000, format('the USD bank must sit at its closing-rate base, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_ap, 'USD');
  perform pg_temp.assert(r.base_net = -1500000, format('AP must sit at the closing-rate base, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_unearned, 'USD');
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0, format('the unearned residue must be cleared, got %s / %s', r.ccy_net, r.base_net));
  select * into r from pg_temp.gl_net(g_ugain, 'UGX');
  perform pg_temp.assert(r.base_net = -75000, format('the unrealised gain must be a 75,000 credit, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_uloss, 'UGX');
  perform pg_temp.assert(r.base_net = 25000, format('the unrealised loss must be a 25,000 debit, got %s', r.base_net));
  perform pg_temp.assert(
    (select fx_rate from fin_open_items where id = ar1) = 3700
    and (select base_outstanding_amount from fin_open_item_balances where id = ar1) = 3700000,
    'original item rates and booked bases are never overwritten');
  raise notice 'PASS: one balanced journal revalues every foreign monetary balance to the closing rate';

  -------------------------------------------------------------------
  -- 2. Re-running the same day is refused while the run is live.
  -------------------------------------------------------------------
  perform pg_temp.jwt(u);
  set local role authenticated;
  perform pg_temp.expect_error('select fin_revalue_fx(current_date)', 'FX_REVAL_EXISTS', 'a second run the same day');
  reset role;
  raise notice 'PASS: a live run blocks a same-day rerun';

  -------------------------------------------------------------------
  -- 3. Voiding reverses the journal exactly.
  -------------------------------------------------------------------
  select count(*) into je_count from journal_entries where tenant_id = ta;
  perform pg_temp.jwt(u);
  set local role authenticated;
  run := fin_void_fx_revaluation(run.id, 'Closing rate was withdrawn by the regulator');
  reset role;
  perform pg_temp.assert(run.status = 'void' and run.void_journal_entry_id is not null, 'the run is void');
  perform pg_temp.assert((select count(*) from journal_entries where tenant_id = ta) = je_count + 1, 'the void adds exactly one journal');
  select * into r from pg_temp.gl_net(g_ar, 'USD');
  perform pg_temp.assert(r.base_net = 3700000, format('AR must be back at the booked base, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_unearned, 'USD');
  perform pg_temp.assert(r.base_net = 5000, format('the unearned residue must be back, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_ugain, 'UGX');
  perform pg_temp.assert(r.base_net = 0, 'the unrealised gain must be undone');
  raise notice 'PASS: voiding reverses the journal exactly';

  -------------------------------------------------------------------
  -- 4. A run date without approved rates is all-or-nothing.
  -------------------------------------------------------------------
  select count(*) into je_count from journal_entries where tenant_id = ta;
  perform pg_temp.jwt(u);
  set local role authenticated;
  perform pg_temp.expect_error('select fin_revalue_fx(current_date - 10)', 'FX_RATE_MISSING', 'a run date before any rate');
  reset role;
  perform pg_temp.assert((select count(*) from journal_entries where tenant_id = ta) = je_count, 'a refused run writes nothing');
  perform pg_temp.assert(not exists (select 1 from fx_revaluation_runs where tenant_id = ta and as_of = current_date - 10),
    'a refused run leaves no run row');
  raise notice 'PASS: a missing closing rate refuses the whole run and writes nothing';

  -------------------------------------------------------------------
  -- 5. After a void, the same day runs fresh.
  -------------------------------------------------------------------
  perform pg_temp.jwt(u);
  set local role authenticated;
  run2 := fin_revalue_fx(current_date);
  reset role;
  perform pg_temp.assert(run2.status = 'posted' and run2.journal_entry_id is not null
                     and run2.id <> run.id, 'a fresh run posts after the void');
  select * into r from pg_temp.gl_net(g_ugain, 'UGX');
  perform pg_temp.assert(r.base_net = -75000, format('the fresh run books the same 75,000 gain, got %s', r.base_net));
  raise notice 'PASS: the same day can be revalued after a void';

  -------------------------------------------------------------------
  -- 6. A later run supersedes the live journal (reversing it first) and
  --    posts only what still moves. At yesterday's 3700 the AR, bank and
  --    AP move back onto their booked rates, so only the unearned
  --    residue (booked mixed-rate) still differs from its closing value.
  -------------------------------------------------------------------
  perform pg_temp.jwt(u);
  set local role authenticated;
  run := fin_revalue_fx(current_date - 1);
  reset role;
  perform pg_temp.assert(run.status = 'posted' and run.journal_entry_id is not null, 'the later run posts');
  perform pg_temp.assert(jsonb_array_length(run.detail) = 1,
    format('only the unearned residue still moves at 3700, got %s rows', jsonb_array_length(run.detail)));
  perform pg_temp.assert((select status from fx_revaluation_runs where id = run2.id) = 'void',
    'the previous run must be superseded');
  perform pg_temp.assert((select count(*) from journal_entries j where j.id = (select void_journal_entry_id from fx_revaluation_runs where id = run2.id)) = 1,
    'the superseded journal must be reversed');
  select * into r from pg_temp.gl_net(g_ar, 'USD');
  perform pg_temp.assert(r.base_net = 3700000 and r.ccy_net = 1000,
    format('at yesterday 3700 the AR move is zero, got %s / %s', r.base_net, r.ccy_net));
  select * into r from pg_temp.gl_net(g_unearned, 'USD');
  perform pg_temp.assert(r.base_net = 0, format('the residue must be cleared by the later run, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_uloss, 'UGX');
  perform pg_temp.assert(r.base_net = 5000, format('the loss account must carry the 5,000 residue, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_ugain, 'UGX');
  perform pg_temp.assert(r.base_net = 0, format('the superseded gain must be fully reversed, got %s', r.base_net));
  perform pg_temp.jwt(u);
  perform pg_temp.expect_error(format('select fin_void_fx_revaluation(%L, ''too late'')', run2.id), 'FX_REVAL_VOID', 'voiding a superseded run');
  reset role;
  raise notice 'PASS: a later run supersedes and reverses the live journal, posting only what still moves';

  -------------------------------------------------------------------
  -- 7. A company without foreign balances gets a journal-free run.
  -------------------------------------------------------------------
  perform pg_temp.jwt(ub);
  run := fin_revalue_fx(current_date);
  perform pg_temp.assert(run.status = 'posted' and run.journal_entry_id is null
                     and jsonb_array_length(run.detail) = 0,
    'a functional-only company revalues nothing');
  -- RLS: tenant B sees none of tenant A's runs (as authenticated, not as the owner).
  set local role authenticated;
  select count(*) into n from fx_revaluation_runs where tenant_id = ta;
  reset role;
  perform pg_temp.assert(n = 0, format('tenant B must see none of tenant A runs, got %s', n));
  perform pg_temp.jwt(out_);
  perform pg_temp.expect_error('select fin_revalue_fx(current_date)', 'FX_REVAL_FORBIDDEN', 'a non-finance caller');
  reset role;
  raise notice 'PASS: a functional-only company runs clean, and access is gated';

  raise notice 'ALL PASS: period-end FX revaluation';
end
$$;

rollback;
