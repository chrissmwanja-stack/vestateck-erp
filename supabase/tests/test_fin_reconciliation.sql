-- D4d-1 functional test: reconciling fin_settlements against bank statement lines.
--
-- Covers: manual and auto matching of settlements, auto-match refusing to guess
-- (same pool and across pools), the possible-double-entry view, rule filters
-- (bank account, status, direction), the void guard (reconciled settlements
-- cannot be voided until unmatched), the one-source check and uniqueness, the
-- variance view for settlement rows, the reconciliation position, company
-- isolation, and grants.
--
-- Run against a fresh local stack only (`supabase start` / `supabase db reset`).
-- Everything runs in one transaction that ROLLBACKs, so no fixture data is left
-- behind; any RAISE EXCEPTION is a real assertion failure and makes psql exit
-- non-zero (same convention as the other files in this directory).

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

-- Owner-side readers so assertions do not depend on the caller's RLS.
create function pg_temp.line_id(p_tenant uuid, p_amount numeric) returns uuid
language sql security definer as $$
  select id from public.bank_statement_lines where tenant_id = p_tenant and amount = p_amount
$$;
create function pg_temp.settle_id(p_tenant uuid, p_no text) returns uuid
language sql security definer as $$
  select id from public.fin_settlements where tenant_id = p_tenant and settlement_no = p_no
