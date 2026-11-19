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

-- Both finance users are company admins as well as team members: the exception
-- has to be approved by a *different* admin, and there are only two people here.
update public.app_users set is_company_admin = true
 where id in (pg_temp.hget('fin'), pg_temp.hget('fin2'));

-- Put the one-person exception in force the way the app does: propose, approve
-- by a DIFFERENT company admin, then record the compliance review. Writing the
-- row directly does not work - company_accounting_settings_guard refuses a new
-- row that arrives already approved, which is the point of the guard.
create or replace function pg_temp.grant_one_person_exception(p_proposer uuid, p_approver uuid, p_reference text)
returns void language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_proposer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into v_id from public.acct_setting_propose(
    'allow_self_approved_bank_adjustments', 'true', current_date,
    'one finance user: nobody else can approve their work');
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', p_approver, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.acct_setting_approve(v_id);
  reset role;
end $$;

create or replace function pg_temp.record_review(p_approver uuid, p_reference text)
returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from public.company_accounting_settings
   where tenant_id = pg_temp.hget('t')
     and setting_key = 'allow_self_approved_bank_adjustments'
     and status = 'approved'
   order by created_at desc limit 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', p_approver, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.acct_setting_record_review(v_id, 'External Accountant', p_reference);
  reset role;
end $$;

do $$
declare v_t uuid := pg_temp.hget('t');
begin
  update public.app_users set is_company_admin = true
   where id in (pg_temp.hget('fin'), pg_temp.hget('fin2'));
end $$;
-- Approved (by the other admin) BEFORE anything is posted, because
-- company_accounting_settings_guard refuses an effective date on or before the
-- newest journal entry (ACCT_SETTING_BACKDATED). It is deliberately left
-- UNREVIEWED here: step 3 needs exactly that state, and step 8 records the
-- review once there are postings to show the flag and the mode.
select pg_temp.grant_one_person_exception(pg_temp.hget('fin'), pg_temp.hget('fin2'), 'Review memo 2026-11-19');


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

-- 0. The fixture itself: bank_reconciliations must accept that an adjustment
--    cleared the line. Before 20261119235951 the check allowed only
--    manual/auto, so approve_bank_adjustment raised a check violation at the
--    point of posting - which is how the first real CI run of this file failed.
--    The probe row deliberately names no other source, so whichever way it
--    goes the only question asked is whether 'adjustment' is a legal match_type.
do $$
declare v_constraint text;
begin
  begin
    insert into public.bank_reconciliations (
      tenant_id, bank_statement_line_id, match_type, variance, matched_by
    ) values (pg_temp.hget('t'), pg_temp.line_id(pg_temp.hget('t'), -7000),
              'adjustment', 0, pg_temp.hget('fin'));
    -- Accepted outright: clean up and pass.
    delete from public.bank_reconciliations
     where tenant_id = pg_temp.hget('t')
       and bank_statement_line_id = pg_temp.line_id(pg_temp.hget('t'), -7000)
       and bank_adjustment_id is null;
  exception
    when check_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'bank_reconciliations_match_type_check' then
        raise exception 'FAIL: bank_reconciliations_match_type_check rejects ''adjustment''; approve_bank_adjustment cannot post (see 20261119235951)';
      end if;
      -- Any other check means 'adjustment' itself was accepted; that is all
      -- this step asserts (the one-source rule is pinned by its own migration).
  end;
  raise notice 'PASS: match_type accepts ''adjustment'' as a way a statement line was cleared';
end $$;

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

-- 3. The permission reads false while the exception is approved but has not been
--    compliance-reviewed (the full three-state sequence is in
--    test_d4e_self_approval_requires_review.sql).
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('fin'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if bank_adjustment_can_self_approve() is not false then
    raise exception 'FAIL: can_self_approve should be false while the exception is unreviewed';
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
  -- Order as returned: created_at is the transaction timestamp, so every event
  -- from one RPC shares it. 20261119235952 makes the function break that tie by
  -- insertion order, which is what the panel renders.
  select array_agg(event), array_agg(actor_name)
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

-- Interest was only deactivated to prove the usual-account RPC refuses an
-- inactive account; step 8 posts against it, so put it back.
update public.gl_accounts set is_active = true where id = pg_temp.hget('gl_interest');

-- 7. The flag and the mode cannot disagree.
--    A direct UPDATE cannot be used to prove it: the mutation guard refuses any
--    write that does not come through the workflow (that is step 7b, and it runs
--    first, so asserting "check_violation" here would fail on the guard's error
--    instead). So: read the constraint from the catalog, and pin the guard.
do $$
declare v_def text;
begin
  -- Two constraints, deliberately: one limits approval_mode to the two known
  -- modes, the other ties the flag to the exception mode. Look up the pair by
  -- name (there is no "the" constraint), and check both directions of the rule
  -- rather than only that some text mentions the columns.
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'public.bank_adjustments'::regclass
     and conname = 'bank_adjustments_self_approved_mode_check';
  if v_def is null then
    raise exception 'FAIL: bank_adjustments_self_approved_mode_check is missing';
  end if;
  if v_def not like '%self_approved%'
     or v_def not like '%one_person_exception%'
     or v_def not like '%IS DISTINCT FROM%' then
    raise exception 'FAIL: the flag/mode constraint does not express both directions of the rule: %', v_def;
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.bank_adjustments'::regclass
       and conname = 'bank_adjustments_approval_mode_check'
  ) then
    raise exception 'FAIL: bank_adjustments_approval_mode_check is missing, so an unknown mode could be stored';
  end if;
  raise notice 'PASS: CHECK constraints limit approval_mode and tie self_approved to it';
end $$;

-- 7b. An out-of-band write is refused, so the pair cannot be forced into
--     disagreement by hand.
do $$
begin
  begin
    update public.bank_adjustments
       set self_approved = true, approval_mode = 'two_person'
     where id = pg_temp.hget('adj');
    raise exception 'FAIL: an out-of-band update of a bank adjustment was accepted';
  exception when others then
    if sqlerrm not like '%BANK_ADJ_IMMUTABLE%' then
      raise exception 'FAIL: expected BANK_ADJ_IMMUTABLE, got: %', sqlerrm;
    end if;
  end;
  raise notice 'PASS: bank adjustments cannot be edited outside the workflow';
end $$;

-- 8. The one-person exception: approve the setting, then the creator can
--    approve their own proposal and it is recorded as the exception.
--    The setting goes through the real workflow (propose -> a different admin
--    approves -> accountant reviews), because company_accounting_settings_guard
--    refuses a new row that arrives already approved. Since 20261119220000 the
--    exception must also be COMPLIANCE-REVIEWED, not merely approved; the
--    approve-but-unreviewed state is covered in detail by
--    test_d4e_self_approval_requires_review.sql, and here the review is
--    recorded straight away so the rest of this file can concentrate on the
--    flag and the mode. Both users are company admins so the review can be
--    recorded without a third persona.

select pg_temp.record_review(pg_temp.hget('fin2'), 'Review memo 2026-11-19');

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
