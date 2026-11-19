-- D4e: the one-person self-approval exception requires a REVIEWED setting.
--
-- 20261119220000 moved approve_bank_adjustment off acct_get_setting and onto
-- acct_assert_reviewed, because allow_self_approved_bank_adjustments is a
-- requires_legal_review key: an admin approving the choice is not the same as
-- an accountant having reviewed it. This file pins that in three states:
--
--   1. approved but not reviewed  -> self-approval refused, can_self_approve false
--   2. reviewed as well           -> self-approval allowed, mode recorded
--   3. no setting at all          -> refused (unchanged from before)
--
-- and that a DIFFERENT finance user is unaffected throughout: the exception is
-- only ever about approving your own submission.
--
-- Run against a fresh local stack; everything rolls back. A RAISE EXCEPTION
-- fails the file (same convention as the other files here).

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

do $$
declare
  v_t    uuid := gen_random_uuid();
  v_mk   uuid := gen_random_uuid();
  v_ck   uuid := gen_random_uuid();
  v_gl_bank uuid; v_gl_charges uuid;
begin
  insert into tenants (id, name) values (v_t, 'Self Approval Review Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'sar-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_mk), (v_ck)) as u(id);

  -- Both are company admins as well as finance team members, so the review can
  -- be recorded by the other one without a separate persona.
  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (v_mk, v_t, 'Self Maker',   'sar-' || v_mk || '@test.local', true),
    (v_ck, v_t, 'Self Checker', 'sar-' || v_ck || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_t, v_mk, 'finance'), (v_t, v_ck, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_t, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_t, '5000', 'Bank Charges', 'expense') returning id into v_gl_charges;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    values (v_t, 'SAR-UGX', 'operating', 'UGX', v_gl_bank);

  insert into holder (name, id) values
    ('t', v_t), ('mk', v_mk), ('ck', v_ck),
    ('gl_bank', v_gl_bank), ('gl_charges', v_gl_charges)
  on conflict (name) do update set id = excluded.id;
end $$;

-- One statement line per scenario, so each can be adjusted independently.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('mk'), 'role', 'authenticated')::text, true);
set local role authenticated;
select import_bank_statement_lines('SAR-UGX', jsonb_build_array(
  jsonb_build_object('statement_date', current_date, 'amount', -1000, 'description', 'charge A', 'reference', 'A'),
  jsonb_build_object('statement_date', current_date, 'amount', -2000, 'description', 'charge B', 'reference', 'B'),
  jsonb_build_object('statement_date', current_date, 'amount', -3000, 'description', 'charge C', 'reference', 'C')
));
reset role;

-- ---------------------------------------------------------------------------
-- 1. No setting at all: refused, and the screen says no.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('mk'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if bank_adjustment_can_self_approve() is not false then
    raise exception 'FAIL: can_self_approve must be false with no setting configured';
  end if;
end $$;
select pg_temp.hput('adj_c', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('t'), -3000),
                                                     pg_temp.hget('gl_charges'), 'charge C reason')).id);
select pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('adj_c')),
  'ADJ_SELF_APPROVAL_FORBIDDEN', 'self-approval with no setting at all');
reset role;
do $$ begin raise notice 'PASS: no setting means no self-approval'; end $$;

-- ---------------------------------------------------------------------------
-- 2. Approved, but NOT reviewed: still refused.
--    Proposed by the maker and approved by the checker through the real
--    functions: company_accounting_settings_guard refuses a new row that arrives
--    already approved, so a direct insert cannot produce this state (nor should
--    it). That workflow itself is covered by test_acct_config_stabilisation.sql;
--    what matters here is the approved-but-unreviewed state.

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

select pg_temp.grant_one_person_exception(pg_temp.hget('mk'), pg_temp.hget('ck'), 'not reviewed yet');

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('mk'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if bank_adjustment_can_self_approve() is not false then
    raise exception 'FAIL: can_self_approve must be false when the setting is approved but unreviewed';
  end if;
end $$;
select pg_temp.hput('adj_a', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('t'), -1000),
                                                     pg_temp.hget('gl_charges'), 'charge A reason')).id);
select pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('adj_a')),
  'ADJ_SELF_APPROVAL_FORBIDDEN', 'self-approval on an approved-but-unreviewed setting');

-- A different finance user can still approve it: the exception is irrelevant
-- to them, and this is the control the whole feature exists for.
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('ck'), 'role', 'authenticated')::text, true);
set local role authenticated;
select approve_bank_adjustment(pg_temp.hget('adj_a'));
reset role;
do $$
declare v_mode text; v_self boolean;
begin
  select approval_mode, self_approved into v_mode, v_self
    from public.bank_adjustments where id = pg_temp.hget('adj_a');
  if v_mode is distinct from 'two_person' or v_self then
    raise exception 'FAIL: expected two_person, got mode=% self=%', v_mode, v_self;
  end if;
  raise notice 'PASS: an approved-but-unreviewed exception blocks self-approval and not independent approval';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Record the review: now the exception is in force and self-approval works.
-- ---------------------------------------------------------------------------
select pg_temp.record_review(pg_temp.hget('ck'), 'Review memo 2026-11-19');

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('mk'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if bank_adjustment_can_self_approve() is not true then
    raise exception 'FAIL: can_self_approve must be true once the review is recorded';
  end if;
end $$;
select pg_temp.hput('adj_b', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('t'), -2000),
                                                     pg_temp.hget('gl_charges'), 'charge B reason')).id);
select approve_bank_adjustment(pg_temp.hget('adj_b'));
reset role;

do $$
declare v_mode text; v_self boolean;
begin
  select approval_mode, self_approved into v_mode, v_self
    from public.bank_adjustments where id = pg_temp.hget('adj_b');
  if v_mode is distinct from 'one_person_exception' or v_self is not true then
    raise exception 'FAIL: expected one_person_exception + self_approved, got mode=% self=%', v_mode, v_self;
  end if;
  raise notice 'PASS: a reviewed exception permits self-approval and is recorded as such';
end $$;

rollback;