$$;
create function pg_temp.recon_count(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.bank_reconciliations where tenant_id = p_tenant
$$;

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_fin_a uuid := gen_random_uuid();
  v_out_a uuid := gen_random_uuid();
  v_fin_b uuid := gen_random_uuid();

  v_gl_trust uuid; v_gl_bank uuid; v_gl_ar uuid; v_gl_trust_b uuid;
  v_client uuid;
  v_trust uuid; v_ops uuid;
  v_ar1 uuid; v_ar2 uuid; v_ar3 uuid; v_ar4 uuid; v_ar5 uuid; v_ar6 uuid; v_ar7 uuid;

  v_s1 fin_settlements%rowtype; v_s2 fin_settlements%rowtype; v_s3 fin_settlements%rowtype;
  v_s4 fin_settlements%rowtype; v_s5 fin_settlements%rowtype; v_s6 fin_settlements%rowtype;
  v_s7 fin_settlements%rowtype;
  v_rec bank_reconciliations%rowtype;
  v_n integer;
  v_pos record;
  v_cash uuid;
  v_gl_before numeric;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Recon Co A'), (v_tb, 'Recon Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'finrecon-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_fin_a), (v_out_a), (v_fin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (v_fin_a, v_ta, 'Recon Finance A', 'finrecon-' || v_fin_a || '@test.local'),
    (v_out_a, v_ta, 'Recon Outsider A', 'finrecon-' || v_out_a || '@test.local'),
    (v_fin_b, v_tb, 'Recon Finance B', 'finrecon-' || v_fin_b || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, v_fin_a, 'finance'),
    (v_tb, v_fin_b, 'finance');
  -- v_out_a is deliberately not on the finance team.

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank', 'asset') returning id into v_gl_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1200', 'Receivables', 'asset') returning id into v_gl_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '1020', 'Client Money Bank', 'asset') returning id into v_gl_trust_b;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', v_gl_bank),
    (v_ta, 'client_money_bank', v_gl_trust),
    (v_ta, 'ar_control', v_gl_ar);

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_ta, 'C-001', 'Recon Client', 'client') returning id into v_client;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_ta, 'TRUST-UGX', 'client_money', 'UGX', v_gl_trust) returning id into v_trust;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_ta, 'OPS-UGX', 'operating', 'UGX', v_gl_bank) returning id into v_ops;
  reset role;

  v_ar1 := (fin_create_open_item(v_ta, v_client, 'ar_control', 'test', null, 'INV-1', current_date, null, 1000)).id;
  v_ar2 := (fin_create_open_item(v_ta, v_client, 'ar_control', 'test', null, 'INV-2', current_date, null, 400)).id;
  v_ar3 := (fin_create_open_item(v_ta, v_client, 'ar_control', 'test', null, 'INV-3', current_date, null, 300)).id;
  v_ar4 := (fin_create_open_item(v_ta, v_client, 'ar_control', 'test', null, 'INV-4', current_date, null, 300)).id;
  v_ar5 := (fin_create_open_item(v_ta, v_client, 'ar_control', 'test', null, 'INV-5', current_date, null, 250)).id;
  v_ar6 := (fin_create_open_item(v_ta, v_client, 'ar_control', 'test', null, 'INV-6', current_date, null, 500)).id;
  v_ar7 := (fin_create_open_item(v_ta, v_client, 'ar_control', 'test', null, 'INV-7', current_date, null, 90)).id;

  -- Settlements, recorded as the finance user.
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_s1 := fin_record_settlement(v_trust, 'in', v_client, 1000, current_date, jsonb_build_array(jsonb_build_object('open_item_id', v_ar1, 'amount', 1000)));
  v_s2 := fin_record_settlement(v_trust, 'in', v_client,  400, current_date, jsonb_build_array(jsonb_build_object('open_item_id', v_ar2, 'amount', 400)));
  v_s3 := fin_record_settlement(v_trust, 'in', v_client,  300, current_date, jsonb_build_array(jsonb_build_object('open_item_id', v_ar3, 'amount', 300)));
  v_s4 := fin_record_settlement(v_trust, 'in', v_client,  300, current_date, jsonb_build_array(jsonb_build_object('open_item_id', v_ar4, 'amount', 300)));
  v_s5 := fin_record_settlement(v_trust, 'in', v_client,  250, current_date, jsonb_build_array(jsonb_build_object('open_item_id', v_ar5, 'amount', 250)));
  v_s6 := fin_record_settlement(v_trust, 'in', v_client,  500, current_date, jsonb_build_array(jsonb_build_object('open_item_id', v_ar6, 'amount', 500)));
  -- Same bank-account name does not exist on OPS-UGX, so this one is a different bank account.
  v_s7 := fin_record_settlement(v_ops,   'in', v_client,   90, current_date, jsonb_build_array(jsonb_build_object('open_item_id', v_ar7, 'amount', 90)));

  -- Statement lines (import as the finance user).
  perform import_bank_statement_lines('TRUST-UGX', jsonb_build_array(
    jsonb_build_object('statement_date', current_date + 1, 'amount', 1000, 'description', 'deposit 1000'),
    jsonb_build_object('statement_date', current_date + 1, 'amount',  400, 'description', 'deposit 400'),
    jsonb_build_object('statement_date', current_date + 1, 'amount',  300, 'description', 'deposit 300 (ambiguous)'),
    jsonb_build_object('statement_date', current_date + 1, 'amount',  250, 'description', 'deposit 250 (double entry)'),
    jsonb_build_object('statement_date', current_date + 1, 'amount',  495, 'description', 'deposit 495 (short paid)'),
    jsonb_build_object('statement_date', current_date + 1, 'amount',  -30, 'description', 'bank charge'),
    jsonb_build_object('statement_date', current_date + 1, 'amount',   90, 'description', 'deposit 90 on trust (settlement is on OPS)')
  ));
  reset role;

  -------------------------------------------------------------------
  -- 0. Authorization and grants
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_out_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select match_bank_statement_line_to_settlement(%L, %L)', pg_temp.line_id(v_ta, 1000), v_s1.id),
    'not authorized', 'non-finance user matching a settlement');
  reset role;

  if has_function_privilege('anon', 'public.match_bank_statement_line_to_settlement(uuid, uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.fin_bank_reconciliation_position(uuid, date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.fin_bank_line_candidates(uuid, uuid)', 'EXECUTE') then
    raise exception 'FAIL: anon can execute a D4d-1 function';
  end if;
  raise notice 'PASS: authorization and grants';

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -------------------------------------------------------------------
  -- 1. Manual match of a line to a settlement
  -------------------------------------------------------------------
  v_rec := match_bank_statement_line_to_settlement(pg_temp.line_id(v_ta, 1000), v_s1.id);
  if v_rec.settlement_id is distinct from v_s1.id or v_rec.cash_bank_transaction_id is not null
     or v_rec.match_type <> 'manual' or v_rec.variance <> 0 then
    raise exception 'FAIL: manual settlement match wrong (%)', to_jsonb(v_rec);
  end if;
  raise notice 'PASS: manual match of a line to a settlement';

  -- Wrong bank account (settlement is on OPS-UGX, line is on TRUST-UGX).
  perform pg_temp.expect_error(
    format('select match_bank_statement_line_to_settlement(%L, %L)', pg_temp.line_id(v_ta, 90), v_s7.id),
    'different bank accounts', 'settlement on another bank account');
  -- Same settlement twice, same line twice.
  perform pg_temp.expect_error(
    format('select match_bank_statement_line_to_settlement(%L, %L)', pg_temp.line_id(v_ta, 400), v_s1.id),
    'already reconciled', 'settlement already matched');
  perform pg_temp.expect_error(
    format('select match_bank_statement_line_to_settlement(%L, %L)', pg_temp.line_id(v_ta, 1000), v_s2.id),
    'already reconciled', 'line already matched');
  raise notice 'PASS: wrong account and double matching are refused';

  -------------------------------------------------------------------
  -- 2. Void guard (decision B)
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format('select fin_void_settlement(%L, ''entered the wrong amount'')', v_s1.id),
    'unmatch it first', 'void of a reconciled settlement');
  if (select status from fin_settlements where id = v_s1.id) <> 'posted' then
    raise exception 'FAIL: refused void still changed the settlement';
  end if;
  raise notice 'PASS: reconciled settlement cannot be voided';

  -------------------------------------------------------------------
  -- 3. Unmatch, then void works; a void settlement cannot be matched
  -------------------------------------------------------------------
  perform unmatch_bank_reconciliation(v_rec.id);
  perform fin_void_settlement(v_s1.id, 'entered the wrong amount');
  if (select status from fin_settlements where id = v_s1.id) <> 'void' then
    raise exception 'FAIL: unmatched settlement could not be voided';
  end if;
  perform pg_temp.expect_error(
    format('select match_bank_statement_line_to_settlement(%L, %L)', pg_temp.line_id(v_ta, 1000), v_s1.id),
    'only posted settlements', 'matching a void settlement');
  raise notice 'PASS: unmatch then void; void settlements cannot be matched';

  -------------------------------------------------------------------
  -- 4. Auto-match: one candidate matches; ambiguity is left alone
  -------------------------------------------------------------------
  -- Candidates: 400 -> S2 only. 300 -> S3 and S4 (ambiguous). 250 -> S5 only for now.
  -- 495 and -30 have no equal-amount candidate. 90 has no TRUST-UGX candidate.
  select auto_match_bank_statement('TRUST-UGX', current_date - 10, current_date + 10) into v_n;
  if v_n <> 2 then
    raise exception 'FAIL: auto-match should match 400 and 250 only, matched %', v_n;
  end if;
  select * into v_rec from bank_reconciliations where bank_statement_line_id = pg_temp.line_id(v_ta, 400);
  if v_rec.settlement_id is distinct from v_s2.id or v_rec.match_type <> 'auto' or v_rec.variance <> 0 then
    raise exception 'FAIL: auto-match of 400 wrong (%)', to_jsonb(v_rec);
  end if;
  if exists (select 1 from bank_reconciliations where bank_statement_line_id = pg_temp.line_id(v_ta, 300)) then
    raise exception 'FAIL: auto-match guessed between two equal settlements';
  end if;
  raise notice 'PASS: auto-match matches a single settlement candidate and refuses to guess between two';

  -- Re-run is a no-op.
  select auto_match_bank_statement('TRUST-UGX', current_date - 10, current_date + 10) into v_n;
  if v_n <> 0 then raise exception 'FAIL: auto-match re-run matched % more', v_n; end if;

  -------------------------------------------------------------------
  -- 5. Possible double entry: same movement as a bank cash txn AND a settlement
  -------------------------------------------------------------------
  -- Undo the auto-match of 250 so it is open again, then add a bank cash receipt for 250.
  perform unmatch_bank_reconciliation((select id from bank_reconciliations where settlement_id = v_s5.id));
  reset role;
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, currency, transaction_date, bank_account, description, recorded_by
  ) values (
    v_ta, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    250, 'UGX', current_date, 'TRUST-UGX', 'duplicate of settlement', v_fin_a
  ) returning id into v_cash;
  set local role authenticated;

  select auto_match_bank_statement('TRUST-UGX', current_date - 10, current_date + 10) into v_n;
  if v_n <> 0 then
    raise exception 'FAIL: auto-match must leave a cross-pool double candidate for a human, matched %', v_n;
  end if;
  select count(*) into v_n from v_bank_possible_double_entries where statement_line_id = pg_temp.line_id(v_ta, 250);
  if v_n <> 1 then raise exception 'FAIL: cross-pool double candidate not flagged'; end if;
  select count(*) into v_n from v_bank_possible_double_entries where statement_line_id = pg_temp.line_id(v_ta, 300);
  if v_n <> 0 then raise exception 'FAIL: same-pool ambiguity must not be flagged as a double entry'; end if;
  raise notice 'PASS: cross-pool double candidates are left for a human and flagged';

  -- A human resolves it by matching the settlement; the flag clears.
  perform match_bank_statement_line_to_settlement(pg_temp.line_id(v_ta, 250), v_s5.id);
  select count(*) into v_n from v_bank_possible_double_entries;
  if v_n <> 0 then raise exception 'FAIL: flag did not clear after matching'; end if;

  -------------------------------------------------------------------
  -- 6. Legacy cash/bank match still works and shares the one-source rule
  -------------------------------------------------------------------
  -- The cash receipt is now an unmatched book item with no statement line left; match it
  -- against a fresh line to prove the legacy path is intact.
  reset role;
  insert into bank_statement_lines (tenant_id, bank_account, statement_date, amount, currency)
  values (v_ta, 'TRUST-UGX', current_date + 1, 250, 'UGX');
  set local role authenticated;
  v_rec := match_bank_statement_line((select id from bank_statement_lines where tenant_id = v_ta and amount = 250 and id <> pg_temp.line_id(v_ta, 250) limit 1), v_cash);
  if v_rec.cash_bank_transaction_id is distinct from v_cash or v_rec.settlement_id is not null then
    raise exception 'FAIL: legacy match row wrong (%)', to_jsonb(v_rec);
  end if;
  raise notice 'PASS: legacy cash/bank matching unchanged';

  -------------------------------------------------------------------
  -- 7. One-source check
  -------------------------------------------------------------------
  reset role;
  perform pg_temp.expect_error(
    format('insert into bank_reconciliations (tenant_id, bank_statement_line_id) values (%L, %L)', v_ta, pg_temp.line_id(v_ta, 495)),
    'bank_reconciliations_one_source_check', 'row with neither source');
  perform pg_temp.expect_error(
    format('insert into bank_reconciliations (tenant_id, bank_statement_line_id, cash_bank_transaction_id, settlement_id) values (%L, %L, %L, %L)',
           v_ta, pg_temp.line_id(v_ta, 495), v_cash, v_s6.id),
    'bank_reconciliations_one_source_check', 'row with both sources');
  raise notice 'PASS: a reconciliation has exactly one source';

  -------------------------------------------------------------------
  -- 8. Variance view includes settlement rows
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform match_bank_statement_line_to_settlement(pg_temp.line_id(v_ta, 495), v_s6.id);
  select * into v_pos from v_bank_reconciliation_variance where settlement_id = v_s6.id;
  if not found or v_pos.source <> 'settlement' or v_pos.variance <> -5
     or v_pos.transaction_amount <> 500 or v_pos.statement_amount <> 495 or v_pos.transaction_type <> 'receipt' then
    raise exception 'FAIL: variance view row wrong (%)', to_jsonb(v_pos);
  end if;
  raise notice 'PASS: variance view reports settlement matches';

  -------------------------------------------------------------------
  -- 9. Reconciliation position
  -------------------------------------------------------------------
  -- State: settlements on TRUST: S1 void (net 0), S2 400 matched, S3 300 open, S4 300 open,
  -- S5 250 matched, S6 500 matched. Cash receipt 250 matched. Statement lines on TRUST:
  -- 1000 open (its settlement was voided), 400 m, 300 open, 250 m, 250 m (cash), 495 m,
  -- -30 open, 90 open.
  -- Add a manual journal of +70 straight to the trust GL account: reconciliation cannot see it.
  reset role;
  perform post_journal_entry(v_ta, 'manual', gen_random_uuid(), current_date, 'Manual journal to the trust account',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_gl_trust, 'debit', 70),
      jsonb_build_object('gl_account_id', v_gl_ar, 'credit', 70)));
  set constraints all immediate;
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- GL: 400 + 300 + 300 + 250 + 500 + 70 = 1820 (S1 and its void net to 0).
  -- Book unmatched: S3 300 + S4 300 = 600.
  -- Statement unmatched: 1000 + 300 - 30 + 90 = 1360.
  -- Expected closing: 1820 - 600 + 1360 = 2580.
  -- Unexplained: GL 1820 - visible book (S2 400 + S3 300 + S4 300 + S5 250 + S6 500 + cash 250 = 2000) = -180.
  -- (The cash receipt has no GL journal in this fixture, so it is visible to reconciliation but
  --  not in the GL; that is exactly the kind of gap the unexplained line surfaces: 70 - 250 = -180.)
  for v_pos in select * from fin_bank_reconciliation_position(v_trust, current_date + 5) loop
    if v_pos.component = 'gl_balance' and v_pos.amount <> 1820 then raise exception 'FAIL: gl_balance % (want 1820)', v_pos.amount; end if;
    if v_pos.component = 'unmatched_book_items' and v_pos.amount <> 600 then raise exception 'FAIL: unmatched_book_items % (want 600)', v_pos.amount; end if;
    if v_pos.component = 'unmatched_statement_lines' and v_pos.amount <> 1360 then raise exception 'FAIL: unmatched_statement_lines % (want 1360)', v_pos.amount; end if;
    if v_pos.component = 'expected_statement_balance' and v_pos.amount <> 2580 then raise exception 'FAIL: expected_statement_balance % (want 2580)', v_pos.amount; end if;
    if v_pos.component = 'unexplained_difference' and v_pos.amount <> -180 then raise exception 'FAIL: unexplained_difference % (want -180)', v_pos.amount; end if;
  end loop;
  select count(*) into v_n from fin_bank_reconciliation_position(v_trust, current_date + 5);
  if v_n <> 5 then raise exception 'FAIL: position should have 5 lines, got %', v_n; end if;

  -- As of a date before anything happened, everything is zero.
  select amount into v_pos from fin_bank_reconciliation_position(v_trust, current_date - 30) where component = 'gl_balance';
  if v_pos.amount <> 0 then raise exception 'FAIL: gl_balance as of an early date should be 0'; end if;
  raise notice 'PASS: reconciliation position components and unexplained difference';

  -------------------------------------------------------------------
  -- 10. Company isolation
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select match_bank_statement_line_to_settlement(%L, %L)', pg_temp.line_id(v_ta, 300), v_s3.id),
    'statement line not found', 'cross-company match');
  perform pg_temp.expect_error(
    format('select * from fin_bank_reconciliation_position(%L)', v_trust),
    'bank account not found', 'cross-company position');
  select count(*) into v_n from v_bank_possible_double_entries;
  if v_n <> 0 then raise exception 'FAIL: other company sees double-entry flags'; end if;
  raise notice 'PASS: companies are isolated';

  reset role;
  raise notice 'ALL FIN_RECONCILIATION TESTS PASSED';
end $$;

rollback;