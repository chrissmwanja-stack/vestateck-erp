-- Workstream C functional test: bank reconciliation RPCs
-- (match_bank_statement_line, auto_match_bank_statement,
-- unmatch_bank_reconciliation).
--
-- Run against a fresh local stack only (`supabase start` in the
-- db-shadow-replay CI job, or `supabase db reset` locally). Everything
-- here is wrapped in one transaction that ROLLBACKs at the end, so it
-- leaves no fixture data behind -- see
-- test_gl_posting_and_period_close.sql's header for the same caveat
-- about sequence objects (none of the tables touched here use one, so
-- it doesn't apply, but the "don't run this against a linked/remote
-- project" rule still does).
--
-- Fails loudly: any RAISE EXCEPTION here is a real assertion failure
-- and should fail the CI step (psql -f exits non-zero on an uncaught
-- error).

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tenant_id uuid := gen_random_uuid();
  v_finance_user_id uuid := gen_random_uuid();
  v_outsider_user_id uuid := gen_random_uuid();
  v_line_id uuid;
  v_txn_id uuid;
  v_txn2_id uuid;
  v_recon_id uuid;
  v_recon record;
  v_matched_count integer;
  v_caught boolean;
begin
  -------------------------------------------------------------------
  -- Fixtures: one tenant, one finance-team auth user, one auth user
  -- with no finance_team_members row (for the authorization checks).
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_tenant_id, 'Bank Recon Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values
    ('00000000-0000-0000-0000-000000000000', v_finance_user_id, 'authenticated', 'authenticated',
     'bankrecon-fin-' || v_finance_user_id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''),
    ('00000000-0000-0000-0000-000000000000', v_outsider_user_id, 'authenticated', 'authenticated',
     'bankrecon-out-' || v_outsider_user_id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '');

  insert into app_users (id, tenant_id, name, email)
  values
    (v_finance_user_id, v_tenant_id, 'Bank Recon Finance User', 'bankrecon-fin-' || v_finance_user_id || '@test.local'),
    (v_outsider_user_id, v_tenant_id, 'Bank Recon Outsider User', 'bankrecon-out-' || v_outsider_user_id || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role)
  values (v_tenant_id, v_finance_user_id, 'finance');
  -- deliberately no finance_team_members row for v_outsider_user_id

  -------------------------------------------------------------------
  -- 0. Authorization: none of the three RPCs should be callable by a
  --    tenant member who isn't on the finance team.
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_outsider_user_id)::text, true);
  set local role authenticated;

  v_caught := false;
  begin
    perform match_bank_statement_line(gen_random_uuid(), gen_random_uuid());
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: match_bank_statement_line was NOT rejected for a non-finance user';
  end if;

  v_caught := false;
  begin
    perform auto_match_bank_statement('TEST-ACC', current_date - 30, current_date);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: auto_match_bank_statement was NOT rejected for a non-finance user';
  end if;

  v_caught := false;
  begin
    perform unmatch_bank_reconciliation(gen_random_uuid());
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: unmatch_bank_reconciliation was NOT rejected for a non-finance user';
  end if;

  raise notice 'PASS: all three RPCs correctly reject a non-finance-team caller';

  -- Switch to the finance user for the rest of the test.
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v_finance_user_id)::text, true);
  set local role authenticated;

  -------------------------------------------------------------------
  -- 1. Manual match: exact-amount match produces a zero-variance,
  --    match_type = 'manual' row.
  -------------------------------------------------------------------
  select id into v_line_id from import_bank_statement_lines(
    'ACC-001',
    jsonb_build_array(jsonb_build_object('statement_date', current_date, 'description', 'Customer deposit', 'amount', 50000))
  );

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    50000, current_date, 'ACC-001', 'Matching receipt'
  ) returning id into v_txn_id;

  select * into v_recon from match_bank_statement_line(v_line_id, v_txn_id);

  if v_recon.id is null then
    raise exception 'FAIL: match_bank_statement_line did not return a reconciliation row';
  end if;
  if v_recon.match_type != 'manual' then
    raise exception 'FAIL: manual match has match_type = %, expected manual', v_recon.match_type;
  end if;
  if v_recon.variance != 0 then
    raise exception 'FAIL: exact-amount manual match has nonzero variance %', v_recon.variance;
  end if;

  raise notice 'PASS: manual match of an exact-amount pair produces a zero-variance manual match';

  -------------------------------------------------------------------
  -- 2. Manual match rejects a cash-method transaction (only
  --    bank-method transactions can be reconciled against a
  --    statement).
  -------------------------------------------------------------------
  select id into v_line_id from import_bank_statement_lines(
    'ACC-001',
    jsonb_build_array(jsonb_build_object('statement_date', current_date, 'description', 'Unmatchable line', 'amount', 7500))
  );

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'cash', 'receivable_invoice', gen_random_uuid(),
    7500, current_date, null, 'Cash receipt, not bank'
  ) returning id into v_txn_id;

  v_caught := false;
  begin
    perform match_bank_statement_line(v_line_id, v_txn_id);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: matching against a cash-method transaction was NOT rejected';
  end if;

  raise notice 'PASS: manual match correctly rejects a cash-method transaction';

  -------------------------------------------------------------------
  -- 3. Manual match rejects a bank-account mismatch between the
  --    statement line and the transaction.
  -------------------------------------------------------------------
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    7500, current_date, 'ACC-002', 'Right amount, wrong account'
  ) returning id into v_txn_id;

  v_caught := false;
  begin
    perform match_bank_statement_line(v_line_id, v_txn_id);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: matching a statement line and transaction on different bank accounts was NOT rejected';
  end if;

  raise notice 'PASS: manual match correctly rejects a bank-account mismatch';

  -------------------------------------------------------------------
  -- 4. Manual match with mismatched amounts still succeeds but
  --    records a nonzero variance (a human deliberately force-matching
  --    e.g. a bank-charge difference) -- see the variance column
  --    comment in the migration.
  -------------------------------------------------------------------
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    7300, current_date, 'ACC-001', 'Close but not exact, bank charge assumed'
  ) returning id into v_txn_id;

  select * into v_recon from match_bank_statement_line(v_line_id, v_txn_id);

  if v_recon.match_type != 'manual' then
    raise exception 'FAIL: forced mismatched match has match_type = %, expected manual', v_recon.match_type;
  end if;
  if v_recon.variance != 200 then
    raise exception 'FAIL: forced mismatched match has variance %, expected 200 (7500 - 7300)', v_recon.variance;
  end if;

  raise notice 'PASS: manual match of a mismatched pair succeeds and records the correct nonzero variance';

  v_recon_id := v_recon.id;

  -------------------------------------------------------------------
  -- 5. Manual match rejects re-matching a statement line (or
  --    transaction) that's already matched -- the two unique
  --    constraints on bank_reconciliations.
  -------------------------------------------------------------------
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    7500, current_date, 'ACC-001', 'Another candidate for an already-matched line'
  ) returning id into v_txn_id;

  v_caught := false;
  begin
    perform match_bank_statement_line(v_line_id, v_txn_id);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: matching an already-matched statement line was NOT rejected';
  end if;

  raise notice 'PASS: manual match correctly rejects an already-matched statement line';

  -------------------------------------------------------------------
  -- 6. unmatch_bank_reconciliation removes the match and frees both
  --    sides up to be matched again.
  -------------------------------------------------------------------
  perform unmatch_bank_reconciliation(v_recon_id);

  if exists (select 1 from bank_reconciliations where id = v_recon_id) then
    raise exception 'FAIL: unmatch_bank_reconciliation did not delete the reconciliation row';
  end if;

  -- The statement line from step 4 (v_line_id) should now be
  -- re-matchable against a fresh exact-amount transaction.
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    7500, current_date, 'ACC-001', 'Re-match after unmatch'
  ) returning id into v_txn_id;

  select * into v_recon from match_bank_statement_line(v_line_id, v_txn_id);
  if v_recon.id is null then
    raise exception 'FAIL: statement line could not be re-matched after unmatch_bank_reconciliation';
  end if;

  raise notice 'PASS: unmatch_bank_reconciliation frees the statement line to be matched again';

  -------------------------------------------------------------------
  -- 7. unmatch_bank_reconciliation on a nonexistent id is rejected.
  -------------------------------------------------------------------
  v_caught := false;
  begin
    perform unmatch_bank_reconciliation(gen_random_uuid());
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'FAIL: unmatch_bank_reconciliation on a nonexistent id was NOT rejected';
  end if;

  raise notice 'PASS: unmatch_bank_reconciliation correctly rejects a nonexistent reconciliation id';

  -------------------------------------------------------------------
  -- 8. auto_match_bank_statement: exactly one candidate -> auto-match
  --    with match_type = 'auto' and variance = 0.
  -------------------------------------------------------------------
  select id into v_line_id from import_bank_statement_lines(
    'ACC-AUTO',
    jsonb_build_array(jsonb_build_object('statement_date', current_date, 'description', 'Single unambiguous candidate', 'amount', 12345))
  );

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    12345, current_date - 2, 'ACC-AUTO', 'The one candidate, 2 days earlier'
  ) returning id into v_txn_id;

  v_matched_count := auto_match_bank_statement('ACC-AUTO', current_date - 10, current_date + 10);

  if v_matched_count != 1 then
    raise exception 'FAIL: auto_match_bank_statement matched % lines, expected 1 for the unambiguous case', v_matched_count;
  end if;

  select * into v_recon from bank_reconciliations where bank_statement_line_id = v_line_id;
  if v_recon.id is null then
    raise exception 'FAIL: auto_match_bank_statement reported a match but created no reconciliation row';
  end if;
  if v_recon.match_type != 'auto' then
    raise exception 'FAIL: auto-matched row has match_type = %, expected auto', v_recon.match_type;
  end if;
  if v_recon.variance != 0 then
    raise exception 'FAIL: auto-matched row has nonzero variance %', v_recon.variance;
  end if;
  if v_recon.cash_bank_transaction_id != v_txn_id then
    raise exception 'FAIL: auto-matched row points at the wrong transaction';
  end if;

  raise notice 'PASS: auto_match_bank_statement matches an unambiguous single candidate';

  -------------------------------------------------------------------
  -- 9. auto_match_bank_statement: zero candidates (amount doesn't
  --    match anything) -> left unmatched, matched count 0.
  -------------------------------------------------------------------
  select id into v_line_id from import_bank_statement_lines(
    'ACC-AUTO',
    jsonb_build_array(jsonb_build_object('statement_date', current_date, 'description', 'No candidate exists for this amount', 'amount', 999111))
  );

  v_matched_count := auto_match_bank_statement('ACC-AUTO', current_date - 10, current_date + 10);

  if v_matched_count != 0 then
    raise exception 'FAIL: auto_match_bank_statement matched % lines when no candidate should exist', v_matched_count;
  end if;
  if exists (select 1 from bank_reconciliations where bank_statement_line_id = v_line_id) then
    raise exception 'FAIL: a statement line with no matching amount was matched anyway';
  end if;

  raise notice 'PASS: auto_match_bank_statement leaves a zero-candidate line unmatched';

  -------------------------------------------------------------------
  -- 10. auto_match_bank_statement: two equally-plausible candidates
  --     (same amount, both within the date window) -> ambiguous, so
  --     the pass must leave it for a human rather than guess.
  -------------------------------------------------------------------
  select id into v_line_id from import_bank_statement_lines(
    'ACC-AUTO',
    jsonb_build_array(jsonb_build_object('statement_date', current_date, 'description', 'Ambiguous: two equally good candidates', 'amount', 44000))
  );

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    44000, current_date - 1, 'ACC-AUTO', 'Ambiguous candidate 1'
  ) returning id into v_txn_id;

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, transaction_date, bank_account, description
  ) values (
    v_tenant_id, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    44000, current_date - 3, 'ACC-AUTO', 'Ambiguous candidate 2'
  ) returning id into v_txn2_id;

  v_matched_count := auto_match_bank_statement('ACC-AUTO', current_date - 10, current_date + 10);

  if v_matched_count != 0 then
    raise exception 'FAIL: auto_match_bank_statement matched % lines for an ambiguous (2-candidate) case, expected 0', v_matched_count;
  end if;
  if exists (select 1 from bank_reconciliations where bank_statement_line_id = v_line_id) then
    raise exception 'FAIL: an ambiguous statement line was auto-matched instead of left for a human';
  end if;
  if exists (select 1 from bank_reconciliations where cash_bank_transaction_id in (v_txn_id, v_txn2_id)) then
    raise exception 'FAIL: an ambiguous candidate transaction was auto-matched instead of left for a human';
  end if;

  raise notice 'PASS: auto_match_bank_statement correctly refuses to guess between two ambiguous candidates';

  -------------------------------------------------------------------
  -- 11. auto_match_bank_statement excludes already-matched lines and
  --     transactions from consideration (re-running the pass is a
  --     no-op for pairs already resolved).
  -------------------------------------------------------------------
  v_matched_count := auto_match_bank_statement('ACC-AUTO', current_date - 10, current_date + 10);
  if v_matched_count != 0 then
    raise exception 'FAIL: re-running auto_match_bank_statement matched % lines, expected 0 (nothing new to match)', v_matched_count;
  end if;

  raise notice 'PASS: auto_match_bank_statement is a no-op on a re-run with no new unmatched pairs';

  raise notice 'ALL BANK RECONCILIATION RPC TESTS PASSED';
end $$;

rollback;
