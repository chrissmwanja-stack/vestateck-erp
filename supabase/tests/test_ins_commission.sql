-- Insurance commission deferral (20261011090000_ins_commission_deferral.sql).
--
-- Covers: commission credited to the unearned liability at bind (never to
-- income), the entry record, the bind refusing a chart with no commission_income
-- rule, recognition only when the insurer's net item is fully paid (partial
-- payment earns nothing), the recognition journal, transfer authorization and
-- validation, the client-money shortfall check, the transfer journal and state
-- changes, the refusal to void an insurer payment whose commission has been
-- transferred out, voiding a transfer, reversal of recognition when an insurer
-- payment is voided, re-recognition after a reversal, direct-write lockout,
-- tenant isolation, anon, and the read-only guard triggers.
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

-- Runs a statement that must fail with an error whose text contains p_needle.
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

-- Runs a statement that must fail with the given SQLSTATE (for RLS denials,
-- whose message text is not stable).
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

-- Acts as a user for the rest of the transaction (role switching stays inline).
create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- The RPCs set the transaction-local flag `ins.via_rpc` and it stays on for the
-- rest of the transaction. Clear it before probing the direct-write guards, so a
-- test does not pass or fail because an earlier RPC left the flag on.
create function pg_temp.flag_off()
returns void language sql as $$ select set_config('ins.via_rpc', 'off', true); $$;
create function pg_temp.flag_on()
returns void language sql as $$ select set_config('ins.via_rpc', 'on', true); $$;

-- Owner-side numeric reader, so assertions do not depend on the caller's RLS.
create function pg_temp.scalar(p_sql text)
returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric;
begin
  execute p_sql into v;
  return v;
end $$;

