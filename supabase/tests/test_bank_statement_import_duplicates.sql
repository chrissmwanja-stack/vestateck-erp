-- Bank statement import: duplicate preview, skip-duplicates batch import.
-- (preview_bank_statement_import, import_bank_statement_batch,
-- bank_statement_lines.import_batch_id; migration 20261119090000.)
--
-- Covers: a first import is never flagged, including a statement that holds
-- two genuinely identical lines; re-importing the same file flags every line;
-- repeats are counted (two on file cover only the first two of three
-- identical lines); matching ignores case and surrounding spaces; skip mode
-- imports only what is new and reports imported/skipped; the default mode
-- still imports everything; one call tags its lines with one batch id; the
-- same lines on another account or in another company are not "already
-- imported"; a bad currency refuses the whole file and writes nothing; a
-- caller outside the finance team is refused; anon cannot execute either
-- function; the legacy import_bank_statement_lines is unchanged.
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

-- Number of incoming lines the preview flags as already imported.
create function pg_temp.flagged(p_account text, p_lines jsonb)
returns integer language sql as $$
  select count(*)::integer from preview_bank_statement_import(p_account, p_lines) where already_imported
$$;

create function pg_temp.line(p_date date, p_desc text, p_ref text, p_amount numeric)
returns jsonb language sql as $$
  select jsonb_build_object('statement_date', p_date, 'description', p_desc,
                            'reference', p_ref, 'amount', p_amount)
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  u  uuid := gen_random_uuid();   -- finance, company A
  ub uuid := gen_random_uuid();   -- finance, company B
  outsider uuid := gen_random_uuid();
  g_a uuid; g_b uuid;
  d1 date := current_date - 10;
  d2 date := current_date - 9;
  charge jsonb; salary jsonb; fresh jsonb;
  file1 jsonb; file2 jsonb;
  r jsonb; r2 jsonb;
  n integer; before_n integer;
  b1 uuid;
