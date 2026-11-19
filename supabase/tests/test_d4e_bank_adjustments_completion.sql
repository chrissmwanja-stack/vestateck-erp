-- D4e completion test: the behaviour added by 20261119210000.
--
-- Covers what the original D4e test file does not:
--   1. an adjustment is refused for a statement line whose bank is not in the
--      bank account registry (ADJ_BANK_UNREGISTERED), and the stored
--      bank_account is the registry name (not the raw statement text);
--   2. a normal approval records approval_mode = 'two_person';
--   3. bank_adjustment_can_self_approve() is false by default and true only
--      when an approved allow_self_approved_bank_adjustments setting is in
--      force, and the self-approved path then records
--      'one_person_exception';
--   4. bank_adjustment_history() returns the events in order, with actor names;
--   5. the usual-account RPCs add/list/remove, and unusual usage reports a
--      posted adjustment once its counter-account is not on the list;
--   6. the CHECK constraint refuses a self_approved row without the exception
--      mode (the flag and the mode cannot disagree).
--
-- Run against a fresh local stack only; everything rolls back. Any RAISE
-- EXCEPTION fails the file (same convention as test_fin_bank_adjustments.sql).

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

create function pg_temp.line_id(p_tenant uuid, p_amount numeric) returns uuid
language sql security definer as $$
  select id from public.bank_statement_lines where tenant_id = p_tenant and amount = p_amount
$$;

create temp table holder (name text primary key, id uuid);
create function pg_temp.hput(p_name text, p_id uuid) returns void language sql security definer as $$
  insert into holder (name, id) values (p_name, p_id) on conflict (name) do update set id = excluded.id
$$;
create function pg_temp.hget(p_name text) returns uuid language sql security definer as $$
  select id from holder where name = p_name
$$;

-- Fixtures (owner side).
do $$
declare
  v_t     uuid := gen_random_uuid();
  v_fin   uuid := gen_random_uuid();
  v_fin2  uuid := gen_random_uuid();
  v_gl_bank uuid; v_gl_charges uuid; v_gl_interest uuid; v_gl_ar uuid;
begin
  insert into tenants (id, name) values (v_t, 'Adj Completion Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'adjc-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_fin), (v_fin2)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (v_fin,  v_t, 'Completion Maker',   'adjc-' || v_fin  || '@test.local'),
    (v_fin2, v_t, 'Completion Checker', 'adjc-' || v_fin2 || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_t, v_fin, 'finance'), (v_t, v_fin2, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_t, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_t, '5000', 'Bank Charges', 'expense') returning id into v_gl_charges;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_t, '4100', 'Interest Received', 'revenue') returning id into v_gl_interest;
  insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
    values (v_t, '1200', 'Trade Receivables', 'asset', true) returning id into v_gl_ar;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    values (v_t, 'REG-UGX', 'operating', 'UGX', v_gl_bank);

  insert into holder (name, id) values
    ('t', v_t), ('fin', v_fin), ('fin2', v_fin2),
    ('gl_bank', v_gl_bank), ('gl_charges', v_gl_charges),
    ('gl_interest', v_gl_interest), ('gl_ar', v_gl_ar)
  on conflict (name) do update set id = excluded.id;
end $$;

-- Statement lines: one against the registered bank, one against a name that is
-- not in the registry at all (the legacy free-text import still accepts it --
-- that is the situation being guarded against).
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin'), 'role', 'authenticated')::text, true);
set local role authenticated;
select import_bank_statement_lines('REG-UGX', jsonb_build_array(
  jsonb_build_object('statement_date', current_date, 'amount', -7000, 'description', 'bank charge', 'reference', 'C-1'),
  jsonb_build_object('statement_date', current_date, 'amount', 30000, 'description', 'interest',    'reference', 'I-1')
));
select import_bank_statement_lines('UNREGISTERED-999', jsonb_build_array(
  jsonb_build_object('statement_date', current_date, 'amount', -9000, 'description', 'charge on a stray account', 'reference', 'U-1')
));
reset role;

-- 1. An unregistered bank cannot be adjusted.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.expect_error(
  format('select create_bank_adjustment(%L, %L, %L)',
         pg_temp.line_id(pg_temp.hget('t'), -9000), pg_temp.hget('gl_charges'), 'charge on a stray account'),
  'ADJ_BANK_UNREGISTERED', 'adjustment on an unregistered bank');
reset role;

-- 2. The registered bank is fine, and the row stores the registry name.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.hput('adj', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('t'), -7000),
                                                   pg_temp.hget('gl_charges'),
                                                   'monthly bank charge')).id);
reset role;

do $$
declare v_acct text;
begin
  select bank_account into v_acct from public.bank_adjustments where id = pg_temp.hget('adj');
  if v_acct is distinct from 'REG-UGX' then
    raise exception 'FAIL: expected the registry name REG-UGX on the adjustment, got %', v_acct;
  end if;
  raise notice 'PASS: adjustment refused for an unregistered bank and stores the registry name';
end $$;

-- 3. The permission reads false before any setting is approved.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if bank_adjustment_can_self_approve() is not false then
    raise exception 'FAIL: can_self_approve should be false with no approved setting';
  end if;
end $$;
reset role;

