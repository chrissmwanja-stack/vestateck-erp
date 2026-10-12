-- Insurance commission transfer reconciliation (20261012090000_ins_commission_transfer_reconciliation.sql).
--
-- Covers: the candidate rule for each side of a transfer (client-money line is
-- negative and matches the 'from' bank, operating line is positive and matches
-- the 'to' bank; wrong bank, wrong currency and unmatched amounts are not
-- candidates), who may reconcile (finance only; tenant isolation; anon), auto-match
-- (one candidate matches, an ambiguous pair is left alone, each side matches
-- separately), manual match (side follows the statement line's bank, variance
-- recorded and shown in the variance view, half-reconciled transfers), the
-- refusals (wrong bank, wrong currency, line or side already matched, unknown
-- ids, voided transfer), the void guard (refused while either side is matched,
-- allowed once both are unmatched, a voided transfer is no longer offered),
-- who can read transfers, and the table constraints.
--
-- Run against a fresh local stack only (`supabase start` / `supabase db reset`).
-- Everything runs in one transaction that ROLLBACKs, so no fixture data is left
-- behind; any RAISE EXCEPTION is a real assertion failure and makes psql exit
-- non-zero (same convention as the other files in this directory).

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

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

create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      return;
    end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
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

-- Owner-side readers, so assertions do not depend on the caller's RLS.
create function pg_temp.line(p_tenant uuid, p_desc text) returns uuid
language sql security definer as $$
  select id from public.bank_statement_lines where tenant_id = p_tenant and description = p_desc
$$;
create function pg_temp.recon(p_transfer uuid, p_side text) returns uuid
language sql security definer as $$
  select id from public.bank_reconciliations where commission_transfer_id = p_transfer and transfer_side = p_side