create function pg_temp.je_net(p_je uuid, p_gl uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines
  where journal_entry_id = p_je and gl_account_id = p_gl
$$;
create function pg_temp.je_bal(p_je uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines where journal_entry_id = p_je
$$;
create function pg_temp.je_lines(p_je uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.journal_entry_lines where journal_entry_id = p_je
$$;
create function pg_temp.n_items_for(p_policy uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.fin_open_items
  where source_id = p_policy and source_type in ('ins_policy_premium', 'ins_policy_insurer')
$$;

create function pg_temp.item(p_policy uuid, p_type text) returns uuid
language sql security definer as $$
  select id from public.fin_open_items where source_id = p_policy and source_type = p_type
$$;
create function pg_temp.bal(p_tenant uuid, p_gl uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines
  where tenant_id = p_tenant and gl_account_id = p_gl
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
  v_tb uuid := gen_random_uuid();   -- tenant B: isolation, and a chart with no commission_income rule
  u_mgr   uuid := gen_random_uuid();
  u_mem   uuid := gen_random_uuid();
  u_fin   uuid := gen_random_uuid();   -- finance team, no insurance role
  u_out   uuid := gen_random_uuid();
  u_mgr_b uuid := gen_random_uuid();

  g_bank uuid; g_trust uuid; g_ar uuid; g_pay uuid; g_unear uuid; g_inc uuid;
  gb_ar uuid; gb_pay uuid; gb_unear uuid;
  v_pl uuid; v_insr uuid; v_pl_b uuid; v_insr_b uuid;
  c1 ins_clients%rowtype; cb ins_clients%rowtype;
  p1 ins_policies%rowtype; p2 ins_policies%rowtype; p0 ins_policies%rowtype; pb ins_policies%rowtype;
  e1 uuid; e2 uuid;
  v_pcli uuid; v_pins uuid;
  v_oper_bank uuid; v_trust_bank uuid;
  s_in1 fin_settlements%rowtype; s_out1a fin_settlements%rowtype; s_out1b fin_settlements%rowtype;
  s_out2 fin_settlements%rowtype; s_in2 fin_settlements%rowtype; s_out1c fin_settlements%rowtype;
  t1 ins_commission_transfers%rowtype; t2 ins_commission_transfers%rowtype;
  v_je uuid; v_n integer; v_num numeric; v_probe text;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Commission A'), (v_tb, 'Commission B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'inscomm-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (u_mgr), (u_mem), (u_fin), (u_out), (u_mgr_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (u_mgr,   v_ta, 'Comm Manager A', 'inscomm-' || u_mgr   || '@test.local'),
    (u_mem,   v_ta, 'Comm Member A',  'inscomm-' || u_mem   || '@test.local'),
    (u_fin,   v_ta, 'Comm Finance A', 'inscomm-' || u_fin   || '@test.local'),
    (u_out,   v_ta, 'Comm Outsider A','inscomm-' || u_out   || '@test.local'),
    (u_mgr_b, v_tb, 'Comm Manager B', 'inscomm-' || u_mgr_b || '@test.local');

  insert into tenant_modules (tenant_id, module) values (v_ta, 'insurance'), (v_tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_ta, u_mgr,   'insurance', 'manager'),
    (v_ta, u_mem,   'insurance', 'member'),
    (v_tb, u_mgr_b, 'insurance', 'manager');
  insert into finance_team_members (tenant_id, user_id, role) values (v_ta, u_fin, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank', 'asset') returning id into g_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1100', 'AR Control', 'asset') returning id into g_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into g_pay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2020', 'Unearned Commission', 'liability') returning id into g_unear;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '4000', 'Commission Income', 'revenue') returning id into g_inc;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', g_bank), (v_ta, 'client_money_bank', g_trust), (v_ta, 'ar_control', g_ar),
    (v_ta, 'insurer_payable', g_pay), (v_ta, 'unearned_commission', g_unear), (v_ta, 'commission_income', g_inc);

  -- Tenant B: everything except commission_income.
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '1100', 'AR Control', 'asset') returning id into gb_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '2010', 'Insurer Payable', 'liability') returning id into gb_pay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '2020', 'Unearned Commission', 'liability') returning id into gb_unear;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_tb, 'ar_control', gb_ar), (v_tb, 'insurer_payable', gb_pay), (v_tb, 'unearned_commission', gb_unear);

  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (v_tb, 'MOTOR', 'Motor B') returning id into v_pl_b;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (v_tb, 'BETA', 'Beta', 10) returning id into v_insr_b;
  cb := ins_register_client('Beta Client', 'corporate', null, null, null, 'medium');
  pb := pg_temp.newpol(cb.id, v_insr_b, v_pl_b, 100000, 10);
  reset role;

  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (v_ta, 'MOTOR', 'Motor') returning id into v_pl;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (v_ta, 'ALPHA', 'Alpha', 10) returning id into v_insr;
  c1 := ins_register_client('Acme Holdings', 'corporate', null, null, null, 'low');
  p1 := pg_temp.newpol(c1.id, v_insr, v_pl, 1000000, 10);
  p2 := pg_temp.newpol(c1.id, v_insr, v_pl, 1000000, 10);
  p0 := pg_temp.newpol(c1.id, v_insr, v_pl, 500000, 0);
  reset role;

  -------------------------------------------------------------------
  -- 1. Bind credits unearned commission, never income
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  p1 := ins_bind_policy(p1.id);
  p0 := ins_bind_policy(p0.id);
  reset role;
  perform pg_temp.assert(pg_temp.je_lines(p1.journal_entry_id) = 3 and pg_temp.je_bal(p1.journal_entry_id) = 0
                         and pg_temp.je_net(p1.journal_entry_id, g_ar) = 1000000
                         and pg_temp.je_net(p1.journal_entry_id, g_pay) = -900000
                         and pg_temp.je_net(p1.journal_entry_id, g_unear) = -100000
                         and pg_temp.je_net(p1.journal_entry_id, g_inc) = 0,
                         'bind: Dr AR gross, Cr insurer payable net, Cr unearned commission; nothing to income');
  select id into e1 from ins_commission_entries where policy_id = p1.id;
  perform pg_temp.assert(e1 is not null
                         and (select amount from ins_commission_entries where id = e1) = 100000
                         and (select status from ins_commission_entries where id = e1) = 'deferred'
                         and (select earned_on from ins_commission_entries where id = e1) is null,
                         'bind records a deferred commission entry for the commission amount');
  perform pg_temp.assert((select count(*) from ins_commission_entries where policy_id = p0.id) = 0
                         and pg_temp.je_lines(p0.journal_entry_id) = 2,
                         'a zero-commission policy has no entry and no commission line');
  perform pg_temp.assert(pg_temp.scalar(format('select unearned_amount from ins_commission_position where tenant_id = %L', v_ta)) = 100000
                         and pg_temp.scalar(format('select earned_in_client_money from ins_commission_position where tenant_id = %L', v_ta)) = 0,
                         'position view: 100000 unearned, nothing earned');
  raise notice 'PASS: bind credits unearned commission and records a deferred entry';

  -------------------------------------------------------------------
  -- 2. Bind needs the commission_income rule too (tenant B has none)
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', pb.id), 'INS_POSTING_RULE_MISSING',
                               'binding without a commission_income rule');
  reset role;
  perform pg_temp.assert((select status from ins_policies where id = pb.id) = 'draft'
                         and (select count(*) from ins_commission_entries where tenant_id = v_tb) = 0
                         and pg_temp.n_items_for(pb.id) = 0,
                         'a refused bind leaves no entry, items or journal behind');
  raise notice 'PASS: bind refuses a chart without commission_income, leaving nothing behind';

  -------------------------------------------------------------------
  -- 3. Partial payment to the insurer earns nothing
  -------------------------------------------------------------------
  select party_account_id into v_pcli from ins_clients where id = c1.id;
  select party_account_id into v_pins from ins_insurers where id = v_insr;

  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'TRUST-UGX', 'client_money', 'UGX', g_trust) returning id into v_trust_bank;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'OPER-UGX', 'operating', 'UGX', g_bank) returning id into v_oper_bank;
  s_in1  := pg_temp.pay(v_trust_bank, 'in',  v_pcli, pg_temp.item(p1.id, 'ins_policy_premium'), 1000000);
  s_out1a := pg_temp.pay(v_trust_bank, 'out', v_pins, pg_temp.item(p1.id, 'ins_policy_insurer'), 400000);
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id = e1) = 'deferred'
                         and (select count(*) from ins_commission_events where entry_id = e1) = 0
                         and pg_temp.scalar(format('select count(*) from journal_entries where tenant_id = %L and source_type = ''ins_commission_recognition''', v_ta)) = 0,
                         'a part payment to the insurer must not earn the commission');
  raise notice 'PASS: partial payment to the insurer leaves the commission unearned';

  -------------------------------------------------------------------
  -- 4. Full payment earns it
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  s_out1b := pg_temp.pay(v_trust_bank, 'out', v_pins, pg_temp.item(p1.id, 'ins_policy_insurer'), 500000);
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id = e1) = 'earned'
                         and (select earned_on from ins_commission_entries where id = e1) = current_date,
                         'paying the insurer in full earns the commission on the settlement date');
  select journal_entry_id into v_je from ins_commission_events where entry_id = e1 and event = 'recognised';
  perform pg_temp.assert(v_je is not null and pg_temp.je_bal(v_je) = 0
                         and pg_temp.je_net(v_je, g_unear) = 100000 and pg_temp.je_net(v_je, g_inc) = -100000
                         and (select settlement_id from ins_commission_events where entry_id = e1 and event = 'recognised') = s_out1b.id
                         and (select source_type from journal_entries where id = v_je) = 'ins_commission_recognition',
                         'recognition journal: Dr unearned, Cr income, tied to the settling payment');
  perform pg_temp.assert(pg_temp.bal(v_ta, g_trust) = 100000, 'client money holds exactly the earned commission');
  perform pg_temp.assert(pg_temp.scalar(format('select earned_in_client_money from ins_commission_position where tenant_id = %L', v_ta)) = 100000
                         and pg_temp.scalar(format('select unearned_amount from ins_commission_position where tenant_id = %L', v_ta)) = 0,
                         'position view: 100000 earned and waiting in client money');
  raise notice 'PASS: full payment to the insurer recognises the commission as income';

  -------------------------------------------------------------------
  -- 5. Who may transfer
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date)', v_trust_bank, v_oper_bank),
                               'INS_FORBIDDEN', 'a member transferring commission');
  reset role;
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date)', v_trust_bank, v_oper_bank),
                               'INS_FORBIDDEN', 'finance without an insurance role transferring commission');
  reset role;
  perform pg_temp.jwt(u_out);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date)', v_trust_bank, v_oper_bank),
                               'INS_FORBIDDEN', 'an outsider transferring commission');
  reset role;
  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date)', v_trust_bank, v_oper_bank),
                               'INS_TRANSFER_BANK', 'tenant B manager using tenant A bank accounts');
  reset role;
  raise notice 'PASS: only insurance managers transfer commission, and only their own banks';

  -------------------------------------------------------------------
  -- 6. Transfer validation
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date)', v_oper_bank, v_trust_bank),
                               'INS_TRANSFER_BANK', 'transfer in the wrong direction');
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date)', v_trust_bank, v_trust_bank),
                               'INS_TRANSFER_INPUT', 'same account both sides');
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, null)', v_trust_bank, v_oper_bank),
                               'INS_TRANSFER_INPUT', 'no transfer date');
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date + 30)', v_trust_bank, v_oper_bank),
                               'INS_TRANSFER_INPUT', 'future transfer date');
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date - 1)', v_trust_bank, v_oper_bank),
                               'INS_TRANSFER_DATE', 'transfer dated before the commission was earned');
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date, array[%L]::uuid[])',
                                      v_trust_bank, v_oper_bank, gen_random_uuid()),
                               'INS_TRANSFER_NOTHING', 'an unknown entry id');
  reset role;
  perform pg_temp.assert((select count(*) from ins_commission_transfers where tenant_id = v_ta) = 0
                         and (select status from ins_commission_entries where id = e1) = 'earned',
                         'refused transfers change nothing');

  -- Make a second earned entry whose cash is not in client money yet: the
  -- insurer is paid out of client money before the client has paid.
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  p2 := ins_bind_policy(p2.id);
  reset role;
  select id into e2 from ins_commission_entries where policy_id = p2.id;
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  s_out2 := pg_temp.pay(v_trust_bank, 'out', v_pins, pg_temp.item(p2.id, 'ins_policy_insurer'), 900000);
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id = e2) = 'earned'
                         and pg_temp.bal(v_ta, g_trust) = -800000,
                         'second policy earned while client money is overdrawn in the ledger');
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date, array[%L]::uuid[])',
                                      v_trust_bank, v_oper_bank, e2),
                               'INS_TRANSFER_TRUST_SHORT', 'transfer larger than the client-money ledger balance');
  reset role;
  raise notice 'PASS: transfer validation (direction, dates, entries, client-money shortfall)';

  -------------------------------------------------------------------
  -- 7. A successful transfer
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  s_in2 := pg_temp.pay(v_trust_bank, 'in', v_pcli, pg_temp.item(p2.id, 'ins_policy_premium'), 1000000);
  reset role;
  perform pg_temp.assert(pg_temp.bal(v_ta, g_trust) = 200000, 'after the client pays policy 2 client money holds both commissions');

  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  t1 := ins_transfer_earned_commission(v_trust_bank, v_oper_bank, current_date, array[e1], 'first batch');
  reset role;
  perform pg_temp.assert(t1.status = 'posted' and t1.amount = 100000 and t1.transfer_no like 'CTR-%'
                         and t1.from_bank_account_id = v_trust_bank and t1.to_bank_account_id = v_oper_bank
                         and t1.notes = 'first batch' and t1.journal_entry_id is not null,
                         'transfer row: posted, amount of the picked entry, numbered, with its journal');
  perform pg_temp.assert(pg_temp.je_bal(t1.journal_entry_id) = 0
                         and pg_temp.je_net(t1.journal_entry_id, g_bank) = 100000
                         and pg_temp.je_net(t1.journal_entry_id, g_trust) = -100000
                         and (select source_type from journal_entries where id = t1.journal_entry_id) = 'ins_commission_transfer',
                         'transfer journal: Dr operating bank, Cr client money');
  perform pg_temp.assert((select status from ins_commission_entries where id = e1) = 'transferred'
                         and (select transfer_id from ins_commission_entries where id = e1) = t1.id
                         and (select status from ins_commission_entries where id = e2) = 'earned',
                         'only the picked entry moves to transferred');
  perform pg_temp.assert(pg_temp.bal(v_ta, g_trust) = 100000 and pg_temp.bal(v_ta, g_bank) = 100000,
                         'client money 100000 left, operating 100000 received');
  perform pg_temp.assert((select count(*) from ins_commission_events where entry_id = e1 and event = 'transferred') = 1,
                         'the transfer is recorded in the entry history');

  -- Entries already transferred cannot be picked again.
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transfer_earned_commission(%L, %L, current_date, array[%L, %L]::uuid[])',
                                      v_trust_bank, v_oper_bank, e1, e2),
                               'INS_TRANSFER_ENTRIES', 'including an already transferred entry in a batch');
  reset role;
  raise notice 'PASS: transfer posts Dr operating / Cr client money and marks only the chosen entries';

  -------------------------------------------------------------------
  -- 8. A paid-out insurer settlement cannot be voided once its commission has left
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform pg_temp.expect_error(format('select fin_void_settlement(%L, ''Paid the wrong insurer'')', s_out1b.id),
                               'INS_COMMISSION_TRANSFERRED', 'voiding an insurer payment after the commission was transferred');
  reset role;
  perform pg_temp.assert((select status from fin_settlements where id = s_out1b.id) = 'posted'
                         and (select status from ins_commission_entries where id = e1) = 'transferred',
                         'the refused void changed nothing');
  raise notice 'PASS: voiding the insurer payment is refused while the commission is transferred';

  -------------------------------------------------------------------
  -- 9. Void the transfer, then reverse and re-earn
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L, ''Entered in error'')', t1.id),
                               'INS_FORBIDDEN', 'a member voiding a transfer');
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L, ''no'')', t1.id),
                               'INS_TRANSFER_VOID', 'void without a proper reason');
  t1 := ins_void_commission_transfer(t1.id, 'Entered in error');
  perform pg_temp.expect_error(format('select ins_void_commission_transfer(%L, ''Entered in error twice'')', t1.id),
                               'INS_TRANSFER_VOID', 'voiding a transfer twice');
  reset role;
  perform pg_temp.assert(t1.status = 'void' and t1.void_reason = 'Entered in error' and t1.void_journal_entry_id is not null
                         and pg_temp.je_net(t1.void_journal_entry_id, g_bank) = -100000
                         and pg_temp.je_net(t1.void_journal_entry_id, g_trust) = 100000,
                         'void posts the exact reversal of the transfer journal');
  perform pg_temp.assert((select status from ins_commission_entries where id = e1) = 'earned'
                         and (select transfer_id from ins_commission_entries where id = e1) is null
                         and pg_temp.bal(v_ta, g_trust) = 200000 and pg_temp.bal(v_ta, g_bank) = 0,
                         'the entry is earned again and the money is back in client money');

  -- Now the insurer payment can be voided: the commission was earned, not transferred.
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  s_out1b := fin_void_settlement(s_out1b.id, 'Paid the wrong insurer');
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id = e1) = 'deferred'
                         and (select earned_on from ins_commission_entries where id = e1) is null,
                         'voiding the settling payment puts the commission back to unearned');
  select journal_entry_id into v_je from ins_commission_events where entry_id = e1 and event = 'recognition_reversed';
  perform pg_temp.assert(v_je is not null and pg_temp.je_net(v_je, g_inc) = 100000 and pg_temp.je_net(v_je, g_unear) = -100000
                         and (select source_type from journal_entries where id = v_je) = 'ins_commission_recognition_reversal',
                         'reversal journal: Dr income, Cr unearned');
  perform pg_temp.assert(pg_temp.scalar(format('select count(*) from ins_commission_events where entry_id = %L', e1)) = 4,
                         'history: recognised, transferred, transfer voided, recognition reversed');

  -- Paying again earns it again (a second journal for the same entry).
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  s_out1c := pg_temp.pay(v_trust_bank, 'out', v_pins, pg_temp.item(p1.id, 'ins_policy_insurer'), 500000);
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id = e1) = 'earned'
                         and (select count(*) from ins_commission_events where entry_id = e1 and event = 'recognised') = 2,
                         'commission is earned a second time after the payment is re-made');
  raise notice 'PASS: void transfer, void settling payment, re-earn (reversal and second recognition)';

  -------------------------------------------------------------------
  -- 10. Direct writes are closed; reads follow the insurance tiers
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_state(format('update ins_commission_entries set status = ''earned'' where id = %L', e2), '42501', 'manager updating an entry');
  perform pg_temp.expect_state(format('delete from ins_commission_entries where id = %L', e2), '42501', 'manager deleting an entry');
  perform pg_temp.expect_state(format('insert into ins_commission_entries (tenant_id, policy_id, amount) values (%L, %L, 1)', v_ta, p0.id), '42501', 'manager inserting an entry');
  perform pg_temp.expect_state(format('insert into ins_commission_events (tenant_id, entry_id, event, amount) values (%L, %L, ''recognised'', 1)', v_ta, e2), '42501', 'manager inserting an event');
  perform pg_temp.expect_state(format('update ins_commission_transfers set amount = 1 where id = %L', t1.id), '42501', 'manager editing a transfer');
  select count(*) into v_n from ins_commission_ledger;
  perform pg_temp.assert(v_n = 2, 'manager reads both entries through the ledger view, got ' || v_n);
  reset role;

  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  select count(*) into v_n from ins_commission_entries;
  perform pg_temp.assert(v_n = 2, 'a member reads the entries');
  reset role;

  perform pg_temp.jwt(u_out);
  set local role authenticated;
  select count(*) into v_n from ins_commission_entries;
  perform pg_temp.assert(v_n = 0, 'an outsider reads no entries');
  select count(*) into v_n from ins_commission_transfers;
  perform pg_temp.assert(v_n = 0, 'an outsider reads no transfers');
  reset role;

  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  select count(*) into v_n from ins_commission_entries;
  select count(*) into v_num from ins_commission_events;
  perform pg_temp.assert(v_n = 0 and v_num = 0, 'tenant B sees nothing of tenant A');
  reset role;
  raise notice 'PASS: direct writes closed; reads follow the insurance tiers and tenant isolation';

  -------------------------------------------------------------------
  -- 11. Grants and guards
  -------------------------------------------------------------------
  perform pg_temp.assert(
    not has_function_privilege('anon', 'public.ins_transfer_earned_commission(uuid,uuid,date,uuid[],text)', 'execute')
    and not has_function_privilege('anon', 'public.ins_void_commission_transfer(uuid,text,date)', 'execute')
    and has_function_privilege('authenticated', 'public.ins_transfer_earned_commission(uuid,uuid,date,uuid[],text)', 'execute')
    and has_function_privilege('authenticated', 'public.ins_void_commission_transfer(uuid,text,date)', 'execute')
    and not has_function_privilege('authenticated', 'public.ins_item_paid_amount(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.ins_commission_on_settlement_posted()', 'execute')
    and not has_function_privilege('authenticated', 'public.ins_commission_on_settlement_voided()', 'execute'),
    'transfer RPCs are authenticated-only; the helper and trigger functions are not client-callable');
  perform pg_temp.assert(
    not has_table_privilege('anon', 'public.ins_commission_entries', 'select')
    and not has_table_privilege('anon', 'public.ins_commission_transfers', 'select')
    and not has_table_privilege('anon', 'public.ins_commission_events', 'select')
    and not has_table_privilege('anon', 'public.ins_commission_ledger', 'select')
    and not has_table_privilege('anon', 'public.ins_commission_position', 'select')
    and not has_table_privilege('authenticated', 'public.ins_commission_entries', 'insert')
    and not has_table_privilege('authenticated', 'public.ins_commission_entries', 'update')
    and not has_table_privilege('authenticated', 'public.ins_commission_entries', 'delete'),
    'anon reads nothing; authenticated cannot write the commission tables');
  perform pg_temp.assert(
    (select count(*) from pg_trigger where tgname = 'tenant_read_only_guard' and not tgisinternal
        and tgrelid in ('public.ins_commission_entries'::regclass, 'public.ins_commission_transfers'::regclass,
                        'public.ins_commission_events'::regclass)) = 3,
    'the read-only tenant guard is attached to all three commission tables');
  perform pg_temp.assert(
    'unearned_commission' = any (platform_gl_posting_roles())
    and exists (select 1 from industry_template_items where template_key = 'insurance' and kind = 'posting_rule' and name = 'unearned_commission')
    and exists (select 1 from industry_template_items where template_key = 'insurance' and kind = 'gl_account' and name = '2020'),
    'the insurance template carries the unearned_commission account and rule');
  raise notice 'PASS: grants, anon, read-only guard, template';

  raise notice 'ins_commission: all assertions passed';
end $$;

rollback;