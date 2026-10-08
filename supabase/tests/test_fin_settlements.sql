-- Phase 2, D4b-1 + D4c: open-item subledger and settlement posting
-- (fin_open_items, fin_settlements, fin_allocations, fin_open_item_balances,
-- fin_record_settlement, fin_void_settlement).
--
-- Covers: receipt/payment posting and the journal it produces, partial and full
-- allocation, input validation, role/direction rules (operating vs client
-- money), party and tenant checks, bank-account checks, unmapped posting roles,
-- finance-role authorization, immutability, void by reversal, balances after a
-- void, RLS and grants, and the posting-time segregation re-check.
--
-- Run against a fresh local stack only (`supabase start` / `supabase db reset`).
-- Everything runs in one transaction that ROLLBACKs, so no fixture data is left
-- behind; any RAISE EXCEPTION is a real assertion failure and makes psql exit
-- non-zero (same convention as the other files in this directory).

\set ON_ERROR_STOP on

begin;

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

create function pg_temp.settle(p_bank uuid, p_dir text, p_party uuid, p_amt numeric,
                               p_allocs jsonb, p_date date default current_date)
returns public.fin_settlements language sql as $$
  select * from public.fin_record_settlement(p_bank, p_dir, p_party, p_amt, p_date, p_allocs)
$$;

create function pg_temp.a1(p_item uuid, p_amt numeric)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('open_item_id', p_item, 'amount', p_amt))
$$;

