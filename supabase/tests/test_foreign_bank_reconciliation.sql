-- A3 rest: foreign-currency bank reconciliation
-- (import_bank_statement_lines, match_bank_statement_line,
-- fin_bank_line_candidates, fin_bank_reconciliation_position).
--
-- Covers: a statement import is pinned to the registered account's currency
-- (an omitted currency defaults to the account's, a wrong one is refused,
-- an unregistered name keeps the legacy UGX default); a mixed-currency
-- manual match is refused; the candidate search will not cross-match a USD
-- line with a UGX amount; and a foreign account's position reconciles the
-- account's own currency against its statement while reporting the
-- functional FX legs (revaluation, realised) separately. A functional
-- account still sees exactly the five original components.
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

create function pg_temp.position_amount(p_bank uuid, p_component text)
returns numeric language sql as $$
  select amount from fin_bank_reconciliation_position(p_bank, current_date)
  where component = p_component
$$;

do $$
declare
  ta       uuid := gen_random_uuid();
  u        uuid := gen_random_uuid();
  out_     uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  g_ops uuid; g_usd uuid; g_ar uuid; g_ap uuid; g_unearned uuid; g_income uuid;
  g_ugain uuid; g_uloss uuid; g_rgain uuid; g_rloss uuid;
  reg_id uuid; fx_id uuid;
  b_usd uuid; b_ops uuid;
  v_client uuid;
  v_je journal_entries%rowtype;
  ar1 uuid; s1 uuid; l1 uuid; l2 uuid; l_ugx uuid; t_ugx uuid;
  n integer; r record; rec record; matched integer;
