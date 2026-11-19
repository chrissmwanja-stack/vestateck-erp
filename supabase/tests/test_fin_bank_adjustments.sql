-- D4e functional test: bank adjustments for bank lines with no book entry.
--
-- Covers: finance-only authorization, counter-account rules (control /
-- header / bank-GL rejected, valid accepted), independent approval enforced,
-- pending uniqueness, atomic journal + reconciliation posting, rejected-then-
-- reworked flow, reversal with independent approval un-reconciling the line,
-- closed-period blocking, cross-tenant isolation, and register visibility.
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
create temp table holder (name text primary key, id uuid);
create function pg_temp.hput(p_name text, p_id uuid) returns void language sql as $$
  insert into holder (name, id) values (p_name, p_id) on conflict (name) do update set id = excluded.id
$$;
create function pg_temp.hget(p_name text) returns uuid language sql as $$
  select id from holder where name = p_name
$$;

-- Fixtures (as the table owner)
do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_fin_a uuid := gen_random_uuid();
  v_fin2 uuid := gen_random_uuid();
  v_out_a uuid := gen_random_uuid();
  v_fin_b uuid := gen_random_uuid();
  v_gl_bank uuid; v_gl_charges uuid; v_gl_interest uuid; v_gl_ar uuid; v_gl_header uuid;
  v_gl_bank_b uuid; v_gl_charges_b uuid;
begin
  insert into tenants (id, name) values (v_ta, 'Adj Co A'), (v_tb, 'Adj Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'adj-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_fin_a), (v_fin2), (v_out_a), (v_fin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (v_fin_a, v_ta, 'Adj Finance A',  'adj-' || v_fin_a || '@test.local'),
    (v_fin2,  v_ta, 'Adj Finance A2', 'adj-' || v_fin2  || '@test.local'),
    (v_out_a, v_ta, 'Adj Outsider A', 'adj-' || v_out_a || '@test.local'),
    (v_fin_b, v_tb, 'Adj Finance B',  'adj-' || v_fin_b || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, v_fin_a, 'finance'),
    (v_ta, v_fin2,  'finance'),
    (v_tb, v_fin_b, 'finance');
  -- v_out_a is deliberately not on the finance team.

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_ta, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_ta, '5000', 'Bank Charges', 'expense') returning id into v_gl_charges;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_ta, '4100', 'Interest Received', 'revenue') returning id into v_gl_interest;
  insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
    values (v_ta, '1200', 'Trade Receivables', 'asset', true) returning id into v_gl_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type, is_header)
    values (v_ta, '1060', 'Bank Summary Header', 'asset', true) returning id into v_gl_header;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_tb, '1000', 'Operating Bank B', 'asset') returning id into v_gl_bank_b;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_tb, '5000', 'Bank Charges B', 'expense') returning id into v_gl_charges_b;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    values (v_ta, 'OPS-UGX', 'operating', 'UGX', v_gl_bank);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    values (v_tb, 'OPS-B-UGX', 'operating', 'UGX', v_gl_bank_b);

  -- Closed period covering today for tenant B only.
  insert into accounting_periods (tenant_id, period_start, period_end, status)
    values (v_tb, current_date - 30, current_date + 30, 'closed');

  insert into holder (name, id) values
    ('ta', v_ta), ('tb', v_tb),
    ('fin_a', v_fin_a), ('fin2', v_fin2), ('out_a', v_out_a), ('fin_b', v_fin_b),
    ('gl_bank', v_gl_bank), ('gl_charges', v_gl_charges), ('gl_interest', v_gl_interest),
    ('gl_ar', v_gl_ar), ('gl_header', v_gl_header),
    ('gl_charges_b', v_gl_charges_b)
  on conflict (name) do update set id = excluded.id;
end $$;

-- Import statement lines as the finance user (tenant A: three lines; tenant B: one).
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform import_bank_statement_lines('OPS-UGX', jsonb_build_array(
  jsonb_build_object('statement_date', current_date, 'amount', -30,    'description', 'bank charge',  'reference', 'CHG-1'),
  jsonb_build_object('statement_date', current_date, 'amount',  20000, 'description', 'interest',     'reference', 'INT-1'),
  jsonb_build_object('statement_date', current_date, 'amount', -45,    'description', 'account fees', 'reference', 'FEE-1')
));
reset role;
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_b'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform import_bank_statement_lines('OPS-B-UGX', jsonb_build_array(
  jsonb_build_object('statement_date', current_date, 'amount', -55, 'description', 'fee', 'reference', 'FEE-B')
));
reset role;