$$;
create function pg_temp.n_recon(p_transfer uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.bank_reconciliations where commission_transfer_id = p_transfer
$$;
create function pg_temp.n_line_recon(p_line uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.bank_reconciliations where bank_statement_line_id = p_line
$$;
create function pg_temp.cand_n(p_line uuid, p_tenant uuid) returns integer
language sql security definer set search_path = public, pg_temp as $$
  select count(*)::integer from public.fin_bank_line_candidates(p_line, p_tenant)
$$;
create function pg_temp.cand_has(p_line uuid, p_tenant uuid, p_source text, p_id uuid) returns boolean
language sql security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.fin_bank_line_candidates(p_line, p_tenant) c
                  where c.source = p_source and c.candidate_id = p_id)
$$;

create function pg_temp.item(p_policy uuid, p_type text) returns uuid
language sql security definer as $$
  select id from public.fin_open_items where source_id = p_policy and source_type = p_type
$$;
create function pg_temp.newpol(p_client uuid, p_insurer uuid, p_line uuid, p_gross numeric, p_rate numeric)
returns public.ins_policies language sql as $$
  select * from public.ins_create_policy(p_client, p_insurer, p_line, current_date, current_date + 365,
                                         50000000, 'UGX', p_gross, p_rate, null, null)
$$;
create function pg_temp.pay(p_bank uuid, p_dir text, p_party uuid, p_item uuid, p_amount numeric)
returns public.fin_settlements language sql as $$
  select * from public.fin_record_settlement(p_bank, p_dir, p_party, p_amount, current_date,
    jsonb_build_array(jsonb_build_object('open_item_id', p_item, 'amount', p_amount)))
$$;

do $$
declare
  v_ta uuid := gen_random_uuid();   -- tenant A: the brokerage under test
  v_tb uuid := gen_random_uuid();   -- tenant B: isolation
  u_mgr   uuid := gen_random_uuid();   -- insurance manager, not on the finance team
  u_mem   uuid := gen_random_uuid();   -- insurance member
  u_fin   uuid := gen_random_uuid();   -- finance team, no insurance role
  u_out   uuid := gen_random_uuid();   -- same company, no roles
  u_fin_b uuid := gen_random_uuid();   -- finance team of tenant B

  g_bank uuid; g_trust uuid; g_other uuid; g_ar uuid; g_pay uuid; g_unear uuid; g_inc uuid;
  v_pl uuid; v_insr uuid;
  c1 ins_clients%rowtype;
  p1 ins_policies%rowtype; p2 ins_policies%rowtype; p3 ins_policies%rowtype;
  e1 uuid; e2 uuid; e3 uuid;
  v_pcli uuid; v_pins uuid;
  v_trust_bank uuid; v_oper_bank uuid; v_other_bank uuid;
  t1 ins_commission_transfers%rowtype; t2 ins_commission_transfers%rowtype; t3 ins_commission_transfers%rowtype;
  r bank_reconciliations%rowtype; r_from1 bank_reconciliations%rowtype; r_to1 bank_reconciliations%rowtype;
  r_to2 bank_reconciliations%rowtype;
  l_out_t3 uuid; l_in_t3 uuid; l_amb_a uuid; l_amb_b uuid; l_in_amb uuid; l_in_over uuid; l_usd uuid; l_other uuid;
  v_n integer; v_num numeric;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Commission Recon A'), (v_tb, 'Commission Recon B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'insrecon-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (u_mgr), (u_mem), (u_fin), (u_out), (u_fin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (u_mgr,   v_ta, 'Recon Manager A',  'insrecon-' || u_mgr   || '@test.local'),
    (u_mem,   v_ta, 'Recon Member A',   'insrecon-' || u_mem   || '@test.local'),
    (u_fin,   v_ta, 'Recon Finance A',  'insrecon-' || u_fin   || '@test.local'),
    (u_out,   v_ta, 'Recon Outsider A', 'insrecon-' || u_out   || '@test.local'),
    (u_fin_b, v_tb, 'Recon Finance B',  'insrecon-' || u_fin_b || '@test.local');

  insert into tenant_modules (tenant_id, module) values (v_ta, 'insurance'), (v_tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_ta, u_mgr, 'insurance', 'manager'),
    (v_ta, u_mem, 'insurance', 'member');
  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, u_fin, 'finance'),
    (v_tb, u_fin_b, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank', 'asset') returning id into g_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1030', 'Other Bank', 'asset') returning id into g_other;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1100', 'AR Control', 'asset') returning id into g_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into g_pay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2020', 'Unearned Commission', 'liability') returning id into g_unear;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '4000', 'Commission Income', 'revenue') returning id into g_inc;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', g_bank), (v_ta, 'client_money_bank', g_trust), (v_ta, 'ar_control', g_ar),
    (v_ta, 'insurer_payable', g_pay), (v_ta, 'unearned_commission', g_unear), (v_ta, 'commission_income', g_inc);

  -- Three policies; each client pays in full, then the insurer is paid its net in
  -- full, which earns the commission: 100000, 100000 and 50000.
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (v_ta, 'MOTOR', 'Motor') returning id into v_pl;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (v_ta, 'ALPHA', 'Alpha', 10) returning id into v_insr;
  c1 := ins_register_client('Acme Holdings', 'corporate', null, null, null, 'low');
  p1 := pg_temp.newpol(c1.id, v_insr, v_pl, 1000000, 10);
  p2 := pg_temp.newpol(c1.id, v_insr, v_pl, 1000000, 10);
  p3 := pg_temp.newpol(c1.id, v_insr, v_pl, 500000, 10);
  p1 := ins_bind_policy(p1.id);
  p2 := ins_bind_policy(p2.id);
  p3 := ins_bind_policy(p3.id);
  reset role;
  select id into e1 from ins_commission_entries where policy_id = p1.id;
  select id into e2 from ins_commission_entries where policy_id = p2.id;
  select id into e3 from ins_commission_entries where policy_id = p3.id;
  select party_account_id into v_pcli from ins_clients where id = c1.id;
  select party_account_id into v_pins from ins_insurers where id = v_insr;

  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'TRUST-UGX', 'client_money', 'UGX', g_trust) returning id into v_trust_bank;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'OPER-UGX', 'operating', 'UGX', g_bank) returning id into v_oper_bank;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'OTHER-UGX', 'operating', 'UGX', g_other) returning id into v_other_bank;
  perform pg_temp.pay(v_trust_bank, 'in',  v_pcli, pg_temp.item(p1.id, 'ins_policy_premium'), 1000000);
  perform pg_temp.pay(v_trust_bank, 'in',  v_pcli, pg_temp.item(p2.id, 'ins_policy_premium'), 1000000);
  perform pg_temp.pay(v_trust_bank, 'in',  v_pcli, pg_temp.item(p3.id, 'ins_policy_premium'), 500000);
  perform pg_temp.pay(v_trust_bank, 'out', v_pins, pg_temp.item(p1.id, 'ins_policy_insurer'), 900000);
  perform pg_temp.pay(v_trust_bank, 'out', v_pins, pg_temp.item(p2.id, 'ins_policy_insurer'), 900000);
  perform pg_temp.pay(v_trust_bank, 'out', v_pins, pg_temp.item(p3.id, 'ins_policy_insurer'), 450000);
  reset role;
  perform pg_temp.assert((select count(*) from ins_commission_entries where tenant_id = v_ta and status = 'earned') = 3,
                         'fixture: three earned commission entries');

  -- Three transfers: two of 100000 (an ambiguous pair) and one of 50000.
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  t1 := ins_transfer_earned_commission(v_trust_bank, v_oper_bank, current_date, array[e1], 'transfer one');
  t2 := ins_transfer_earned_commission(v_trust_bank, v_oper_bank, current_date, array[e2], 'transfer two');
  t3 := ins_transfer_earned_commission(v_trust_bank, v_oper_bank, current_date, array[e3], 'transfer three');
  reset role;
  perform pg_temp.assert(t1.amount = 100000 and t2.amount = 100000 and t3.amount = 50000,
                         'fixture: transfers of 100000, 100000 and 50000');

  -- Statement lines, imported as the finance user.
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform import_bank_statement_lines('TRUST-UGX', jsonb_build_array(
    jsonb_build_object('statement_date', current_date, 'amount',  -50000, 'description', 'out t3'),
    jsonb_build_object('statement_date', current_date, 'amount', -100000, 'description', 'out amb a'),
    jsonb_build_object('statement_date', current_date, 'amount', -100000, 'description', 'out amb b'),
    jsonb_build_object('statement_date', current_date, 'amount', -100000, 'description', 'out usd', 'currency', 'USD')
  ));
  perform import_bank_statement_lines('OPER-UGX', jsonb_build_array(
    jsonb_build_object('statement_date', current_date, 'amount',   50000, 'description', 'in t3'),
    jsonb_build_object('statement_date', current_date, 'amount',  100000, 'description', 'in amb'),
    jsonb_build_object('statement_date', current_date, 'amount',  100500, 'description', 'in over')
  ));
  perform import_bank_statement_lines('OTHER-UGX', jsonb_build_array(
    jsonb_build_object('statement_date', current_date, 'amount', -100000, 'description', 'other bank')
  ));
  reset role;
  l_out_t3 := pg_temp.line(v_ta, 'out t3');     l_in_t3  := pg_temp.line(v_ta, 'in t3');
  l_amb_a  := pg_temp.line(v_ta, 'out amb a');  l_amb_b  := pg_temp.line(v_ta, 'out amb b');
  l_in_amb := pg_temp.line(v_ta, 'in amb');     l_in_over := pg_temp.line(v_ta, 'in over');
  l_usd    := pg_temp.line(v_ta, 'out usd');    l_other  := pg_temp.line(v_ta, 'other bank');

  -------------------------------------------------------------------
  -- 1. Candidates: each side of a transfer
  -------------------------------------------------------------------
  perform pg_temp.assert(pg_temp.cand_n(l_out_t3, v_ta) = 1 and pg_temp.cand_has(l_out_t3, v_ta, 'transfer_from', t3.id),
                         'the -50000 client-money line has exactly one candidate: transfer three, from side');
  perform pg_temp.assert(pg_temp.cand_n(l_in_t3, v_ta) = 1 and pg_temp.cand_has(l_in_t3, v_ta, 'transfer_to', t3.id),
                         'the +50000 operating line has exactly one candidate: transfer three, to side');
  perform pg_temp.assert(pg_temp.cand_n(l_amb_a, v_ta) = 2
                         and pg_temp.cand_has(l_amb_a, v_ta, 'transfer_from', t1.id)
                         and pg_temp.cand_has(l_amb_a, v_ta, 'transfer_from', t2.id),
                         'a -100000 client-money line is offered both 100000 transfers');
  perform pg_temp.assert(pg_temp.cand_n(l_in_amb, v_ta) = 2
                         and pg_temp.cand_has(l_in_amb, v_ta, 'transfer_to', t1.id)
                         and pg_temp.cand_has(l_in_amb, v_ta, 'transfer_to', t2.id),
                         'a +100000 operating line is offered both 100000 transfers');
  perform pg_temp.assert(pg_temp.cand_n(l_usd, v_ta) = 0, 'a line in another currency is not a candidate');
  perform pg_temp.assert(pg_temp.cand_n(l_other, v_ta) = 0, 'a line on a bank that is neither side is not a candidate');
  perform pg_temp.assert(pg_temp.cand_n(l_in_over, v_ta) = 0, 'a line whose amount differs from every transfer is not a candidate');
  raise notice 'PASS: candidates follow bank, direction, currency and amount';

  -------------------------------------------------------------------
  -- 2. Who may reconcile
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_out_t3, t3.id),
                               'not authorized to reconcile bank transactions', 'an insurance manager who is not on the finance team matching');
  perform pg_temp.expect_error(format('select auto_match_bank_statement(%L, current_date - 1, current_date + 1)', 'TRUST-UGX'),
                               'not authorized to auto-match bank transactions', 'an insurance manager auto-matching');
  reset role;
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_out_t3, t3.id),
                               'not authorized to reconcile bank transactions', 'an insurance member matching');
  reset role;
  perform pg_temp.jwt(u_out);
  set local role authenticated;
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_out_t3, t3.id),
                               'not authorized to reconcile bank transactions', 'a user with no roles matching');
  reset role;
  perform pg_temp.jwt(u_fin_b);
  set local role authenticated;
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_out_t3, t3.id),
                               'statement line not found', 'tenant B finance matching tenant A lines');
  reset role;
  perform pg_temp.assert(pg_temp.n_recon(t3.id) = 0, 'refused calls matched nothing');
  raise notice 'PASS: only finance matches, and only inside its own company';

  -------------------------------------------------------------------
  -- 3. Auto-match
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  v_n := auto_match_bank_statement('TRUST-UGX', current_date - 1, current_date + 1);
  reset role;
  perform pg_temp.assert(v_n = 1, 'auto-match on the client-money bank matched exactly the one unambiguous line');
  perform pg_temp.assert(pg_temp.n_line_recon(l_out_t3) = 1 and pg_temp.n_line_recon(l_amb_a) = 0 and pg_temp.n_line_recon(l_amb_b) = 0,
                         'the ambiguous -100000 lines were left for a person');
  select * into r from bank_reconciliations where id = pg_temp.recon(t3.id, 'from');
  perform pg_temp.assert(r.id is not null and r.bank_statement_line_id = l_out_t3 and r.match_type = 'auto'
                         and r.variance = 0 and r.cash_bank_transaction_id is null and r.settlement_id is null,
                         'auto-match recorded the from side of transfer three: auto, no variance, no other source');

  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  v_n := auto_match_bank_statement('OPER-UGX', current_date - 1, current_date + 1);
  reset role;
  perform pg_temp.assert(v_n = 1, 'auto-match on the operating bank matched exactly the one unambiguous line');
  select * into r from bank_reconciliations where id = pg_temp.recon(t3.id, 'to');
  perform pg_temp.assert(r.id is not null and r.bank_statement_line_id = l_in_t3 and r.match_type = 'auto' and r.variance = 0,
                         'auto-match recorded the to side of transfer three separately');
  perform pg_temp.assert(pg_temp.n_recon(t3.id) = 2, 'transfer three has one row per side');

  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  v_n := auto_match_bank_statement('TRUST-UGX', current_date - 1, current_date + 1)
       + auto_match_bank_statement('OPER-UGX', current_date - 1, current_date + 1);
  reset role;
  perform pg_temp.assert(v_n = 0, 'a second auto-match pass finds nothing new and still refuses to guess');
  raise notice 'PASS: auto-match matches each side once and leaves an ambiguous pair alone';

  -------------------------------------------------------------------
  -- 4. Manual match
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  r_from1 := match_bank_statement_line_to_commission_transfer(l_amb_a, t1.id);
  r_to1   := match_bank_statement_line_to_commission_transfer(l_in_over, t1.id);
  r_to2   := match_bank_statement_line_to_commission_transfer(l_in_amb, t2.id);
  reset role;
  perform pg_temp.assert(r_from1.transfer_side = 'from' and r_from1.match_type = 'manual' and r_from1.variance = 0
                         and r_from1.matched_by = u_fin and r_from1.commission_transfer_id = t1.id,
                         'the client-money line matched the from side of transfer one');
  perform pg_temp.assert(r_to1.transfer_side = 'to' and r_to1.variance = 500,
                         'the operating line matched the to side, with the 500 difference recorded as variance');
  perform pg_temp.assert(r_to2.transfer_side = 'to' and r_to2.variance = 0 and pg_temp.n_recon(t2.id) = 1,
                         'transfer two is half reconciled: only its to side is matched');
  select variance into v_num from v_bank_reconciliation_variance
   where reconciliation_id = r_to1.id and source = 'commission_transfer' and commission_transfer_id = t1.id;
  perform pg_temp.assert(v_num = 500, 'the variance view lists the transfer match as a commission_transfer source with variance 500');
  perform pg_temp.assert(not exists (select 1 from v_bank_reconciliation_variance where reconciliation_id = r_from1.id),
                         'a zero-variance match is not in the variance view');
  perform pg_temp.assert(pg_temp.cand_n(l_amb_b, v_ta) = 1 and pg_temp.cand_has(l_amb_b, v_ta, 'transfer_from', t2.id),
                         'once transfer one is matched on its from side, the other -100000 line is offered only transfer two');
  raise notice 'PASS: manual match picks the side from the statement bank and records variance';

  -------------------------------------------------------------------
  -- 5. Refusals
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_other, t1.id),
                               'moves money between', 'a line on a bank that is neither side of the transfer');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_usd, t2.id),
                               'different currencies', 'a line in another currency');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_amb_a, t2.id),
                               'already reconciled', 'a statement line that is already matched');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_amb_b, t1.id),
                               'already reconciled', 'a side of a transfer that is already matched');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_amb_b, gen_random_uuid()),
                               'commission transfer not found', 'an unknown transfer');
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', gen_random_uuid(), t2.id),
                               'statement line not found', 'an unknown statement line');
  reset role;
  perform pg_temp.assert(pg_temp.n_recon(t1.id) = 2 and pg_temp.n_recon(t2.id) = 1 and pg_temp.n_line_recon(l_amb_b) = 0
                         and pg_temp.n_line_recon(l_usd) = 0 and pg_temp.n_line_recon(l_other) = 0,
                         'refused matches left nothing behind');
  raise notice 'PASS: wrong bank, wrong currency, double matches and unknown ids are refused';

  -------------------------------------------------------------------
  -- 6. Voiding a transfer needs both sides unmatched
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L, %L)', t3.id, 'Entered in error'),
                               'INS_TRANSFER_RECONCILED', 'voiding a transfer with both sides matched');
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L, %L)', t2.id, 'Entered in error'),
                               'INS_TRANSFER_RECONCILED', 'voiding a transfer with only its to side matched');
  reset role;

  -- Unmatch the from side of transfer one: the to side still blocks the void.
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform unmatch_bank_reconciliation(r_from1.id);
  reset role;
  perform pg_temp.assert(pg_temp.n_recon(t1.id) = 1, 'one side of transfer one is still matched');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L, %L)', t1.id, 'Entered in error'),
                               'INS_TRANSFER_RECONCILED', 'voiding a transfer with only its from side unmatched');
  reset role;

  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform unmatch_bank_reconciliation(r_to1.id);
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  t1 := ins_void_commission_transfer(t1.id, 'Entered in error');
  reset role;
  perform pg_temp.assert(t1.status = 'void' and (select status from ins_commission_entries where id = e1) = 'earned',
                         'with both sides unmatched the transfer voids and its commission is earned again');

  -- A voided transfer is no longer offered or accepted.
  perform pg_temp.assert(not pg_temp.cand_has(l_amb_a, v_ta, 'transfer_from', t1.id)
                         and pg_temp.cand_n(l_amb_a, v_ta) = 1 and pg_temp.cand_has(l_amb_a, v_ta, 'transfer_from', t2.id),
                         'a voided transfer is no longer a candidate; only transfer two remains');
  perform pg_temp.assert(pg_temp.cand_n(l_in_over, v_ta) = 0, 'the operating line is not offered the voided transfer');
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform pg_temp.expect_error(format('select match_bank_statement_line_to_commission_transfer(%L, %L)', l_amb_a, t1.id),
                               'only posted commission transfers can be reconciled', 'matching a voided transfer');

  -- Both -100000 lines now have the same single candidate, so auto-match takes one and leaves the other.
  v_n := auto_match_bank_statement('TRUST-UGX', current_date - 1, current_date + 1);
  reset role;
  perform pg_temp.assert(v_n = 1, 'auto-match matched one of the two lines to transfer two and left the other');
  perform pg_temp.assert(pg_temp.n_line_recon(l_amb_a) + pg_temp.n_line_recon(l_amb_b) = 1
                         and pg_temp.recon(t2.id, 'from') is not null and pg_temp.n_recon(t2.id) = 2,
                         'transfer two now has both sides matched');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L, %L)', t2.id, 'Entered in error'),
                               'INS_TRANSFER_RECONCILED', 'voiding a transfer that is now fully matched');
  reset role;
  raise notice 'PASS: a transfer cannot be voided while either side is matched; a voided transfer drops out';

  -------------------------------------------------------------------
  -- 7. Who can read transfers
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  select count(*) into v_n from ins_commission_transfers;
  select count(*) into v_num from ins_commission_entries;
  reset role;
  perform pg_temp.assert(v_n = 3 and v_num = 0, 'finance without an insurance role reads the transfers but not the entries');
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  select count(*) into v_n from ins_commission_transfers;
  reset role;
  perform pg_temp.assert(v_n = 3, 'an insurance member reads the transfers');
  perform pg_temp.jwt(u_out);
  set local role authenticated;
  select count(*) into v_n from ins_commission_transfers;
  reset role;
  perform pg_temp.assert(v_n = 0, 'a user with no insurance or finance role sees no transfers');
  perform pg_temp.jwt(u_fin_b);
  set local role authenticated;
  select count(*) into v_n from ins_commission_transfers;
  reset role;
  perform pg_temp.assert(v_n = 0, 'tenant B finance sees no transfers of tenant A');
  raise notice 'PASS: transfer reads follow the finance and insurance tiers and tenant isolation';

  -------------------------------------------------------------------
  -- 8. Constraints and grants
  -------------------------------------------------------------------
  perform pg_temp.expect_state(format(
    'insert into bank_reconciliations (tenant_id, bank_statement_line_id, commission_transfer_id, transfer_side, match_type, variance) '
    'values (%L, %L, %L, ''middle'', ''manual'', 0)', v_ta, l_usd, t2.id),
    '23514', 'a transfer match with a side other than from or to');
  perform pg_temp.expect_state(format(
    'insert into bank_reconciliations (tenant_id, bank_statement_line_id, commission_transfer_id, match_type, variance) '
    'values (%L, %L, %L, ''manual'', 0)', v_ta, l_usd, t2.id),
    '23514', 'a transfer match with no side');
  perform pg_temp.assert(
    not has_function_privilege('anon', 'public.match_bank_statement_line_to_commission_transfer(uuid,uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.match_bank_statement_line_to_commission_transfer(uuid,uuid)', 'execute')
    and not has_function_privilege('anon', 'public.fin_bank_line_candidates(uuid,uuid)', 'execute'),
    'the manual-match RPC is authenticated-only and the candidate function is not anon-callable');
  raise notice 'PASS: constraints and grants';

  raise notice 'ins_commission_reconciliation: all assertions passed';
end $$;

rollback;