begin
  -------------------------------------------------------------------
  -- Fixtures: one company with a UGX ledger, a UGX operating bank and a
  -- USD bank, approved USD rates for yesterday (3700) and today (3750).
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Recon Foreign Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'fbr-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (u), (out_), (approver)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (u,   ta, 'FBR Finance',  'fbr-' || u   || '@test.local'),
    (out_, ta, 'FBR Outsider', 'fbr-' || out_ || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, u, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1000','Operating UGX','asset'), (ta,'1030','Bank USD','asset'),
    (ta,'1100','AR','asset'), (ta,'2000','AP','liability'),
    (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue'),
    (ta,'4999','Other income','revenue'),
    (ta,'4900','Realised FX gain','revenue'), (ta,'5910','Realised FX loss','expense'),
    (ta,'4901','Unrealised FX gain','revenue'), (ta,'5911','Unrealised FX loss','expense');
  select id into g_ops     from gl_accounts where tenant_id=ta and account_code='1000';
  select id into g_usd     from gl_accounts where tenant_id=ta and account_code='1030';
  select id into g_ar      from gl_accounts where tenant_id=ta and account_code='1100';
  select id into g_ap      from gl_accounts where tenant_id=ta and account_code='2000';
  select id into g_unearned from gl_accounts where tenant_id=ta and account_code='2020';
  select id into g_income  from gl_accounts where tenant_id=ta and account_code='4000';
  select id into g_rgain   from gl_accounts where tenant_id=ta and account_code='4900';
  select id into g_rloss   from gl_accounts where tenant_id=ta and account_code='5910';
  select id into g_ugain   from gl_accounts where tenant_id=ta and account_code='4901';
  select id into g_uloss   from gl_accounts where tenant_id=ta and account_code='5911';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'bank',g_ops),(ta,'ar_control',g_ar),(ta,'ap_control',g_ap),
    (ta,'unearned_commission',g_unearned),(ta,'commission_income',g_income),
    (ta,'fx_gain_realised',g_rgain),(ta,'fx_loss_realised',g_rloss),
    (ta,'fx_gain_unrealised',g_ugain),(ta,'fx_loss_unrealised',g_uloss);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'RV-OPS-UGX','operating','UGX',g_ops);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'RV-BANK-USD','operating','USD',g_usd) returning id into b_usd;
  select id into b_ops from fin_bank_accounts where tenant_id = ta and name = 'RV-OPS-UGX';

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

  perform pg_temp.jwt(u);
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (ta, 'C-FBR', 'FBR Client', 'client') returning id into v_client;
  reset role;

  -------------------------------------------------------------------
  -- 1. The import is pinned to the registered account's currency: an
  --    omitted currency defaults to the account's, a wrong one is
  --    refused, an unregistered name keeps the legacy UGX default.
  -------------------------------------------------------------------
  perform pg_temp.jwt(u);
  set local role authenticated;
  select id into l1 from import_bank_statement_lines('RV-BANK-USD',
    jsonb_build_array(jsonb_build_object('statement_date', current_date, 'description', 'Customer receipt', 'amount', 400)));
  perform pg_temp.assert((select currency from bank_statement_lines where id = l1) = 'USD',
    'a line without a currency defaults to the account currency');
  perform pg_temp.expect_error(
    format('select count(*) from import_bank_statement_lines(''RV-BANK-USD'', jsonb_build_array(jsonb_build_object(''statement_date'', date %L, ''amount'', 1, ''currency'', ''UGX'')))',
           current_date::text),
    'BANK_STMT_CURRENCY', 'a UGX line on a USD account');
  select id into l_ugx from import_bank_statement_lines('RV-LEGACY-ACC',
    jsonb_build_array(jsonb_build_object('statement_date', current_date, 'description', 'Old free-text account', 'amount', 9000)));
  perform pg_temp.assert((select currency from bank_statement_lines where id = l_ugx) = 'UGX',
    'an unregistered account name keeps the legacy UGX default');
  raise notice 'PASS: statement imports are pinned to the registered account currency';

  -------------------------------------------------------------------
  -- 2. The USD book side: an AR item at yesterday's 3700 and a 400
  --    receipt into the USD bank today. The statement line matches it
  --    and only it.
  -------------------------------------------------------------------
  reset role;
  v_je := post_journal_entry(ta, 'manual', null, current_date - 1, 'USD invoice and bank funding',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', g_usd,    'debit',   500, 'currency', 'USD', 'description', 'bank funding'),
      jsonb_build_object('gl_account_id', g_ar,     'debit',  1000, 'currency', 'USD', 'description', 'INV-FBR-1'),
      jsonb_build_object('gl_account_id', g_income, 'credit', 1500, 'currency', 'USD', 'description', 'funding and invoice')));
  ar1 := (fin_create_open_item_fx(ta, v_client, 'ar_control', 'test', null, 'INV-FBR-1', current_date - 1, null, 1000,
                                  'USD 1,000 due', 'USD', v_je.id)).id;

  perform pg_temp.jwt(u);
  set local role authenticated;
  -- The receipt lands yesterday, so the bank books at 3700 and the 3e run
  -- at today's 3750 is what moves it.
  s1 := (fin_record_settlement(b_usd, 'in', v_client, 400, current_date - 1,
                               jsonb_build_array(jsonb_build_object('open_item_id', ar1, 'amount', 400)))).id;

  select id into l2 from import_bank_statement_lines('RV-BANK-USD',
    jsonb_build_array(jsonb_build_object('statement_date', current_date - 1, 'description', 'Bank charge', 'amount', -50)));

  select auto_match_bank_statement('RV-BANK-USD', current_date - 10, current_date) into matched;
  perform pg_temp.assert(matched = 1, format('exactly one USD line auto-matches, got %s', matched));
  select * into rec from bank_reconciliations where bank_statement_line_id = l1;
  perform pg_temp.assert(rec.settlement_id = s1 and rec.match_type = 'auto' and rec.variance = 0,
    'the USD line matched the USD settlement at zero variance');
  perform pg_temp.assert(
    (select count(*) from bank_reconciliations where bank_statement_line_id = l2) = 0,
    'the bank charge stays unmatched');
  raise notice 'PASS: the candidate search matches the USD settlement and nothing else';

  -------------------------------------------------------------------
  -- 3. Mixed currencies are refused: a crafted USD line on the UGX
  --    account (the importer would never create one) matches neither a
  --    manual UGX receipt nor the auto-match pass.
  -------------------------------------------------------------------
  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, currency, transaction_date, bank_account, description
  ) values (
    ta, 'receipt', 'bank', 'receivable_invoice', gen_random_uuid(),
    9000, 'UGX', current_date, 'RV-OPS-UGX', 'UGX receipt'
  ) returning id into t_ugx;
  -- Craft the impossible-through-the-importer line (the owner bypasses RLS;
  -- the import RPC itself refuses to create it).
  reset role;
  update bank_statement_lines set bank_account = 'RV-OPS-UGX' where id = l_ugx;
  update bank_statement_lines set currency = 'USD' where id = l_ugx;
  perform pg_temp.jwt(u);
  set local role authenticated;

  perform pg_temp.expect_error(
    format('select match_bank_statement_line(%L::uuid, %L::uuid)', l_ugx, t_ugx),
    'different currencies (USD vs UGX)', 'a USD line against a UGX transaction');
  select auto_match_bank_statement('RV-OPS-UGX', current_date - 1, current_date) into matched;
  perform pg_temp.assert(matched = 0, format('the cross-currency line must not auto-match, got %s', matched));
  perform pg_temp.assert(
    (select count(*) from bank_reconciliations where bank_statement_line_id = l_ugx) = 0,
    'the crafted cross-currency line stays unmatched');
  -- Move it back off the UGX account so section 4's pools stay clean.
  reset role;
  update bank_statement_lines set bank_account = 'RV-LEGACY-ACC' where id = l_ugx;
  perform pg_temp.jwt(u);
  set local role authenticated;
  raise notice 'PASS: mixed-currency matches are refused by hand and by auto-match';

  -------------------------------------------------------------------
  -- 4. The position: the USD account reconciles its own currency
  --    against its statement, and the functional FX legs (the 3e
  --    revaluation) are reported separately. The 900 USD on the GL was
  --    all booked at 3700, so the run posts a 45,000 UGX debit onto it
  --    and the AR's 30,000 goes to its own control.
  -------------------------------------------------------------------
  perform fin_revalue_fx(current_date);
  reset role;

  perform pg_temp.jwt(u);
  set local role authenticated;
  perform pg_temp.assert((select count(*) from fin_bank_reconciliation_position(b_usd, current_date)) = 6,
    'a foreign account shows the six components');
  perform pg_temp.assert(pg_temp.position_amount(b_usd, 'gl_balance') = 900,
    format('the GL balance counts the account currency only, got %s', pg_temp.position_amount(b_usd, 'gl_balance')));
  perform pg_temp.assert(pg_temp.position_amount(b_usd, 'unmatched_book_items') = 0,
    'every USD book item is on the statement');
  perform pg_temp.assert(pg_temp.position_amount(b_usd, 'unmatched_statement_lines') = -50,
    'the bank charge is the only unmatched statement line');
  perform pg_temp.assert(pg_temp.position_amount(b_usd, 'expected_statement_balance') = 850,
    format('the statement should close at 850, got %s', pg_temp.position_amount(b_usd, 'expected_statement_balance')));
  perform pg_temp.assert(pg_temp.position_amount(b_usd, 'unexplained_difference') = 500,
    format('only the 500 funding leg is a GL movement the statement cannot see, got %s',
           pg_temp.position_amount(b_usd, 'unexplained_difference')));
  perform pg_temp.assert(pg_temp.position_amount(b_usd, 'fx_gl_movements') = 45000,
    format('the revaluation leg is reported in the functional currency, got %s', pg_temp.position_amount(b_usd, 'fx_gl_movements')));

  -- The functional account keeps exactly the original five components.
  perform pg_temp.assert((select count(*) from fin_bank_reconciliation_position(b_ops, current_date)) = 5,
    'a functional account shows the five original components');
  perform pg_temp.assert(pg_temp.position_amount(b_ops, 'gl_balance') = 9000,
    'the UGX GL balance sums every leg');
  perform pg_temp.assert(pg_temp.position_amount(b_ops, 'unmatched_book_items') = 9000,
    'the UGX receipt has no statement line yet');
  perform pg_temp.assert(pg_temp.position_amount(b_ops, 'expected_statement_balance') = 0,
    'the UGX expected balance nets the unmatched book items off');
  perform pg_temp.assert(pg_temp.position_amount(b_ops, 'unexplained_difference') = 0,
    'the UGX GL movement is fully explained');
  raise notice 'PASS: the position reconciles a foreign account in its own currency and shows the FX legs separately';

  -------------------------------------------------------------------
  -- 5. Access: a non-finance user can neither import nor match.
  -------------------------------------------------------------------
  perform pg_temp.jwt(out_);
  perform pg_temp.expect_error(
    format('select count(*) from import_bank_statement_lines(''RV-BANK-USD'', jsonb_build_array(jsonb_build_object(''statement_date'', date %L, ''amount'', 1)))',
           current_date::text),
    'not authorized', 'an outsider importing statement lines');
  perform pg_temp.expect_error(
    format('select match_bank_statement_line(%L::uuid, %L::uuid)', l1, t_ugx),
    'not authorized', 'an outsider matching lines');
  reset role;
  raise notice 'PASS: statement imports and matches stay finance-only';

  raise notice 'ALL PASS: foreign-currency bank reconciliation';
end
$$;

rollback;