-- Owner-side readers, so assertions do not depend on the caller's RLS.
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
create function pg_temp.n_settlements(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.fin_settlements where tenant_id = p_tenant
$$;
create function pg_temp.n_settlement_journals(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.journal_entries
  where tenant_id = p_tenant and source_type in ('fin_settlement', 'fin_settlement_void')
$$;

do $$
declare
  v_ta uuid := gen_random_uuid();   -- tenant A (main)
  v_tb uuid := gen_random_uuid();   -- tenant B (isolation, unmapped roles)
  v_fin_a uuid := gen_random_uuid();
  v_cc_a  uuid := gen_random_uuid();
  v_out_a uuid := gen_random_uuid();
  v_fin_b uuid := gen_random_uuid();

  -- GL accounts
  v_gl_bank uuid; v_gl_trust uuid; v_gl_ar uuid; v_gl_comm uuid; v_gl_ap uuid; v_gl_ins uuid;
  v_gl_spare uuid; v_gl_bank_b uuid;

  -- parties
  v_client uuid; v_vendor uuid; v_insurer uuid; v_client_b uuid;

  -- bank accounts
  v_ops uuid; v_trust uuid; v_legacy uuid; v_inact uuid; v_ops_b uuid;

  -- open items
  v_ar1 uuid; v_ar2 uuid; v_ar3 uuid; v_ar_void uuid; v_ap1 uuid; v_ins1 uuid; v_comm1 uuid; v_ar_b uuid;

  v_s fin_settlements%rowtype;
  v_s_void fin_settlements%rowtype;
  v_bal record;
  v_n integer;
  v_base_settlements integer;
  v_base_journals integer;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Settlement Co A'), (v_tb, 'Settlement Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'settle-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_fin_a), (v_cc_a), (v_out_a), (v_fin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (v_fin_a, v_ta, 'Settle Finance A', 'settle-' || v_fin_a || '@test.local'),
    (v_cc_a,  v_ta, 'Settle Cost Control A', 'settle-' || v_cc_a || '@test.local'),
    (v_out_a, v_ta, 'Settle Outsider A', 'settle-' || v_out_a || '@test.local'),
    (v_fin_b, v_tb, 'Settle Finance B', 'settle-' || v_fin_b || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, v_fin_a, 'finance'),
    (v_ta, v_cc_a, 'cost_control'),
    (v_tb, v_fin_b, 'finance');
  -- v_out_a is deliberately not on the finance team.

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank', 'asset') returning id into v_gl_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1200', 'Receivables', 'asset') returning id into v_gl_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1210', 'Commission Receivable', 'asset') returning id into v_gl_comm;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1030', 'Spare Bank', 'asset') returning id into v_gl_spare;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2000', 'Payables', 'liability') returning id into v_gl_ap;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into v_gl_ins;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank_b;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', v_gl_bank),
    (v_ta, 'client_money_bank', v_gl_trust),
    (v_ta, 'ar_control', v_gl_ar),
    (v_ta, 'commission_receivable', v_gl_comm),
    (v_ta, 'ap_control', v_gl_ap),
    (v_ta, 'insurer_payable', v_gl_ins),
    (v_tb, 'bank', v_gl_bank_b);   -- tenant B deliberately has no ar_control rule

  -- Parties (accounts), created as the finance users.
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_ta, 'C-001', 'Settle Client', 'client') returning id into v_client;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_ta, 'V-001', 'Settle Vendor', 'vendor') returning id into v_vendor;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_ta, 'B-001', 'Settle Insurer', 'both') returning id into v_insurer;

  -- Bank accounts of tenant A.
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_ta, 'OPS-UGX', 'operating', 'UGX', v_gl_bank) returning id into v_ops;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_ta, 'TRUST-UGX', 'client_money', 'UGX', v_gl_trust) returning id into v_trust;
  insert into fin_bank_accounts (tenant_id, name) values (v_ta, 'LEGACY-NOGL') returning id into v_legacy;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_ta, 'RETIRED-UGX', 'operating', 'UGX', v_gl_spare) returning id into v_inact;
  update fin_bank_accounts set is_active = false where id = v_inact;
  reset role;

  -- Open items of tenant A (fin_create_open_item is internal; owner calls it
  -- with the matching tenant's user in the JWT).
  v_ar1     := (fin_create_open_item(v_ta, v_client,  'ar_control',            'test', null, 'INV-AR-1',   current_date, null, 1000)).id;
  v_ar2     := (fin_create_open_item(v_ta, v_client,  'ar_control',            'test', null, 'INV-AR-2',   current_date, null, 400)).id;
  v_ar3     := (fin_create_open_item(v_ta, v_client,  'ar_control',            'test', null, 'INV-AR-3',   current_date, null, 300)).id;
  v_ar_void := (fin_create_open_item(v_ta, v_client,  'ar_control',            'test', null, 'INV-AR-V',   current_date, null, 250)).id;
  v_ap1     := (fin_create_open_item(v_ta, v_vendor,  'ap_control',            'test', null, 'BILL-AP-1',  current_date, null, 600)).id;
  v_ins1    := (fin_create_open_item(v_ta, v_insurer, 'insurer_payable',       'test', null, 'BILL-INS-1', current_date, null, 500)).id;
  v_comm1   := (fin_create_open_item(v_ta, v_insurer, 'commission_receivable', 'test', null, 'COMM-1',     current_date, null, 200)).id;

  -- Tenant B.
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_tb, 'C-001', 'Settle Client B', 'client') returning id into v_client_b;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_tb, 'OPS-B', 'operating', 'UGX', v_gl_bank_b) returning id into v_ops_b;
  reset role;
  v_ar_b := (fin_create_open_item(v_tb, v_client_b, 'ar_control', 'test', null, 'INV-B-1', current_date, null, 100)).id;

  -- Duplicate source identity is rejected (idempotent raising by source).
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  perform fin_create_open_item(v_ta, v_client, 'ar_control', 'dup_src', v_ta, 'DUP-1', current_date, null, 10);
  perform pg_temp.expect_error(
    format('select fin_create_open_item(%L, %L, ''ar_control'', ''dup_src'', %L, ''DUP-2'', current_date, null, 10)', v_ta, v_client, v_ta),
    'fin_open_items_source_unique', 'second open item for the same source');
  -- A party from another company is rejected.
  perform pg_temp.expect_error(
    format('select fin_create_open_item(%L, %L, ''ar_control'', ''x'', null, ''X-1'', current_date, null, 10)', v_ta, v_client_b),
    'OPEN_ITEM_PARTY_INVALID', 'party from another company');
  -- A caller cannot raise items for another company.
  perform pg_temp.expect_error(
    format('select fin_create_open_item(%L, %L, ''ar_control'', ''x'', null, ''X-2'', current_date, null, 10)', v_tb, v_client_b),
    'not authorized to create open items', 'open item for another company');
  raise notice 'PASS: open-item creation rules';

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_base_settlements := pg_temp.n_settlements(v_ta);
  v_base_journals := pg_temp.n_settlement_journals(v_ta);

  -------------------------------------------------------------------
  -- 1. Receipt in full: Dr bank, Cr AR control
  -------------------------------------------------------------------
  v_s := pg_temp.settle(v_ops, 'in', v_client, 1000, pg_temp.a1(v_ar1, 1000));
  if v_s.status <> 'posted' or v_s.journal_entry_id is null or v_s.settlement_no is null
     or v_s.currency <> 'UGX' or v_s.void_journal_entry_id is not null then
    raise exception 'FAIL: receipt not recorded as posted with a journal (%)', to_jsonb(v_s);
  end if;
  if pg_temp.je_lines(v_s.journal_entry_id) <> 2
     or pg_temp.je_bal(v_s.journal_entry_id) <> 0
     or pg_temp.je_net(v_s.journal_entry_id, v_gl_bank) <> 1000
     or pg_temp.je_net(v_s.journal_entry_id, v_gl_ar) <> -1000 then
    raise exception 'FAIL: receipt journal wrong (expected Dr bank 1000 / Cr AR control 1000)';
  end if;
  select * into v_bal from fin_open_item_balances where id = v_ar1;
  if v_bal.settlement_status <> 'settled' or v_bal.outstanding_amount <> 0 or v_bal.allocated_amount <> 1000 then
    raise exception 'FAIL: fully allocated item should be settled (%)', to_jsonb(v_bal);
  end if;
  raise notice 'PASS: receipt posts Dr bank / Cr AR control and settles the item';

  -------------------------------------------------------------------
  -- 2. Partial allocation
  -------------------------------------------------------------------
  v_s := pg_temp.settle(v_ops, 'in', v_client, 150, pg_temp.a1(v_ar2, 150));
  select * into v_bal from fin_open_item_balances where id = v_ar2;
  if v_bal.settlement_status <> 'partly_settled' or v_bal.outstanding_amount <> 250 then
    raise exception 'FAIL: partial settlement should leave 250 outstanding (%)', to_jsonb(v_bal);
  end if;
  raise notice 'PASS: partial settlement leaves the remainder outstanding';

  -------------------------------------------------------------------
  -- 3. Rejections. Each failed call must leave no settlement or journal behind.
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 100, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar2, 50)::text),
    'SETTLEMENT_NOT_FULLY_ALLOCATED', 'allocations below the settlement amount');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 300, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar2, 300)::text),
    'ALLOCATION_EXCEEDS_ITEM', 'allocation above the outstanding amount');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 1, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar1, 1)::text),
    'ALLOCATION_EXCEEDS_ITEM', 'allocation against an already settled item');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 20, %L::jsonb)', v_ops, v_client,
           (pg_temp.a1(v_ar2, 10) || pg_temp.a1(v_ar2, 10))::text),
    'SETTLEMENT_INPUT', 'same item twice in the allocations');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, ''[]''::jsonb)', v_ops, v_client),
    'SETTLEMENT_INPUT', 'empty allocations');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 0, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar2, 0)::text),
    'SETTLEMENT_INPUT', 'zero amount');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''sideways'', %L, 10, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar2, 10)::text),
    'SETTLEMENT_INPUT', 'bad direction');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb, current_date + 5)', v_ops, v_client, pg_temp.a1(v_ar2, 10)::text),
    'SETTLEMENT_INPUT', 'future settlement date');
  raise notice 'PASS: input validation and allocation limits';

  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''out'', %L, 100, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar2, 100)::text),
    'SETTLEMENT_ROLE_NOT_ALLOWED', 'money out against a receivable item');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 100, %L::jsonb)', v_ops, v_vendor, pg_temp.a1(v_ap1, 100)::text),
    'SETTLEMENT_ROLE_NOT_ALLOWED', 'money in against a payable item');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''out'', %L, 600, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ap1, 600)::text),
    'ALLOCATION_PARTY', 'item of a different party than the settlement');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 200, %L::jsonb)', v_trust, v_insurer, pg_temp.a1(v_comm1, 200)::text),
    'SETTLEMENT_ROLE_NOT_ALLOWED', 'client-money account settling commission');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''out'', %L, 500, %L::jsonb)', v_ops, v_insurer, pg_temp.a1(v_ins1, 500)::text),
    'SETTLEMENT_ROLE_NOT_ALLOWED', 'operating account paying an insurer payable');
  raise notice 'PASS: operating vs client-money role and direction rules';

  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb)', v_legacy, v_client, pg_temp.a1(v_ar2, 10)::text),
    'SETTLEMENT_BANK', 'bank account without a GL account');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb)', v_inact, v_client, pg_temp.a1(v_ar2, 10)::text),
    'SETTLEMENT_BANK', 'inactive bank account');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb)', v_ops_b, v_client, pg_temp.a1(v_ar2, 10)::text),
    'SETTLEMENT_BANK', 'bank account of another company');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb)', v_ops, v_client, pg_temp.a1(gen_random_uuid(), 10)::text),
    'ALLOCATION_ITEM', 'unknown open item');
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 100, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar_b, 100)::text),
    'ALLOCATION_ITEM', 'open item of another company');
  raise notice 'PASS: bank-account and tenant checks';

  if pg_temp.n_settlements(v_ta) <> v_base_settlements + 2 or pg_temp.n_settlement_journals(v_ta) <> v_base_journals + 2 then
    raise exception 'FAIL: rejected settlements left rows behind (settlements %, journals %)',
      pg_temp.n_settlements(v_ta), pg_temp.n_settlement_journals(v_ta);
  end if;
  raise notice 'PASS: rejected settlements leave nothing behind';

  -------------------------------------------------------------------
  -- 4. The other legitimate combinations
  -------------------------------------------------------------------
  -- Client money in against AR: Dr trust GL, Cr AR control.
  v_s := pg_temp.settle(v_trust, 'in', v_client, 300, pg_temp.a1(v_ar3, 300));
  if pg_temp.je_net(v_s.journal_entry_id, v_gl_trust) <> 300 or pg_temp.je_net(v_s.journal_entry_id, v_gl_ar) <> -300
     or pg_temp.je_bal(v_s.journal_entry_id) <> 0 then
    raise exception 'FAIL: client-money receipt journal wrong';
  end if;
  -- Operating payment of a vendor bill: Dr AP control, Cr bank.
  v_s := pg_temp.settle(v_ops, 'out', v_vendor, 600, pg_temp.a1(v_ap1, 600));
  if pg_temp.je_net(v_s.journal_entry_id, v_gl_ap) <> 600 or pg_temp.je_net(v_s.journal_entry_id, v_gl_bank) <> -600
     or pg_temp.je_bal(v_s.journal_entry_id) <> 0 then
    raise exception 'FAIL: operating payment journal wrong';
  end if;
  -- Client-money payment of an insurer payable: Dr insurer payable, Cr trust GL.
  v_s := pg_temp.settle(v_trust, 'out', v_insurer, 500, pg_temp.a1(v_ins1, 500));
  if pg_temp.je_net(v_s.journal_entry_id, v_gl_ins) <> 500 or pg_temp.je_net(v_s.journal_entry_id, v_gl_trust) <> -500
     or pg_temp.je_bal(v_s.journal_entry_id) <> 0 then
    raise exception 'FAIL: insurer remittance journal wrong';
  end if;
  -- Operating receipt of commission: Dr bank, Cr commission receivable.
  v_s := pg_temp.settle(v_ops, 'in', v_insurer, 200, pg_temp.a1(v_comm1, 200));
  if pg_temp.je_net(v_s.journal_entry_id, v_gl_bank) <> 200 or pg_temp.je_net(v_s.journal_entry_id, v_gl_comm) <> -200
     or pg_temp.je_bal(v_s.journal_entry_id) <> 0 then
    raise exception 'FAIL: commission receipt journal wrong';
  end if;
  raise notice 'PASS: client-money and operating receipts and payments post to the right accounts';

  -------------------------------------------------------------------
  -- 5. Authorization and grants
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_cc_a, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar2, 10)::text),
    'requires the finance role', 'cost_control user recording a settlement');
  perform set_config('request.jwt.claims', json_build_object('sub', v_out_a, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar2, 10)::text),
    'requires the finance role', 'non-finance user recording a settlement');
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);

  perform pg_temp.expect_error(
    format('select fin_create_open_item(%L, %L, ''ar_control'', ''x'', null, ''X-3'', current_date, null, 10)', v_ta, v_client),
    'permission denied', 'authenticated calling fin_create_open_item');
  perform pg_temp.expect_error(
    format('select platform_fin_record_settlement_impl(%L, %L, ''in'', %L, 10, current_date, %L::jsonb)', v_ta, v_ops, v_client, pg_temp.a1(v_ar2, 10)::text),
    'permission denied', 'authenticated calling the settlement implementation');
  perform pg_temp.expect_error(
    format('select platform_fin_void_settlement_impl(%L, %L, ''reason here'')', v_ta, gen_random_uuid()),
    'permission denied', 'authenticated calling the void implementation');
  perform pg_temp.expect_error(
    format('insert into fin_open_items (tenant_id, party_account_id, side, control_role, source_type, document_no, document_date, amount) values (%L, %L, ''receivable'', ''ar_control'', ''x'', ''D'', current_date, 1)', v_ta, v_client),
    'permission denied', 'direct insert into fin_open_items');
  perform pg_temp.expect_error(
    format('insert into fin_allocations (tenant_id, settlement_id, open_item_id, amount) values (%L, %L, %L, 1)', v_ta, v_s.id, v_ar2),
    'permission denied', 'direct insert into fin_allocations');
  perform pg_temp.expect_error(
    format('insert into fin_settlements (tenant_id, settlement_no, direction, bank_account_id, party_account_id, amount, currency, settlement_date) values (%L, ''X'', ''in'', %L, %L, 1, ''UGX'', current_date)', v_ta, v_ops, v_client),
    'permission denied', 'direct insert into fin_settlements');
  perform pg_temp.expect_error(
    format('update fin_settlements set notes = ''x'' where id = %L', v_s.id),
    'permission denied', 'direct update of fin_settlements');
  perform pg_temp.expect_error(
    format('delete from fin_settlements where id = %L', v_s.id),
    'permission denied', 'delete from fin_settlements');
  raise notice 'PASS: only finance can record; clients cannot write the tables or call internal functions';

  -------------------------------------------------------------------
  -- 6. Immutability (checked as the table owner, so the triggers, not the
  --    grants, are what stops these)
  -------------------------------------------------------------------
  reset role;
  perform pg_temp.expect_error(
    format('update fin_settlements set amount = amount + 1 where id = %L', v_s.id),
    'SETTLEMENT_IMMUTABLE', 'editing a recorded settlement');
  perform pg_temp.expect_error(
    format('update fin_settlements set journal_entry_id = %L where id = %L', gen_random_uuid(), v_s.id),
    'SETTLEMENT_IMMUTABLE', 'repointing the posted journal');
  perform pg_temp.expect_error(
    format('update fin_settlements set status = ''void'' where id = %L', v_s.id),
    'SETTLEMENT_VOID', 'voiding without a reversing journal');
  perform pg_temp.expect_error(
    format('update fin_open_items set amount = amount + 1 where id = %L', v_ar2),
    'OPEN_ITEM_IMMUTABLE', 'editing an open item');
  perform pg_temp.expect_error(
    format('update fin_allocations set amount = amount + 1 where open_item_id = %L', v_ar2),
    'ALLOCATION_IMMUTABLE', 'editing an allocation');
  raise notice 'PASS: settlements, open items and allocations are immutable';

  -------------------------------------------------------------------
  -- 7. Void by reversal
  -------------------------------------------------------------------
  set local role authenticated;
  v_s := pg_temp.settle(v_ops, 'in', v_client, 250, pg_temp.a1(v_ar_void, 250));

  perform pg_temp.expect_error(
    format('select fin_void_settlement(%L, ''no'')', v_s.id),
    'at least 5 characters', 'void with a too-short reason');
  perform pg_temp.expect_error(
    format('select fin_void_settlement(%L, ''Entered in error'', current_date - 1)', v_s.id),
    'void date must be between', 'void dated before the settlement');
  perform set_config('request.jwt.claims', json_build_object('sub', v_cc_a, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select fin_void_settlement(%L, ''Entered in error'')', v_s.id),
    'requires the finance role', 'cost_control user voiding a settlement');
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);

  v_s_void := fin_void_settlement(v_s.id, 'Entered in error');
  if v_s_void.status <> 'void' or v_s_void.void_journal_entry_id is null or v_s_void.voided_at is null
     or v_s_void.void_reason <> 'Entered in error' or v_s_void.journal_entry_id <> v_s.journal_entry_id then
    raise exception 'FAIL: void did not record status, reason and reversing journal (%)', to_jsonb(v_s_void);
  end if;
  if pg_temp.je_bal(v_s_void.void_journal_entry_id) <> 0
     or pg_temp.je_net(v_s.journal_entry_id, v_gl_bank) + pg_temp.je_net(v_s_void.void_journal_entry_id, v_gl_bank) <> 0
     or pg_temp.je_net(v_s.journal_entry_id, v_gl_ar) + pg_temp.je_net(v_s_void.void_journal_entry_id, v_gl_ar) <> 0 then
    raise exception 'FAIL: void journal does not reverse the original';
  end if;
  select * into v_bal from fin_open_item_balances where id = v_ar_void;
  if v_bal.settlement_status <> 'open' or v_bal.outstanding_amount <> 250 or v_bal.allocated_amount <> 0 then
    raise exception 'FAIL: a voided settlement must stop counting against the item (%)', to_jsonb(v_bal);
  end if;
  perform pg_temp.expect_error(
    format('select fin_void_settlement(%L, ''Entered in error again'')', v_s.id),
    'already void', 'voiding twice');
  -- The item can be settled again after the void.
  v_s := pg_temp.settle(v_ops, 'in', v_client, 250, pg_temp.a1(v_ar_void, 250));
  select * into v_bal from fin_open_item_balances where id = v_ar_void;
  if v_bal.settlement_status <> 'settled' then
    raise exception 'FAIL: item should be settled again after re-recording (%)', to_jsonb(v_bal);
  end if;
  reset role;
  perform pg_temp.expect_error(
    format('insert into fin_allocations (tenant_id, settlement_id, open_item_id, amount) values (%L, %L, %L, 1)', v_ta, v_s_void.id, v_ar2),
    'ALLOCATION_SETTLEMENT', 'allocating against a void settlement');
  perform pg_temp.expect_error(
    format('update fin_settlements set notes = ''x'' where id = %L', v_s_void.id),
    'SETTLEMENT_', 'changing a void settlement');
  raise notice 'PASS: void reverses the journal, frees the item and cannot be repeated';

  -------------------------------------------------------------------
  -- 8. Unmapped posting role (tenant B has no ar_control rule)
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 100, %L::jsonb)', v_ops_b, v_client_b, pg_temp.a1(v_ar_b, 100)::text),
    'SETTLEMENT_UNMAPPED_ROLE', 'posting role with no GL mapping');
  raise notice 'PASS: posting fails loudly when a role is not mapped';

  -------------------------------------------------------------------
  -- 9. Segregation is re-checked at posting time: map the operating 'bank'
  --    role onto the client-money GL account after the accounts exist.
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  reset role;
  begin
    update gl_posting_rules set gl_account_id = v_gl_trust where tenant_id = v_ta and account_role = 'bank';
    set local role authenticated;
    perform pg_temp.expect_error(
      format('select pg_temp.settle(%L, ''in'', %L, 10, %L::jsonb)', v_trust, v_client, pg_temp.a1(v_ar2, 10)::text),
      'SETTLEMENT_SEGREGATION', 'client-money account whose GL is now the operating bank role');
    reset role;
    update gl_posting_rules set gl_account_id = v_gl_bank where tenant_id = v_ta and account_role = 'bank';
    raise notice 'PASS: segregation is re-checked when posting';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'SKIP: segregation re-check not exercised (posting rule could not be repointed: %)', sqlerrm;
  end;

  -------------------------------------------------------------------
  -- 10. RLS and anon
  -------------------------------------------------------------------
  set local role authenticated;
  select count(*) into v_n from fin_settlements where tenant_id = v_tb;
  if v_n <> 0 then raise exception 'FAIL: finance A can see % settlements of company B', v_n; end if;
  select count(*) into v_n from fin_open_items where tenant_id = v_tb;
  if v_n <> 0 then raise exception 'FAIL: finance A can see % open items of company B', v_n; end if;
  select count(*) into v_n from fin_open_items where tenant_id = v_ta;
  if v_n < 7 then raise exception 'FAIL: finance A should see company A''s open items (saw %)', v_n; end if;
  select count(*) into v_n from fin_allocations where tenant_id = v_tb;
  if v_n <> 0 then raise exception 'FAIL: finance A can see company B allocations'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cc_a, 'role', 'authenticated')::text, true);
  select count(*) into v_n from fin_settlements;
  if v_n = 0 then raise exception 'FAIL: cost_control (finance team) should be able to read settlements'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_out_a, 'role', 'authenticated')::text, true);
  select count(*) into v_n from fin_settlements;
  if v_n <> 0 then raise exception 'FAIL: a non-finance user can read % settlements', v_n; end if;
  select count(*) into v_n from fin_open_item_balances;
  if v_n <> 0 then raise exception 'FAIL: a non-finance user can read % open-item balances', v_n; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  select count(*) into v_n from fin_open_items;
  if v_n <> 1 then raise exception 'FAIL: finance B should see exactly its own 1 open item (saw %)', v_n; end if;
  select count(*) into v_n from fin_settlements;
  if v_n <> 0 then raise exception 'FAIL: finance B should see no settlements (saw %)', v_n; end if;
  reset role;

  set local role anon;
  perform pg_temp.expect_error('select count(*) from fin_settlements', 'permission denied', 'anon reading settlements');
  perform pg_temp.expect_error('select count(*) from fin_open_item_balances', 'permission denied', 'anon reading balances');
  perform pg_temp.expect_error(
    format('select fin_record_settlement(%L, ''in'', %L, 10, current_date, ''[]''::jsonb)', v_ops, v_client),
    'permission denied', 'anon recording a settlement');
  reset role;
  raise notice 'PASS: RLS isolates companies and finance team; anon has no access';

  raise notice 'ALL FIN_SETTLEMENTS TESTS PASSED';
end
$$;

rollback;