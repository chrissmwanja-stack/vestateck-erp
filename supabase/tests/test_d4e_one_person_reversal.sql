-- D4e: a one-person finance team can complete a reversal.
--
-- The gap this pins: reversal is a request plus an approval, and the request
-- row's creator is whoever raised it. If that is also the person who created
-- the original adjustment (the normal case in a one-person team), the approval
-- raised ADJ_SELF_APPROVAL_FORBIDDEN and the reversal could never complete, so
-- a wrong posting stayed posted forever. 20261119235950 applies the same
-- creator/actor test to reversals that adjustments already had.
--
-- Four states are checked:
--   1. no exception          -> self-approving your own reversal is refused;
--   2. another user approves -> allowed (unchanged, the two-person control);
--   3. approved but unreviewed exception -> still refused;
--   4. reviewed exception    -> your own reversal is allowed, recorded as
--                              one_person_exception on the reversal row.
--
-- Run against a fresh local stack; everything rolls back.

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
  v_t   uuid := gen_random_uuid();
  v_one uuid := gen_random_uuid();   -- the whole finance team
  v_two uuid := gen_random_uuid();   -- a second finance user, for state 2
  v_gl_bank uuid; v_gl_charges uuid;
begin
  insert into tenants (id, name) values (v_t, 'One Person Rev Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'opr-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_one), (v_two)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (v_one, v_t, 'Only Finance Person', 'opr-' || v_one || '@test.local', true),
    (v_two, v_t, 'Second Finance',      'opr-' || v_two || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_t, v_one, 'finance'), (v_t, v_two, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_t, '1000', 'Operating Bank', 'asset') returning id into v_gl_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (v_t, '5000', 'Bank Charges', 'expense') returning id into v_gl_charges;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    values (v_t, 'OPR-UGX', 'operating', 'UGX', v_gl_bank);

  insert into holder (name, id) values
    ('t', v_t), ('one', v_one), ('two', v_two),
    ('gl_bank', v_gl_bank), ('gl_charges', v_gl_charges)
  on conflict (name) do update set id = excluded.id;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('one'), 'role', 'authenticated')::text, true);
set local role authenticated;
select import_bank_statement_lines('OPR-UGX', jsonb_build_array(
  jsonb_build_object('statement_date', current_date, 'amount', -5000, 'description', 'charge', 'reference', 'R1'),
  jsonb_build_object('statement_date', current_date, 'amount', -6000, 'description', 'charge 2', 'reference', 'R2')
));
reset role;

-- ---------------------------------------------------------------------------
-- 1. No exception: the one-person team is stuck, which is the bug.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('one'), 'role', 'authenticated')::text, true);
set local role authenticated;

select pg_temp.hput('adj1', (create_bank_adjustment(pg_temp.line_id(pg_temp.hget('t'), -5000),
                                                    pg_temp.hget('gl_charges'), 'monthly charge')).id);
select pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('adj1')),
  'ADJ_SELF_APPROVAL_FORBIDDEN', 'self-approving your own adjustment');

-- A different person posts it, so there is something to reverse.
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('two'), 'role', 'authenticated')::text, true);
set local role authenticated;
select approve_bank_adjustment(pg_temp.hget('adj1'));
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('one'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.hput('rev1', (request_bank_adjustment_reversal(pg_temp.hget('adj1'), 'posted against the wrong account')).id);
select pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('rev1')),
  'ADJ_SELF_APPROVAL_FORBIDDEN', 'self-approving your own reversal request with no exception');
reset role;
do $$ begin raise notice 'PASS: with no exception, your own reversal cannot be approved (the gap this fixes)'; end $$;

-- ---------------------------------------------------------------------------
-- 3. Approved but UNREVIEWED exception: still refused.
-- ---------------------------------------------------------------------------
do $$
declare v_t uuid := pg_temp.hget('t');
begin
  insert into public.company_accounting_settings (
    tenant_id, setting_key, value, effective_from, status, rationale,
    approved_by, approved_at, created_by
  ) values (
    v_t, 'allow_self_approved_bank_adjustments', 'true', current_date, 'approved',
    'one person finance team, review still outstanding',
    pg_temp.hget('two'), now(), pg_temp.hget('one')
  );
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('one'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.expect_error(
  format('select approve_bank_adjustment(%L)', pg_temp.hget('rev1')),
  'ADJ_SELF_APPROVAL_FORBIDDEN', 'self-approving a reversal on an unreviewed exception');
reset role;
do $$ begin raise notice 'PASS: an unreviewed exception still blocks self-approval of a reversal'; end $$;

-- ---------------------------------------------------------------------------
-- 4. Record the review: the one-person team can now complete the reversal.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('two'), 'role', 'authenticated')::text, true);
set local role authenticated;
select acct_setting_record_review(
  (select id from public.company_accounting_settings
    where tenant_id = pg_temp.hget('t')
      and setting_key = 'allow_self_approved_bank_adjustments'
      and status = 'approved' limit 1),
  'External Accountant', 'Review memo 2026-11-19 (reversal)');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.hget('one'), 'role', 'authenticated')::text, true);
set local role authenticated;
select approve_bank_adjustment(pg_temp.hget('rev1'));
reset role;

do $$
declare
  v_orig_status text;
  v_rev_status  text;
  v_mode        text;
  v_self        boolean;
  v_recon       int;
begin
  select status into v_orig_status from public.bank_adjustments where id = pg_temp.hget('adj1');
  select status, approval_mode, self_approved into v_rev_status, v_mode, v_self
    from public.bank_adjustments where id = pg_temp.hget('rev1');
  select count(*) into v_recon from public.bank_reconciliations where bank_adjustment_id = pg_temp.hget('adj1');

  if v_orig_status is distinct from 'reversed' then
    raise exception 'FAIL: original should be reversed, is %', v_orig_status;
  end if;
  if v_rev_status is distinct from 'posted' then
    raise exception 'FAIL: reversal should be posted, is %', v_rev_status;
  end if;
  if v_mode is distinct from 'one_person_exception' or v_self is not true then
    raise exception 'FAIL: reversal should be recorded as one_person_exception; mode=% self=%', v_mode, v_self;
  end if;
  if v_recon <> 0 then
    raise exception 'FAIL: the statement line should be unmatched again, % reconciliation rows remain', v_recon;
  end if;
  raise notice 'PASS: a reviewed exception lets one person complete a reversal, and the line is unmatched again';
end $$;

rollback;