-- 1. A non-finance user cannot create an adjustment.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('out_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select create_bank_adjustment(%L, %L, %L)',
         pg_temp.line_id(pg_temp.hget('ta'), -30), pg_temp.hget('gl_charges'), 'bank charge per statement'),
  'not authorized', 'non-finance user creating an adjustment');
reset role;

-- 2. Finance creates a pending adjustment for the bank charge line.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into holder
select 'adj_charge', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('ta'), -30),
                                             pg_temp.hget('gl_charges'),
                                             'bank charge per statement')).id;
reset role;
do $$
declare v public.bank_adjustments%rowtype;
begin
  select * into v from public.bank_adjustments where id = pg_temp.hget('adj_charge');
  if v.status <> 'pending' or v.amount <> 30 or v.direction <> 'out'
     or v.currency <> 'UGX' or v.kind <> 'adjustment' then
    raise exception 'FAIL: pending adjustment wrong: status=% amount=% direction=%', v.status, v.amount, v.direction;
  end if;
end $$;

-- 3. One live adjustment per line.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select create_bank_adjustment(%L, %L, %L)',
         pg_temp.line_id(pg_temp.hget('ta'), -30), pg_temp.hget('gl_charges'), 'duplicate attempt'),
  'ADJ_LIVE_EXISTS', 'duplicate live adjustment');
reset role;

-- 4. The creator cannot approve their own adjustment.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('adj_charge')),
  'ADJ_SELF_APPROVAL_FORBIDDEN', 'creator self-approves');
reset role;

-- 5. Counter-account rules: control, header and bank-GL accounts are rejected.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select create_bank_adjustment(%L, %L, %L)',
         pg_temp.line_id(pg_temp.hget('ta'), 20000), pg_temp.hget('gl_ar'), 'control account attempt'),
  'ADJ_COUNTER_CONTROL', 'control account rejected');
perform pg_temp.expect_error(
  format('select create_bank_adjustment(%L, %L, %L)',
         pg_temp.line_id(pg_temp.hget('ta'), 20000), pg_temp.hget('gl_header'), 'header account attempt'),
  'ADJ_COUNTER_HEADER', 'header account rejected');
perform pg_temp.expect_error(
  format('select create_bank_adjustment(%L, %L, %L)',
         pg_temp.line_id(pg_temp.hget('ta'), 20000), pg_temp.hget('gl_bank'), 'bank gl attempt'),
  'ADJ_COUNTER_BANK', 'bank GL rejected');
reset role;

-- 6. A different finance user approves: journal posted + line reconciled atomically.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare v public.bank_adjustments%rowtype;
begin
  v := approve_bank_adjustment(pg_temp.hget('adj_charge'));
  if v.status <> 'posted' or v.journal_entry_id is null then
    raise exception 'FAIL: approval did not post the adjustment (status %)', v.status;
  end if;
end $$;
reset role;
do $$
declare
  v_adj public.bank_adjustments%rowtype;
  v_je  uuid;
  v_diff numeric;
  v_gl  text;
begin
  select * into v_adj from public.bank_adjustments where id = pg_temp.hget('adj_charge');
  v_je := v_adj.journal_entry_id;
  if (select count(*) from public.journal_entries e where e.id = v_je
        and e.source_type = 'bank_adjustment' and e.source_id = v_adj.id) <> 1 then
    raise exception 'FAIL: adjustment journal entry missing or mis-sourced';
  end if;
  select sum(debit) - sum(credit) into v_diff from public.journal_entry_lines where journal_entry_id = v_je;
  if v_diff <> 0 then raise exception 'FAIL: adjustment journal does not balance (diff %)', v_diff; end if;
  -- Money out: charges debited, bank credited.
  if not exists (select 1 from public.journal_entry_lines l
                  join public.gl_accounts g on g.id = l.gl_account_id
                 where l.journal_entry_id = v_je and g.account_code = '5000' and l.debit = 30) then
    raise exception 'FAIL: bank charges debit line missing';
  end if;
  if not exists (select 1 from public.journal_entry_lines l
                  join public.gl_accounts g on g.id = l.gl_account_id
                 where l.journal_entry_id = v_je and g.account_code = '1000' and l.credit = 30) then
    raise exception 'FAIL: bank credit line missing';
  end if;
  if (select count(*) from public.bank_reconciliations r
       where r.bank_statement_line_id = v_adj.bank_statement_line_id
         and r.bank_adjustment_id = v_adj.id and r.variance = 0) <> 1 then
    raise exception 'FAIL: line was not reconciled to the adjustment journal';
  end if;
end $$;

-- Re-approving a posted adjustment is refused.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('adj_charge')),
  'ADJ_NOT_PENDING', 'double approval');
