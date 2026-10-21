-- Phase A, A3 slice 3d-1: foreign-currency credit notes
-- (fin_credit_notes.fx_rate / base_amount / realised_result, the rate rules in
-- fin_credit_notes_guard, the currency-aware raise functions, and the
-- reversal-mode void).
--
-- Covers: a USD credit note against a USD receivable booked at yesterday's rate takes
-- the items' currency, the note-date rate for the offset line, the item's booked rate
-- for the control line, and books the difference as a realised gain; the sign is
-- mirrored on the payable side (a loss when the payable was booked cheaper); two items
-- booked at different rates give one control line per booking entry; mixed-currency
-- applications are refused; a foreign note at a rate other than the approved credit-date
-- rate is refused, and so is a functional note at a rate other than 1 or with a realised
-- result; functional-currency notes are unchanged line for line; voiding a foreign note
-- negates it exactly, realised line included; the balance nets to zero in the currency
-- and in base.
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

-- Net of one account over the journals of the given source documents: currency net and base net.
create function pg_temp.net_of(p_account uuid, p_sources uuid[], out ccy_net numeric, out base_net numeric)
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0), coalesce(sum(l.base_debit - l.base_credit), 0)
  from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
  where e.source_id = any (p_sources) and l.gl_account_id = p_account
$$;

create function pg_temp.lines_of(p_source uuid) returns text language sql as $$
  select coalesce(string_agg(format('%s=%s/%s %s@%s base %s/%s', a.account_code, l.debit, l.credit, l.currency, l.fx_rate,
                                    l.base_debit, l.base_credit), ' | ' order by a.account_code, l.debit), '(none)')
  from journal_entries e
  join journal_entry_lines l on l.journal_entry_id = e.id
  join gl_accounts a on a.id = l.gl_account_id
  where e.source_id = p_source
$$;

create function pg_temp.a1(p_item uuid, p_amt numeric)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('open_item_id', p_item, 'amount', p_amt))
$$;

create function pg_temp.a2(p_item1 uuid, p_amt1 numeric, p_item2 uuid, p_amt2 numeric)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('open_item_id', p_item1, 'amount', p_amt1),
                           jsonb_build_object('open_item_id', p_item2, 'amount', p_amt2))
$$;

