-- Phase 2, D4b-2: credit notes
-- (fin_credit_notes, fin_credit_applications, fin_raise_credit_note,
-- fin_void_credit_note, and the credit-aware fin_open_item_balances and
-- fin_allocations_guard).
--
-- Covers: posting on both sides (receivable Dr offset / Cr control, payable
-- Dr control / Cr offset), full application at raise, a credit note split
-- across items, balances (credited, allocated, outstanding, status), the
-- interaction with settlements in both directions, input validation, role /
-- party / offset-account rules, unmapped roles, failed attempts leaving no
-- rows, finance-role authorization and grants, immutability, void by
-- reversal and re-raising after a void, RLS and anon.
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

create function pg_temp.credit(p_role text, p_party uuid, p_amt numeric, p_offset uuid, p_apps jsonb,
                               p_date date default current_date, p_reason text default 'Test credit note')
returns public.fin_credit_notes language sql as $$
  select * from public.fin_raise_credit_note(p_role, p_party, p_amt, p_date, p_offset, p_apps, p_reason)
$$;

create function pg_temp.settle(p_bank uuid, p_dir text, p_party uuid, p_amt numeric, p_allocs jsonb)
returns public.fin_settlements language sql as $$
  select * from public.fin_record_settlement(p_bank, p_dir, p_party, p_amt, current_date, p_allocs)
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
create function pg_temp.n_credit_notes(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.fin_credit_notes where tenant_id = p_tenant
$$;
create function pg_temp.n_credit_apps(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.fin_credit_applications where tenant_id = p_tenant
$$;
create function pg_temp.n_credit_journals(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.journal_entries
  where tenant_id = p_tenant and source_type in ('fin_credit_note', 'fin_credit_note_void')
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
  v_gl_spare uuid; v_gl_rev uuid; v_gl_exp uuid; v_gl_rev_off uuid; v_gl_bank_b uuid; v_gl_rev_b uuid;

  -- parties
  v_client uuid; v_vendor uuid; v_insurer uuid; v_client_b uuid;

  -- bank accounts
  v_ops uuid;

  -- open items
  v_ar1 uuid; v_ar2 uuid; v_ar3 uuid; v_ap1 uuid; v_ins1 uuid; v_comm1 uuid; v_ar_b uuid;

  v_cn1 fin_credit_notes%rowtype;
  v_cn fin_credit_notes%rowtype;
  v_s fin_settlements%rowtype;
  v_bal record;
  v_n integer;
  v_base_notes integer;
  v_base_apps integer;
  v_base_journals integer;
  v_void_je uuid;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Credit Note Co A'), (v_tb, 'Credit Note Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'credit-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_fin_a), (v_cc_a), (v_out_a), (v_fin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (v_fin_a, v_ta, 'Credit Finance A', 'credit-' || v_fin_a || '@test.local'),
    (v_cc_a,  v_ta, 'Credit Cost Control A', 'credit-' || v_cc_a || '@test.local'),
    (v_out_a, v_ta, 'Credit Outsider A', 'credit-' || v_out_a || '@test.local'),
    (v_fin_b, v_tb, 'Credit Finance B', 'credit-' || v_fin_b || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, v_fin_a, 'finance'),
    (v_ta, v_cc_a, 'cost_control'),
    (v_tb, v_fin_b, 'finance');
  -- v_out_a is deliberately not on the finance team.

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank', 'asset') returning id into v_gl_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1030', 'Spare Bank', 'asset') returning id into v_gl_spare;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1200', 'Receivables', 'asset') returning id into v_gl_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1210', 'Commission Receivable', 'asset') returning id into v_gl_comm;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2000', 'Payables', 'liability') returning id into v_gl_ap;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into v_gl_ins;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '4000', 'Commission Income', 'revenue') returning id into v_gl_rev;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '5100', 'Premium Adjustments', 'expense') returning id into v_gl_exp;
  insert into gl_accounts (tenant_id, account_code, name, account_type, is_active) values (v_ta, '4900', 'Retired Income', 'revenue', false) returning id into v_gl_rev_off;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank_b;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '4000', 'Commission Income', 'revenue') returning id into v_gl_rev_b;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', v_gl_bank),
    (v_ta, 'client_money_bank', v_gl_trust),
    (v_ta, 'ar_control', v_gl_ar),
    (v_ta, 'commission_receivable', v_gl_comm),
    (v_ta, 'ap_control', v_gl_ap),
    (v_ta, 'insurer_payable', v_gl_ins),
    (v_tb, 'bank', v_gl_bank_b);   -- tenant B deliberately has no ar_control rule

  -- Parties and bank accounts, created as the finance users.
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_ta, 'C-001', 'Credit Client', 'client') returning id into v_client;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_ta, 'V-001', 'Credit Vendor', 'vendor') returning id into v_vendor;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_ta, 'B-001', 'Credit Insurer', 'both') returning id into v_insurer;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_ta, 'OPS-UGX', 'operating', 'UGX', v_gl_bank) returning id into v_ops;
  -- Registers the spare GL as a bank account so it is rejected as an offset by the bank-account rule alone.
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values (v_ta, 'SPARE-UGX', 'operating', 'UGX', v_gl_spare);
  reset role;

  -- Open items of tenant A (fin_create_open_item is internal; owner calls it).
  v_ar1   := (fin_create_open_item(v_ta, v_client,  'ar_control',            'test', null, 'INV-AR-1',   current_date, null, 1000)).id;
  v_ar2   := (fin_create_open_item(v_ta, v_client,  'ar_control',            'test', null, 'INV-AR-2',   current_date, null, 400)).id;
  v_ar3   := (fin_create_open_item(v_ta, v_client,  'ar_control',            'test', null, 'INV-AR-3',   current_date, null, 300)).id;
  v_ap1   := (fin_create_open_item(v_ta, v_vendor,  'ap_control',            'test', null, 'BILL-AP-1',  current_date, null, 600)).id;
  v_ins1  := (fin_create_open_item(v_ta, v_insurer, 'insurer_payable',       'test', null, 'BILL-INS-1', current_date, null, 500)).id;
  v_comm1 := (fin_create_open_item(v_ta, v_insurer, 'commission_receivable', 'test', null, 'COMM-1',     current_date, null, 200)).id;

  -- Tenant B.
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into accounts (tenant_id, account_code, name, account_type) values (v_tb, 'C-001', 'Credit Client B', 'client') returning id into v_client_b;
  reset role;
  v_ar_b := (fin_create_open_item(v_tb, v_client_b, 'ar_control', 'test', null, 'INV-B-1', current_date, null, 100)).id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -------------------------------------------------------------------
  -- 1. Receivable credit note on one item: Dr offset, Cr AR control
  -------------------------------------------------------------------
  v_cn1 := pg_temp.credit('ar_control', v_client, 200, v_gl_rev, pg_temp.a1(v_ar1, 200));
  if v_cn1.status <> 'posted' or v_cn1.journal_entry_id is null or v_cn1.credit_note_no is null
     or v_cn1.currency <> 'UGX' or v_cn1.side <> 'receivable' or v_cn1.void_journal_entry_id is not null then
    raise exception 'FAIL: credit note not recorded as posted with a journal (%)', to_jsonb(v_cn1);
  end if;
  if pg_temp.je_lines(v_cn1.journal_entry_id) <> 2
     or pg_temp.je_bal(v_cn1.journal_entry_id) <> 0
     or pg_temp.je_net(v_cn1.journal_entry_id, v_gl_rev) <> 200
     or pg_temp.je_net(v_cn1.journal_entry_id, v_gl_ar) <> -200 then
    raise exception 'FAIL: receivable credit note journal wrong (expected Dr offset 200 / Cr AR control 200)';
  end if;
  select * into v_bal from fin_open_item_balances where id = v_ar1;
  if v_bal.credited_amount <> 200 or v_bal.allocated_amount <> 0 or v_bal.outstanding_amount <> 800
     or v_bal.settlement_status <> 'partly_settled' then
    raise exception 'FAIL: credited item should show 200 credited, 800 outstanding (%)', to_jsonb(v_bal);
  end if;
  raise notice 'PASS: receivable credit note posts Dr offset / Cr AR control and reduces the item';

  -------------------------------------------------------------------
  -- 2. One credit note split across two items
  -------------------------------------------------------------------
  v_cn := pg_temp.credit('ar_control', v_client, 150, v_gl_rev,
                         pg_temp.a1(v_ar2, 100) || pg_temp.a1(v_ar3, 50));
  if pg_temp.je_lines(v_cn.journal_entry_id) <> 2 or pg_temp.je_net(v_cn.journal_entry_id, v_gl_ar) <> -150 then
    raise exception 'FAIL: split credit note should post one journal of 150 against AR control';
  end if;
  select * into v_bal from fin_open_item_balances where id = v_ar2;
  if v_bal.outstanding_amount <> 300 or v_bal.credited_amount <> 100 then
    raise exception 'FAIL: first split item should have 300 outstanding (%)', to_jsonb(v_bal);
  end if;
  select * into v_bal from fin_open_item_balances where id = v_ar3;
  if v_bal.outstanding_amount <> 250 or v_bal.credited_amount <> 50 then
    raise exception 'FAIL: second split item should have 250 outstanding (%)', to_jsonb(v_bal);
  end if;
  raise notice 'PASS: a credit note can be split across several open items';

  -------------------------------------------------------------------
  -- 3. Credit notes and settlements share the same outstanding amount
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format('select pg_temp.settle(%L, ''in'', %L, 801, %L::jsonb)', v_ops, v_client, pg_temp.a1(v_ar1, 801)::text),
    'ALLOCATION_EXCEEDS_ITEM', 'receipt above what is left after a credit note');
  v_s := pg_temp.settle(v_ops, 'in', v_client, 800, pg_temp.a1(v_ar1, 800));
  select * into v_bal from fin_open_item_balances where id = v_ar1;
  if v_bal.settlement_status <> 'settled' or v_bal.outstanding_amount <> 0
     or v_bal.allocated_amount <> 800 or v_bal.credited_amount <> 200 then
    raise exception 'FAIL: receipt plus credit note should settle the item (%)', to_jsonb(v_bal);
  end if;
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 1, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar1, 1)::text),
    'CREDIT_EXCEEDS_ITEM', 'credit note against an item already settled by receipt and credit');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 301, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar2, 301)::text),
    'CREDIT_EXCEEDS_ITEM', 'credit note above the outstanding amount');
  raise notice 'PASS: settlements and credit notes cannot over-consume an item';

  -------------------------------------------------------------------
  -- 4. Payable side and commission, other roles
  -------------------------------------------------------------------
  -- Insurer credits us: Dr insurer payable, Cr offset.
  v_cn := pg_temp.credit('insurer_payable', v_insurer, 100, v_gl_exp, pg_temp.a1(v_ins1, 100));
  if v_cn.side <> 'payable' or pg_temp.je_net(v_cn.journal_entry_id, v_gl_ins) <> 100
     or pg_temp.je_net(v_cn.journal_entry_id, v_gl_exp) <> -100 or pg_temp.je_bal(v_cn.journal_entry_id) <> 0 then
    raise exception 'FAIL: insurer payable credit note journal wrong (expected Dr insurer payable 100 / Cr offset 100)';
  end if;
  select * into v_bal from fin_open_item_balances where id = v_ins1;
  if v_bal.outstanding_amount <> 400 then
    raise exception 'FAIL: insurer payable item should have 400 outstanding (%)', to_jsonb(v_bal);
  end if;
  -- Vendor credit: Dr AP control, Cr offset.
  v_cn := pg_temp.credit('ap_control', v_vendor, 100, v_gl_exp, pg_temp.a1(v_ap1, 100));
  if pg_temp.je_net(v_cn.journal_entry_id, v_gl_ap) <> 100 or pg_temp.je_net(v_cn.journal_entry_id, v_gl_exp) <> -100 then
    raise exception 'FAIL: vendor credit note journal wrong';
  end if;
  -- Commission reduction: Dr offset, Cr commission receivable.
  v_cn := pg_temp.credit('commission_receivable', v_insurer, 50, v_gl_rev, pg_temp.a1(v_comm1, 50));
  if pg_temp.je_net(v_cn.journal_entry_id, v_gl_rev) <> 50 or pg_temp.je_net(v_cn.journal_entry_id, v_gl_comm) <> -50 then
    raise exception 'FAIL: commission credit note journal wrong';
  end if;
  raise notice 'PASS: payable, vendor and commission credit notes post to the right accounts';

  -------------------------------------------------------------------
  -- 5. Rejections. Each failed call must leave no credit note, application or journal.
  -------------------------------------------------------------------
  v_base_notes := pg_temp.n_credit_notes(v_ta);
  v_base_apps := pg_temp.n_credit_apps(v_ta);
  v_base_journals := pg_temp.n_credit_journals(v_ta);

  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 100, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar2, 50)::text),
    'CREDIT_NOTE_NOT_FULLY_APPLIED', 'applications below the credit note amount');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 20, %L, %L::jsonb)', v_client, v_gl_rev,
           (pg_temp.a1(v_ar2, 10) || pg_temp.a1(v_ar2, 10))::text),
    'CREDIT_NOTE_INPUT', 'same item twice in the applications');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, ''[]''::jsonb)', v_client, v_gl_rev),
    'CREDIT_NOTE_INPUT', 'empty applications');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 0, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar2, 0)::text),
    'CREDIT_NOTE_INPUT', 'zero amount');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''bank'', %L, 10, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_INPUT', 'a control role that is not a subledger role');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb, current_date + 5)', v_client, v_gl_rev, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_INPUT', 'future credit date');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb, current_date, ''abc'')', v_client, v_gl_rev, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_INPUT', 'reason too short');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ap_control'', %L, 10, %L, %L::jsonb)', v_vendor, v_gl_exp, pg_temp.a1(v_ins1, 10)::text),
    'CREDIT_NOTE_ROLE', 'payable credit note against an item with another control role');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_vendor, v_gl_rev, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_APPLICATION_PARTY', 'item of a different party than the credit note');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(gen_random_uuid(), 10)::text),
    'CREDIT_APPLICATION_ITEM', 'unknown open item');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar_b, 10)::text),
    'CREDIT_APPLICATION_ITEM', 'open item of another company');
  raise notice 'PASS: input validation, role, party and item rules';

  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_ar, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_OFFSET', 'offset is the control account');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_trust, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_OFFSET', 'offset is the client-money account');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_bank, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_OFFSET', 'offset is the operating bank account');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_spare, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_OFFSET', 'offset is a registered bank account without a posting rule');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_rev_off, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_OFFSET', 'inactive offset account');
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_rev_b, pg_temp.a1(v_ar2, 10)::text),
    'CREDIT_NOTE_OFFSET', 'offset account of another company');
  raise notice 'PASS: offset-account rules';

  if pg_temp.n_credit_notes(v_ta) <> v_base_notes or pg_temp.n_credit_apps(v_ta) <> v_base_apps
     or pg_temp.n_credit_journals(v_ta) <> v_base_journals then
    raise exception 'FAIL: rejected credit notes left rows behind (notes % vs %, applications % vs %, journals % vs %)',
      pg_temp.n_credit_notes(v_ta), v_base_notes, pg_temp.n_credit_apps(v_ta), v_base_apps,
      pg_temp.n_credit_journals(v_ta), v_base_journals;
  end if;
  raise notice 'PASS: rejected credit notes leave nothing behind';

  -------------------------------------------------------------------
  -- 6. Unmapped control role fails loudly (tenant B has no ar_control rule)
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client_b, v_gl_rev_b, pg_temp.a1(v_ar_b, 10)::text),
    'CREDIT_NOTE_UNMAPPED_ROLE', 'role with no GL account');
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  if pg_temp.n_credit_notes(v_tb) <> 0 then
    raise exception 'FAIL: a failed credit note left a row in company B';
  end if;
  raise notice 'PASS: unmapped posting role fails loudly';

  -------------------------------------------------------------------
  -- 7. Authorization and grants
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_cc_a, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar2, 10)::text),
    'requires the finance role', 'cost_control raising a credit note');
  perform pg_temp.expect_error(
    format('select fin_void_credit_note(%L, ''no authority here'')', v_cn1.id),
    'requires the finance role', 'cost_control voiding a credit note');
  perform set_config('request.jwt.claims', json_build_object('sub', v_out_a, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select pg_temp.credit(''ar_control'', %L, 10, %L, %L::jsonb)', v_client, v_gl_rev, pg_temp.a1(v_ar2, 10)::text),
    'requires the finance role', 'non-finance user raising a credit note');
  perform pg_temp.expect_error(
    format('select fin_void_credit_note(%L, ''no authority here'')', v_cn1.id),
    'requires the finance role', 'non-finance user voiding a credit note');

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  perform pg_temp.expect_error(
    format('select platform_fin_raise_credit_note_impl(%L, ''ar_control'', %L, 10, current_date, %L, %L::jsonb, ''Test credit note'')',
           v_ta, v_client, v_gl_rev, pg_temp.a1(v_ar2, 10)::text),
    'permission denied', 'client calling the internal raise implementation');
  perform pg_temp.expect_error(
    format('select platform_fin_void_credit_note_impl(%L, %L, ''no authority here'')', v_ta, v_cn1.id),
    'permission denied', 'client calling the internal void implementation');
  perform pg_temp.expect_error(
    format('insert into fin_credit_notes (tenant_id, credit_note_no, side, control_role, party_account_id, offset_gl_account_id, amount, currency, credit_date, reason) values (%L, ''X'', ''receivable'', ''ar_control'', %L, %L, 1, ''UGX'', current_date, ''direct insert'')',
           v_ta, v_client, v_gl_rev),
    'permission denied', 'client writing credit notes directly');
  perform pg_temp.expect_error(
    format('insert into fin_credit_applications (tenant_id, credit_note_id, open_item_id, amount) values (%L, %L, %L, 1)', v_ta, v_cn1.id, v_ar2),
    'permission denied', 'client writing credit applications directly');
  perform pg_temp.expect_error(
    format('select fin_open_item_consumed(%L)', v_ar1),
    'permission denied', 'client calling the internal consumed-amount helper');
  raise notice 'PASS: only the finance role can raise or void; internals and tables are closed to clients';

  -------------------------------------------------------------------
  -- 8. Immutability (as the table owner: the triggers must still refuse)
  -------------------------------------------------------------------
  reset role;
  perform pg_temp.expect_error(
    format('update fin_credit_notes set amount = 999 where id = %L', v_cn1.id),
    'CREDIT_NOTE_IMMUTABLE', 'editing a credit note amount');
  perform pg_temp.expect_error(
    format('update fin_credit_notes set offset_gl_account_id = %L where id = %L', v_gl_exp, v_cn1.id),
    'CREDIT_NOTE_IMMUTABLE', 'editing a credit note offset account');
  perform pg_temp.expect_error(
    format('update fin_credit_applications set amount = 1 where credit_note_id = %L', v_cn1.id),
    'CREDIT_APPLICATION_IMMUTABLE', 'editing a credit application');
  raise notice 'PASS: credit notes and applications cannot be edited';

  -------------------------------------------------------------------
  -- 9. Void by reversal
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select fin_void_credit_note(%L, ''abc'')', v_cn1.id),
    'CREDIT_NOTE_VOID', 'void with a reason that is too short');

  v_cn := fin_void_credit_note(v_cn1.id, 'Raised against the wrong invoice');
  if v_cn.status <> 'void' or v_cn.void_journal_entry_id is null or v_cn.voided_at is null or v_cn.void_reason is null then
    raise exception 'FAIL: void credit note should carry its reversing journal, time and reason (%)', to_jsonb(v_cn);
  end if;
  v_void_je := v_cn.void_journal_entry_id;
  if pg_temp.je_bal(v_void_je) <> 0
     or pg_temp.je_net(v_cn1.journal_entry_id, v_gl_rev) + pg_temp.je_net(v_void_je, v_gl_rev) <> 0
     or pg_temp.je_net(v_cn1.journal_entry_id, v_gl_ar) + pg_temp.je_net(v_void_je, v_gl_ar) <> 0 then
    raise exception 'FAIL: the reversing journal should net the original to zero';
  end if;
  select * into v_bal from fin_open_item_balances where id = v_ar1;
  if v_bal.credited_amount <> 0 or v_bal.allocated_amount <> 800 or v_bal.outstanding_amount <> 200
     or v_bal.settlement_status <> 'partly_settled' then
    raise exception 'FAIL: voiding the credit note should reopen 200 on the item (%)', to_jsonb(v_bal);
  end if;
  perform pg_temp.expect_error(
    format('select fin_void_credit_note(%L, ''Second attempt to void'')', v_cn1.id),
    'already void', 'voiding a credit note twice');

  reset role;
  perform pg_temp.expect_error(
    format('insert into fin_credit_applications (tenant_id, credit_note_id, open_item_id, amount) values (%L, %L, %L, 1)', v_ta, v_cn1.id, v_ar1),
    'CREDIT_APPLICATION_NOTE', 'applying a void credit note');
  perform pg_temp.expect_error(
    format('update fin_credit_notes set status = ''posted'' where id = %L', v_cn1.id),
    'CREDIT_NOTE_', 'reviving a void credit note');

  -- The freed amount can be credited again.
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_cn := pg_temp.credit('ar_control', v_client, 200, v_gl_rev, pg_temp.a1(v_ar1, 200), current_date, 'Corrected credit note');
  select * into v_bal from fin_open_item_balances where id = v_ar1;
  if v_bal.settlement_status <> 'settled' or v_bal.outstanding_amount <> 0 or v_bal.credited_amount <> 200 then
    raise exception 'FAIL: re-raised credit note should settle the item again (%)', to_jsonb(v_bal);
  end if;
  raise notice 'PASS: void reverses the journal, reopens the item, and the amount can be credited again';

  -------------------------------------------------------------------
  -- 10. RLS and anon
  -------------------------------------------------------------------
  select count(*) into v_n from fin_credit_notes where tenant_id = v_tb;
  if v_n <> 0 then raise exception 'FAIL: finance A can see % credit notes of company B', v_n; end if;
  select count(*) into v_n from fin_credit_notes where tenant_id = v_ta;
  if v_n < 6 then raise exception 'FAIL: finance A should see company A''s credit notes (saw %)', v_n; end if;
  select count(*) into v_n from fin_credit_applications where tenant_id = v_tb;
  if v_n <> 0 then raise exception 'FAIL: finance A can see company B credit applications'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cc_a, 'role', 'authenticated')::text, true);
  select count(*) into v_n from fin_credit_notes;
  if v_n = 0 then raise exception 'FAIL: cost_control (finance team) should be able to read credit notes'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_out_a, 'role', 'authenticated')::text, true);
  select count(*) into v_n from fin_credit_notes;
  if v_n <> 0 then raise exception 'FAIL: a non-finance user can read % credit notes', v_n; end if;
  select count(*) into v_n from fin_credit_applications;
  if v_n <> 0 then raise exception 'FAIL: a non-finance user can read % credit applications', v_n; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  select count(*) into v_n from fin_credit_notes;
  if v_n <> 0 then raise exception 'FAIL: finance B should see no credit notes (saw %)', v_n; end if;
  reset role;

  set local role anon;
  perform pg_temp.expect_error('select count(*) from fin_credit_notes', 'permission denied', 'anon reading credit notes');
  perform pg_temp.expect_error('select count(*) from fin_credit_applications', 'permission denied', 'anon reading credit applications');
  perform pg_temp.expect_error(
    format('select fin_raise_credit_note(''ar_control'', %L, 10, current_date, %L, ''[]''::jsonb, ''Test credit note'')', v_client, v_gl_rev),
    'permission denied', 'anon raising a credit note');
  reset role;
  raise notice 'PASS: RLS isolates companies and finance team; anon has no access';

  raise notice 'ALL FIN_CREDIT_NOTES TESTS PASSED';
end
$$;

rollback;