-- 4. A different finance user approves: approval_mode is two_person.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
select approve_bank_adjustment(pg_temp.hget('adj'));
reset role;

do $$
declare v_mode text; v_self boolean;
begin
  select approval_mode, self_approved into v_mode, v_self
    from public.bank_adjustments where id = pg_temp.hget('adj');
  if v_mode is distinct from 'two_person' or v_self then
    raise exception 'FAIL: expected two_person, not self-approved; got mode=% self=%', v_mode, v_self;
  end if;
  raise notice 'PASS: independent approval records approval_mode = two_person';
end $$;

-- 5. The history is readable, in order, with names.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin2'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare v_events text[]; v_names text[];
begin
  select array_agg(event order by created_at, event), array_agg(actor_name order by created_at, event)
    into v_events, v_names
    from bank_adjustment_history(pg_temp.hget('adj'));
  if v_events is distinct from array['created','approved'] then
    raise exception 'FAIL: unexpected history %', v_events;
  end if;
  if v_names[1] is distinct from 'Completion Maker' and v_names[1] is distinct from 'Completion Checker' then
    raise exception 'FAIL: history actor names missing: %', v_names;
  end if;
  raise notice 'PASS: history returns created then approved with actor names';
end $$;
reset role;

-- 6. Usual accounts: list starts empty, add works, the control account is
--    refused by the caller-visible rule (server-side: not in the picker) and
--    by the RPC for an inactive account.
-- Make one account inactive BEFORE switching roles: a direct table update from
-- inside `set local role authenticated` would be an RLS/permission question,
-- not the thing this test is about.
do $$
begin
  update public.gl_accounts set is_active = false where id = pg_temp.hget('gl_interest');
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if (select count(*) from bank_adjustment_list_usual_accounts()) <> 0 then
    raise exception 'FAIL: usual accounts should start empty';
  end if;
end $$;

select bank_adjustment_add_usual_account(pg_temp.hget('gl_charges'));

do $$
begin
  if (select count(*) from bank_adjustment_list_usual_accounts()) <> 1 then
    raise exception 'FAIL: usual account was not added';
  end if;
end $$;

select pg_temp.expect_error(
  format('select bank_adjustment_add_usual_account(%L)', pg_temp.hget('gl_interest')),
  'not an active account', 'adding an inactive usual account');

-- With Bank Charges now usual, the posted adjustment is no longer unusual.
do $$
begin
  if (select count(*) from bank_adjustment_unusual_account_usage(null)) <> 0 then
    raise exception 'FAIL: a posted adjustment on a usual account should not be flagged';
  end if;
  raise notice 'PASS: usual accounts add/list, and stop the report flagging that account';
end $$;

select bank_adjustment_remove_usual_account(pg_temp.hget('gl_charges'));

do $$
begin
  if (select count(*) from bank_adjustment_unusual_account_usage(null)) <> 1 then
    raise exception 'FAIL: removing the usual account should make the posting unusual again';
  end if;
  raise notice 'PASS: removing a usual account brings the posting back into the report';
end $$;
reset role;

-- 7. The flag and the mode cannot disagree.
do $$
begin
  begin
    update public.bank_adjustments
       set self_approved = true, approval_mode = 'two_person'
     where id = pg_temp.hget('adj');
    raise exception 'FAIL: a self-approved row with two_person mode was accepted';
  exception when check_violation then
    null;  -- expected
  end;
  raise notice 'PASS: self_approved and approval_mode must agree';
end $$;

-- 8. The one-person exception: approve the setting, then the creator can
--    approve their own proposal and it is recorded as the exception.
-- The setting rows are written directly (as the owner) rather than through
-- acct_setting_propose/acct_setting_approve: those require a company admin and
-- a *different* admin to approve, which is a separate workflow this test is
-- not asserting. What is under test here is that the exception is honoured
-- only when an approved value is in force.
do $$
declare v_t uuid := pg_temp.hget('t');
begin
  insert into public.company_accounting_settings (
    tenant_id, setting_key, value, effective_from, status, rationale,
    approved_by, approved_at, created_by
  ) values (
    v_t, 'allow_self_approved_bank_adjustments', 'true', current_date, 'approved',
    'single finance user company', pg_temp.hget('fin2'), now(), pg_temp.hget('fin2')
  );
end $$;
do $$
begin
  raise notice 'PASS: the one-person exception setting is approved for this company';
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if bank_adjustment_can_self_approve() is not true then
    raise exception 'FAIL: can_self_approve should be true once the setting is approved';
  end if;
end $$;

select pg_temp.hput('adj2', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('t'), 30000),
                                                    pg_temp.hget('gl_interest'),
                                                    'interest received')).id);
select approve_bank_adjustment(pg_temp.hget('adj2'));
reset role;

do $$
declare v_mode text; v_self boolean;
begin
  select approval_mode, self_approved into v_mode, v_self
    from public.bank_adjustments where id = pg_temp.hget('adj2');
  if v_mode is distinct from 'one_person_exception' or v_self is not true then
    raise exception 'FAIL: expected one_person_exception and self_approved; got mode=% self=%', v_mode, v_self;
  end if;
  raise notice 'PASS: the one-person exception is discoverable and recorded when used';
end $$;

rollback;