do $$
declare
  ta       uuid := gen_random_uuid();
  u        uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  org      uuid;
  g_bank uuid; g_ar uuid; g_ap uuid; g_rev uuid; g_exp uuid; g_gain uuid; g_loss uuid;
  reg_id uuid; fx_id uuid;
  v_client uuid; v_vendor uuid;
  -- booking entries and open items
  v_je journal_entries%rowtype;
  e1 uuid; e2 uuid; e3 uuid;
  ar1 uuid; ar2 uuid; ar3 uuid; ar_ugx uuid; ap1 uuid;
  cn  fin_credit_notes%rowtype;
  cn2 fin_credit_notes%rowtype;
  v_void fin_credit_notes%rowtype;
  r record;
  n integer;
  v_bal numeric;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Foreign Credit Note Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated', 'fcn-' || u || '@test.local',
          extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}',
          now(), now(), '', '');
  insert into app_users (id, tenant_id, name, email) values (u, ta, 'FCN Finance', 'fcn-' || u || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, u, 'finance');
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank', 'asset'), (ta, '1100', 'AR', 'asset'), (ta, '2000', 'AP', 'liability'),
    (ta, '4000', 'Revenue', 'revenue'), (ta, '5000', 'Premium adjustments', 'expense'),
    (ta, '4900', 'Realised FX gain', 'revenue'), (ta, '5910', 'Realised FX loss', 'expense');
  select id into g_bank from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into g_ar   from gl_accounts where tenant_id = ta and account_code = '1100';
  select id into g_ap   from gl_accounts where tenant_id = ta and account_code = '2000';
  select id into g_rev  from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into g_exp  from gl_accounts where tenant_id = ta and account_code = '5000';
  select id into g_gain from gl_accounts where tenant_id = ta and account_code = '4900';
  select id into g_loss from gl_accounts where tenant_id = ta and account_code = '5910';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta, 'bank', g_bank), (ta, 'ar_control', g_ar), (ta, 'ap_control', g_ap),
    (ta, 'default_revenue', g_rev), (ta, 'default_expense', g_exp),
    (ta, 'fx_gain_realised', g_gain), (ta, 'fx_loss_realised', g_loss);

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3800, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  -- Parties, booked as the finance user.
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (ta, 'C-FCN', 'FCN Client', 'client') returning id into v_client;
  insert into accounts (tenant_id, account_code, name, account_type) values (ta, 'V-FCN', 'FCN Vendor', 'vendor') returning id into v_vendor;
  reset role;

  -------------------------------------------------------------------
  -- Booked foreign items: entry 1 (yesterday, 3700) carries a USD 1,000
  -- and a USD 600 receivable; entry 2 (today, 3800) a USD 400 receivable;
  -- entry 3 (yesterday) a USD 500 payable.
  -------------------------------------------------------------------
  v_je := post_journal_entry(ta, 'manual', null, current_date - 1, 'USD receivables booked yesterday',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_ar,  'debit',  1600, 'currency', 'USD', 'description', 'INV-USD-1'),
      jsonb_build_object('gl_account_id', g_rev, 'credit', 1600, 'currency', 'USD', 'description', 'INV-USD-1')));
  e1 := v_je.id;
  ar1 := (fin_create_open_item_fx(ta, v_client, 'ar_control', 'test', null, 'INV-USD-1', current_date - 1, null, 1000,
                                 'USD 1,000 due', 'USD', e1)).id;
  ar3 := (fin_create_open_item_fx(ta, v_client, 'ar_control', 'test', null, 'INV-USD-1b', current_date - 1, null, 600,
                                 'USD 600 due', 'USD', e1)).id;
  perform pg_temp.assert((select fx_rate from fin_open_items where id = ar1) = 3700
                     and (select fx_rate from fin_open_items where id = ar3) = 3700,
    'the items must carry the booking entry''s 3700');

  v_je := post_journal_entry(ta, 'manual', null, current_date, 'USD receivable booked today',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_ar,  'debit',  400, 'currency', 'USD', 'description', 'INV-USD-2'),
      jsonb_build_object('gl_account_id', g_rev, 'credit', 400, 'currency', 'USD', 'description', 'INV-USD-2')));
  e2 := v_je.id;
  ar2 := (fin_create_open_item_fx(ta, v_client, 'ar_control', 'test', null, 'INV-USD-2', current_date, null, 400,
                                 'USD 400 due', 'USD', e2)).id;

  v_je := post_journal_entry(ta, 'manual', null, current_date - 1, 'USD payable booked yesterday',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_exp, 'debit',  500, 'currency', 'USD', 'description', 'BILL-USD-1'),
      jsonb_build_object('gl_account_id', g_ap,  'credit', 500, 'currency', 'USD', 'description', 'BILL-USD-1')));
  e3 := v_je.id;
  ap1 := (fin_create_open_item_fx(ta, v_vendor, 'ap_control', 'test', null, 'BILL-USD-1', current_date - 1, null, 500,
                                 'USD 500 owed', 'USD', e3)).id;

  ar_ugx := (fin_create_open_item(ta, v_client, 'ar_control', 'test', null, 'INV-UGX-1', current_date, null, 700,
                                 'UGX 700 due')).id;
  raise notice 'PASS: foreign items carry the rate of the entry that booked them';

  -------------------------------------------------------------------
  -- 1. A USD credit note against the USD receivable: control at the booked
  --    rate, offset at the note-date rate, the difference a realised gain.
  -------------------------------------------------------------------
  set local role authenticated;
  cn := fin_raise_credit_note('ar_control', v_client, 1000, current_date, g_exp, pg_temp.a1(ar1, 1000), 'Premium cancelled in USD');
  reset role;
  perform pg_temp.assert(cn.currency = 'USD' and cn.fx_rate = 3800 and cn.realised_result = 100000,
    format('note must be USD at 3800 with a 100,000 gain, got %s @ %s result %s', cn.currency, cn.fx_rate, cn.realised_result));
  select * into r from pg_temp.net_of(g_ar, array[cn.id]);
  perform pg_temp.assert(r.ccy_net = -1000 and r.base_net = -3700000,
    format('the control side must be a USD 1,000 credit at 3700: %s', pg_temp.lines_of(cn.id)));
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
     where e.source_id = cn.id and l.gl_account_id = g_exp and l.debit = 1000 and l.currency = 'USD' and l.fx_rate = 3800),
    format('the offset side must be a USD 1,000 debit at the note-date 3800: %s', pg_temp.lines_of(cn.id)));
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
     where e.source_id = cn.id and l.gl_account_id = g_gain and l.credit = 100000 and l.currency = 'UGX'),
    format('a realised gain of UGX 100,000 must be booked: %s', pg_temp.lines_of(cn.id)));
  select coalesce(sum(base_debit - base_credit), 0) into v_bal from journal_entry_lines where journal_entry_id = cn.journal_entry_id;
  perform pg_temp.assert(v_bal = 0, format('the note must balance in base, got %s', v_bal));
  perform pg_temp.assert((select outstanding_amount from fin_open_item_balances where id = ar1) = 0,
    'the item must be fully credited');
  raise notice 'PASS: a USD note at a higher rate books a realised gain and nets the item to zero';

  -------------------------------------------------------------------
  -- 2. The rate rules in the guard.
  -------------------------------------------------------------------
  perform pg_temp.expect_error(format(
    'insert into fin_credit_notes (tenant_id, credit_note_no, side, control_role, party_account_id, offset_gl_account_id, amount, currency, fx_rate, credit_date, reason) values (%L, ''CRN-X'', ''receivable'', ''ar_control'', %L, %L, 1, ''USD'', 3700, current_date, ''wrong rate note'')',
    ta, v_client, g_exp),
    'CREDIT_NOTE_RATE', 'a foreign note at a stale rate');
  perform pg_temp.expect_error(format(
    'insert into fin_credit_notes (tenant_id, credit_note_no, side, control_role, party_account_id, offset_gl_account_id, amount, currency, fx_rate, realised_result, credit_date, reason) values (%L, ''CRN-Y'', ''receivable'', ''ar_control'', %L, %L, 1, ''UGX'', 2, 5, current_date, ''bad functional note'')',
    ta, v_client, g_exp),
    'CREDIT_NOTE_RATE', 'a functional note at rate 2 with a result');
  raise notice 'PASS: the guard enforces the approved note-date rate and the functional defaults';

  -------------------------------------------------------------------
  -- 3. Mixed-currency applications are refused and leave nothing behind.
  -------------------------------------------------------------------
  select count(*) into n from fin_credit_notes where tenant_id = ta;
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select fin_raise_credit_note(''ar_control'', %L, 800, current_date, %L, %L, ''mixed currencies'')', v_client, g_exp, pg_temp.a2(ar2, 100, ar_ugx, 700)),
    'CREDIT_NOTE_CURRENCY', 'a note across currencies');
  reset role;
  perform pg_temp.assert((select count(*) from fin_credit_notes where tenant_id = ta) = n,
    'a refused mixed-currency note must leave no rows');
  raise notice 'PASS: applications in two currencies are refused and leave nothing behind';

  -------------------------------------------------------------------
  -- 4. Two items booked at different rates: one control line per booking
  --    entry, the result on the totals.
  -------------------------------------------------------------------
  set local role authenticated;
  cn2 := fin_raise_credit_note('ar_control', v_client, 1000, current_date, g_exp, pg_temp.a2(ar2, 400, ar3, 600), 'Split USD credit');
  reset role;
  perform pg_temp.assert(cn2.realised_result = 60000,
    format('400 at 3800 and 600 at 3700 against 1000 at 3800 is a 60,000 gain, got %s', cn2.realised_result));
  select count(*) into n from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
   where e.source_id = cn2.id and l.gl_account_id = g_ar and l.credit > 0 and l.currency = 'USD';
  perform pg_temp.assert(n = 2, format('two booking entries must give two control lines, got %s', n));
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
     where e.source_id = cn2.id and l.gl_account_id = g_ar and l.credit = 600 and l.fx_rate = 3700),
    'the 600 portion must sit at its booking rate 3700');
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
     where e.source_id = cn2.id and l.gl_account_id = g_gain and l.credit = 60000),
    'the 60,000 gain must be booked');
  raise notice 'PASS: two booking rates give two control lines and the result lands on the totals';

  -------------------------------------------------------------------
  -- 5. The payable side mirrors the sign: a loss when the payable was
  --    booked cheaper than today's note rate.
  -------------------------------------------------------------------
  set local role authenticated;
  cn := fin_raise_credit_note('ap_control', v_vendor, 500, current_date, g_exp, pg_temp.a1(ap1, 500), 'Vendor bill cancelled in USD');
  reset role;
  perform pg_temp.assert(cn.currency = 'USD' and cn.realised_result = -50000,
    format('cancelling a payable booked at 3700 with a note at 3800 is a 50,000 loss, got %s', cn.realised_result));
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
     where e.source_id = cn.id and l.gl_account_id = g_loss and l.debit = 50000 and l.currency = 'UGX'),
    format('a realised loss of UGX 50,000 must be booked: %s', pg_temp.lines_of(cn.id)));
  raise notice 'PASS: the payable side books the mirrored loss';

  -------------------------------------------------------------------
  -- 6. A functional note is unchanged: rate 1, no result, UGX lines only.
  -------------------------------------------------------------------
  set local role authenticated;
  cn := fin_raise_credit_note('ar_control', v_client, 300, current_date, g_exp, pg_temp.a1(ar_ugx, 300), 'UGX note unchanged');
  reset role;
  perform pg_temp.assert(cn.currency = 'UGX' and cn.fx_rate = 1 and cn.realised_result = 0,
    'a functional note must stay at rate 1 with no realised result');
  perform pg_temp.assert(
    not exists (select 1 from journal_entry_lines where journal_entry_id = cn.journal_entry_id and currency <> 'UGX'),
    format('a functional note must post UGX lines only: %s', pg_temp.lines_of(cn.id)));
  raise notice 'PASS: functional-currency notes are unchanged line for line';

  -------------------------------------------------------------------
  -- 7. Voiding a foreign note reverses it exactly.
  -------------------------------------------------------------------
  set local role authenticated;
  v_void := fin_void_credit_note(cn2.id, 'Undoing the split USD credit');
  reset role;
  perform pg_temp.assert(v_void.status = 'void' and v_void.void_journal_entry_id is not null, 'the note must be void');
  select * into r from pg_temp.net_of(g_ar, array[cn2.id, v_void.void_journal_entry_id]);
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0,
    format('the note and its void must net to zero in USD and base, got %s / %s', r.ccy_net, r.base_net));
  select * into r from pg_temp.net_of(g_gain, array[cn2.id, v_void.void_journal_entry_id]);
  perform pg_temp.assert(r.base_net = 0, 'the realised gain must be undone');
  perform pg_temp.assert((select outstanding_amount from fin_open_item_balances where id = ar2) = 400
                     and (select outstanding_amount from fin_open_item_balances where id = ar3) = 600,
    'the items must be outstanding again');
  raise notice 'PASS: voiding a foreign note negates it exactly, realised line included';

  raise notice 'ALL PASS: foreign credit notes';
end
$$;

rollback;