begin
  -------------------------------------------------------------------
  -- Fixtures: two companies, each with a finance user and a registered
  -- UGX bank account called BK-1; plus a non-finance user in company A.
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Stmt Dup Co A'), (tb, 'Stmt Dup Co B');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'sdi-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (u), (ub), (outsider)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (u,        ta, 'SDI Finance A',  'sdi-' || u        || '@test.local'),
    (ub,       tb, 'SDI Finance B',  'sdi-' || ub       || '@test.local'),
    (outsider, ta, 'SDI Outsider',   'sdi-' || outsider || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, u, 'finance'), (tb, ub, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank A', 'asset'), (tb, '1000', 'Bank B', 'asset');
  select id into g_a from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into g_b from gl_accounts where tenant_id = tb and account_code = '1000';
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta, 'BK-1', 'operating', 'UGX', g_a), (ta, 'BK-2', 'operating', 'UGX', g_a),
    (tb, 'BK-1', 'operating', 'UGX', g_b);

  charge := pg_temp.line(d1, 'SMS CHARGE', 'FEE01', -500);
  salary := pg_temp.line(d2, 'SALARY PYMT', 'REF001', -1674500);
  fresh  := pg_temp.line(d2, 'NEW RECEIPT', 'RCP9', 250000);
  -- A statement with two genuinely identical charge lines, plus a salary line.
  file1 := jsonb_build_array(charge, charge, salary);

  perform pg_temp.jwt(u);
  set local role authenticated;

  -------------------------------------------------------------------
  -- 1. First import: nothing is flagged, even with two identical lines.
  -------------------------------------------------------------------
  perform pg_temp.assert(pg_temp.flagged('BK-1', file1) = 0,
    'a first import flags nothing, including two identical lines in one file');

  r := import_bank_statement_batch('BK-1', file1);
  perform pg_temp.assert((r ->> 'imported')::int = 3 and (r ->> 'skipped')::int = 0,
    'default mode imports every line and skips none');
  perform pg_temp.assert((r ->> 'import_batch_id') is not null, 'the batch id is returned');
  b1 := (r ->> 'import_batch_id')::uuid;
  perform pg_temp.assert(
    (select count(*) from bank_statement_lines where bank_account = 'BK-1' and import_batch_id = b1) = 3,
    'all three lines carry the batch id of the call that created them');

  -------------------------------------------------------------------
  -- 2. Re-importing the same file flags every line.
  -------------------------------------------------------------------
  perform pg_temp.assert(pg_temp.flagged('BK-1', file1) = 3,
    'the same file imported again is flagged line for line (the two identical charges are both covered)');

  -------------------------------------------------------------------
  -- 3. Repeats are counted: two charges on file cover only the first two
  --    of three identical charges.
  -------------------------------------------------------------------
  file2 := jsonb_build_array(charge, charge, charge);
  perform pg_temp.assert(pg_temp.flagged('BK-1', file2) = 2,
    'two identical lines on file cover the first two of three, not all three');
  perform pg_temp.assert(
    (select already_imported from preview_bank_statement_import('BK-1', file2) where line_no = 3) = false,
    'the third identical line is the new one');

  -------------------------------------------------------------------
  -- 4. Matching ignores case and surrounding spaces.
  -------------------------------------------------------------------
  perform pg_temp.assert(
    pg_temp.flagged('BK-1', jsonb_build_array(pg_temp.line(d2, '  salary pymt ', ' ref001', -1674500))) = 1,
    'description and reference match regardless of case and surrounding spaces');
  perform pg_temp.assert(
    pg_temp.flagged('BK-1', jsonb_build_array(pg_temp.line(d2, 'SALARY PYMT', 'REF001', -1674501))) = 0,
    'a different amount is a different line');
  perform pg_temp.assert(
    pg_temp.flagged('BK-1', jsonb_build_array(pg_temp.line(d2 + 1, 'SALARY PYMT', 'REF001', -1674500))) = 0,
    'a different date is a different line');

  -------------------------------------------------------------------
  -- 5. Skip mode: a file of the three known lines plus one new line
  --    imports only the new one and reports what it skipped.
  -------------------------------------------------------------------
  select count(*) into before_n from bank_statement_lines where bank_account = 'BK-1';
  r2 := import_bank_statement_batch('BK-1', file1 || jsonb_build_array(fresh), true);
  perform pg_temp.assert((r2 ->> 'imported')::int = 1 and (r2 ->> 'skipped')::int = 3,
    'skip mode imports only the new line and reports 3 skipped');
  select count(*) into n from bank_statement_lines where bank_account = 'BK-1';
  perform pg_temp.assert(n = before_n + 1, 'skip mode wrote exactly one new line');
  perform pg_temp.assert((r2 ->> 'import_batch_id')::uuid <> b1, 'each call gets its own batch id');

  -- Skipping everything is not an error.
  r2 := import_bank_statement_batch('BK-1', file1, true);
  perform pg_temp.assert((r2 ->> 'imported')::int = 0 and (r2 ->> 'skipped')::int = 3,
    'a file that is entirely already imported imports nothing and does not fail');

  -- Skip mode also works for a repeat count: three charges, two on file.
  select count(*) into before_n from bank_statement_lines where bank_account = 'BK-1';
  r2 := import_bank_statement_batch('BK-1', file2, true);
  perform pg_temp.assert((r2 ->> 'imported')::int = 1 and (r2 ->> 'skipped')::int = 2,
    'skip mode with a repeat count imports the one extra charge');

  -------------------------------------------------------------------
  -- 6. Default mode is explicit "import everything": nothing is skipped
  --    even when the lines are already on file.
  -------------------------------------------------------------------
  select count(*) into before_n from bank_statement_lines where bank_account = 'BK-1';
  r2 := import_bank_statement_batch('BK-1', file1);
  perform pg_temp.assert((r2 ->> 'imported')::int = 3 and (r2 ->> 'skipped')::int = 0,
    'without skip_duplicates the lines are imported again (a deliberate override)');
  select count(*) into n from bank_statement_lines where bank_account = 'BK-1';
  perform pg_temp.assert(n = before_n + 3, 'the override wrote three lines');

  -------------------------------------------------------------------
  -- 7. Scope: another account in the same company, and another company
  --    with an account of the same name, are not "already imported".
  -------------------------------------------------------------------
  perform pg_temp.assert(pg_temp.flagged('BK-2', file1) = 0,
    'the same lines on a different bank account are new');
  reset role;
  perform pg_temp.jwt(ub);
  set local role authenticated;
  perform pg_temp.assert(pg_temp.flagged('BK-1', file1) = 0,
    'company B does not see company A''s lines as already imported');
  r2 := import_bank_statement_batch('BK-1', file1, true);
  perform pg_temp.assert((r2 ->> 'imported')::int = 3 and (r2 ->> 'skipped')::int = 0,
    'company B imports the same file in full');
  reset role;
  perform pg_temp.assert(
    (select count(*) from bank_statement_lines where tenant_id = tb) = 3,
    'company B holds exactly its own three lines');

  -------------------------------------------------------------------
  -- 8. A wrong currency refuses the whole file and writes nothing.
  -------------------------------------------------------------------
  perform pg_temp.jwt(u);
  set local role authenticated;
  select count(*) into before_n from bank_statement_lines where tenant_id = ta;
  perform pg_temp.expect_error(
    format($f$select import_bank_statement_batch('BK-1', %L::jsonb)$f$,
      jsonb_build_array(pg_temp.line(d1, 'OK LINE', 'X1', 100),
        jsonb_build_object('statement_date', d1, 'amount', 5, 'currency', 'USD'))::text),
    'BANK_STMT_CURRENCY', 'a USD line on a UGX account');
  select count(*) into n from bank_statement_lines where tenant_id = ta;
  perform pg_temp.assert(n = before_n, 'the refused file left no lines behind, not even the good one');

  perform pg_temp.expect_error(
    $f$select import_bank_statement_batch('BK-1', '[]'::jsonb)$f$,
    'at least one statement line', 'an empty file');
  perform pg_temp.expect_error(
    $f$select import_bank_statement_batch('  ', '[{"statement_date":"2026-01-01","amount":1}]'::jsonb)$f$,
    'bank_account is required', 'a blank account');
  perform pg_temp.expect_error(
    $f$select import_bank_statement_batch('BK-1', '[{"amount":1}]'::jsonb)$f$,
    'each line requires', 'a line with no date');

  -------------------------------------------------------------------
  -- 9. A caller outside the finance team is refused by both functions.
  -------------------------------------------------------------------
  reset role;
  perform pg_temp.jwt(outsider);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($f$select * from preview_bank_statement_import('BK-1', %L::jsonb)$f$, file1::text),
    'not authorized', 'preview by a non-finance user');
  perform pg_temp.expect_error(
    format($f$select import_bank_statement_batch('BK-1', %L::jsonb)$f$, file1::text),
    'not authorized', 'batch import by a non-finance user');
  reset role;

  -------------------------------------------------------------------
  -- 10. Grants: anon cannot execute either function.
  -------------------------------------------------------------------
  perform pg_temp.assert(
    not has_function_privilege('anon', 'public.preview_bank_statement_import(text, jsonb)', 'execute'),
    'anon cannot execute preview_bank_statement_import');
  perform pg_temp.assert(
    not has_function_privilege('anon', 'public.import_bank_statement_batch(text, jsonb, boolean)', 'execute'),
    'anon cannot execute import_bank_statement_batch');
  perform pg_temp.assert(
    has_function_privilege('authenticated', 'public.import_bank_statement_batch(text, jsonb, boolean)', 'execute'),
    'authenticated can execute import_bank_statement_batch');

  -------------------------------------------------------------------
  -- 11. The legacy function still works and leaves the batch id null.
  -------------------------------------------------------------------
  perform pg_temp.jwt(u);
  set local role authenticated;
  perform import_bank_statement_lines('BK-2', jsonb_build_array(fresh));
  reset role;
  perform pg_temp.assert(
    (select count(*) from bank_statement_lines where bank_account = 'BK-2' and tenant_id = ta
        and import_batch_id is null) = 1,
    'import_bank_statement_lines is unchanged and does not tag a batch');

  raise notice 'PASS: bank statement import duplicate protection';
end $$;

rollback;