reset role;

-- 7. Register is visible to finance.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if (select count(*) from public.bank_adjustment_register
       where adjustment_id = pg_temp.hget('adj_charge')
         and approver_id = pg_temp.hget('fin2')) <> 1 then
    raise exception 'FAIL: adjustment missing from the register (or approver wrong)';
  end if;
end $$;
reset role;

-- 8. Reject, then rework a rejected adjustment into a new pending row.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into holder
select 'adj_interest', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('ta'), 20000),
                                               pg_temp.hget('gl_interest'),
                                               'interest per bank statement')).id;
reset role;
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform reject_bank_adjustment(pg_temp.hget('adj_interest'), 'please confirm the interest amount first');
reset role;
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into holder
select 'adj_rework', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('ta'), 20000),
                                             pg_temp.hget('gl_interest'),
                                             'interest confirmed against statement',
                                             pg_temp.hget('adj_interest'))).id;
reset role;
do $$
declare v public.bank_adjustments%rowtype;
begin
  select * into v from public.bank_adjustments where id = pg_temp.hget('adj_rework');
  if v.status <> 'pending' or v.reworked_from <> pg_temp.hget('adj_interest') then
    raise exception 'FAIL: rework row wrong (status %, reworked_from %)', v.status, v.reworked_from;
  end if;
  if not exists (select 1 from public.bank_adjustment_events
                 where adjustment_id = v.id and event = 'reworked') then
    raise exception 'FAIL: rework event missing';
  end if;
end $$;

-- 9. Approve the rework, then reverse it with independent approval.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare v public.bank_adjustments%rowtype;
begin
  v := approve_bank_adjustment(pg_temp.hget('adj_rework'));
  if v.status <> 'posted' then raise exception 'FAIL: rework did not post'; end if;
end $$;
reset role;
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into holder
select 'adj_reversal', (request_bank_adjustment_reversal(pg_temp.hget('adj_rework'),
                                                         'wrong counter-account, reversing')).id;
reset role;
-- The requester cannot self-approve the reversal either.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('adj_reversal')),
  'ADJ_SELF_APPROVAL_FORBIDDEN', 'creator self-approves reversal');
reset role;
-- Independent approval posts the reversal journal and un-reconciles the line.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare v public.bank_adjustments%rowtype;
begin
  v := approve_bank_adjustment(pg_temp.hget('adj_reversal'));
  if v.status <> 'posted' then raise exception 'FAIL: reversal did not complete'; end if;
end $$;
reset role;
do $$
declare
  v_orig public.bank_adjustments%rowtype;
  v_line uuid := pg_temp.line_id(pg_temp.hget('ta'), 20000);
begin
  select * into v_orig from public.bank_adjustments where id = pg_temp.hget('adj_rework');
  if v_orig.status <> 'reversed' then
    raise exception 'FAIL: original adjustment is %, expected reversed', v_orig.status;
  end if;
  if exists (select 1 from public.bank_reconciliations where bank_statement_line_id = v_line) then
    raise exception 'FAIL: line still reconciled after reversal';
  end if;
  if not exists (select 1 from public.journal_entries where source_type = 'bank_adjustment_reversal'
                  and source_id = pg_temp.hget('adj_reversal') and status = 'posted') then
    raise exception 'FAIL: reversal journal missing';
  end if;
  if not exists (select 1 from public.bank_adjustment_events
                 where adjustment_id = v_orig.id and event = 'reversed') then
    raise exception 'FAIL: reversed event missing on the original adjustment';
  end if;
end $$;
-- The line is free again: a replacement adjustment can be submitted.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into holder
select 'adj_replacement', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('ta'), 20000),
                                                  pg_temp.hget('gl_interest'),
                                                  'replacement after reversal')).id;
reset role;
do $$
begin
  if (select status from public.bank_adjustments where id = pg_temp.hget('adj_replacement')) <> 'pending' then
    raise exception 'FAIL: replacement adjustment not pending';
  end if;
end $$;

-- 10. Closed period blocks creation.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_b'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select create_bank_adjustment(%L, %L, %L)',
         pg_temp.line_id(pg_temp.hget('tb'), -55), pg_temp.hget('gl_charges_b'), 'closed period attempt'),
  'ADJ_PERIOD_CLOSED', 'closed period blocks creation');
reset role;

-- 11. Cross-tenant isolation: tenant B finance cannot approve tenant A's adjustment.
perform set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin_b'), 'role', 'authenticated')::text, true);
set local role authenticated;
perform pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('adj_replacement')),
  'ADJ_NOT_FOUND', 'cross-tenant approval');
reset role;

rollback;
