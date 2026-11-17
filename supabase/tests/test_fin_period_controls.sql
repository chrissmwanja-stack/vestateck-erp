-- =====================================================================
-- Finance A: accounting period close / reopen controls
-- =====================================================================
--
-- Proves migration 20261117130000:
--
--   1. Only the RPCs can change a period: an authenticated finance user
--      can no longer UPDATE or DELETE accounting_periods directly.
--   2. Close is idempotent and logged.
--   3. Reopen requires a reason, and requires a DIFFERENT finance user
--      from the one who closed it (maker-checker / segregation of duties).
--   4. A closed period still blocks postings through the gateway, and
--      reopening restores posting -- the round trip.
--   5. A period with postings inside it cannot be deleted; an empty one can.
--   6. Journal rows cannot be DELETEd by a client role (privilege revoked),
--      independent of the immutability trigger.
--   7. Tenant isolation: a finance user of another company cannot close or
--      reopen this company's periods.
--
-- One transaction, ROLLBACKs at the end.
-- =====================================================================

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

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_fin1 uuid := gen_random_uuid();   -- closes
  v_fin2 uuid := gen_random_uuid();   -- reopens (different user)
  v_finb uuid := gen_random_uuid();   -- finance of another tenant
  v_cc   uuid := gen_random_uuid();   -- on the team, wrong role
  v_gl_cash uuid; v_gl_inc uuid;
  v_period uuid;
  v_period_empty uuid;
  v_je uuid;
  v_p accounting_periods%rowtype;
  v_n int;
  v_status text;
begin
  ------------------------------------------------------------------
  -- Fixtures
  ------------------------------------------------------------------
  insert into tenants (id, name, industry_template)
  values (v_ta, 'Period Controls A', 'general'), (v_tb, 'Period Controls B', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'period-' || u.id || '@test.local',
         extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_fin1), (v_fin2), (v_finb), (v_cc)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (v_fin1, v_ta, 'Period Fin One', 'period-' || v_fin1 || '@test.local'),
    (v_fin2, v_ta, 'Period Fin Two', 'period-' || v_fin2 || '@test.local'),
    (v_cc,   v_ta, 'Period Cost Control', 'period-' || v_cc || '@test.local'),
    (v_finb, v_tb, 'Period Fin B', 'period-' || v_finb || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, v_fin1, 'finance'),
    (v_ta, v_fin2, 'finance'),
    (v_ta, v_cc,   'cost_control'),
    (v_tb, v_finb, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_ta, '1000', 'Cash', 'asset') returning id into v_gl_cash;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_ta, '4000', 'Income', 'revenue') returning id into v_gl_inc;

  -- A period covering the current month, and a separate empty future one.
  insert into accounting_periods (tenant_id, period_start, period_end)
  values (v_ta, date_trunc('month', current_date)::date,
                (date_trunc('month', current_date) + interval '1 month - 1 day')::date)
  returning id into v_period;

  insert into accounting_periods (tenant_id, period_start, period_end)
  values (v_ta, date '2031-01-01', date '2031-01-31')
  returning id into v_period_empty;

  ------------------------------------------------------------------
  -- 1. Direct writes are gone for a finance user
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin1, 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform pg_temp.expect_error(
    format('update accounting_periods set status = ''closed'' where id = %L', v_period),
    'permission denied', 'direct UPDATE of accounting_periods by a finance user');

  perform pg_temp.expect_error(
    format('delete from accounting_periods where id = %L', v_period),
    'permission denied', 'direct DELETE of accounting_periods by a finance user');

  reset role;
  raise notice 'PASS: accounting_periods can no longer be UPDATEd or DELETEd directly';

  ------------------------------------------------------------------
  -- 2. Close: works, is idempotent, is logged
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_p := fin_close_accounting_period(v_period, 'month end');
  reset role;

  if v_p.status <> 'closed' then
    raise exception 'FAIL: close did not set status, got %', v_p.status;
  end if;

  select count(*) into v_n from accounting_period_events
  where period_id = v_period and action = 'close';
  if v_n <> 1 then
    raise exception 'FAIL: expected 1 close event, found %', v_n;
  end if;

  -- Idempotent second close: no second event.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform fin_close_accounting_period(v_period, 'month end again');
  reset role;

  select count(*) into v_n from accounting_period_events
  where period_id = v_period and action = 'close';
  if v_n <> 1 then
    raise exception 'FAIL: closing twice created % close events, expected 1', v_n;
  end if;
  raise notice 'PASS: close is idempotent and logged once';

  ------------------------------------------------------------------
  -- 3. Reopen needs a reason, and a different user
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin1, 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform pg_temp.expect_error(
    format('select fin_reopen_accounting_period(%L, %L)', v_period, 'too short'),
    'at least 10 characters', 'reopen with a short reason');

  -- Same user who closed it -> refused.
  perform pg_temp.expect_error(
    format('select fin_reopen_accounting_period(%L, %L)', v_period,
           'reopening because we found a late invoice'),
    'SEGREGATION_OF_DUTIES', 'reopen by the same user who closed it');
  reset role;
  raise notice 'PASS: reopen needs a real reason and a second finance user';

  -- The wrong role is refused too.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_cc, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select fin_reopen_accounting_period(%L, %L)', v_period,
           'cost control should not be able to reopen this'),
    'not authorized', 'reopen by a cost_control user');
  reset role;

  -- A different finance user succeeds, and it is logged.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_p := fin_reopen_accounting_period(v_period, 'late supplier invoice arrived after close');
  reset role;

  if v_p.status <> 'open' then
    raise exception 'FAIL: reopen did not set status open, got %', v_p.status;
  end if;

  select count(*) into v_n from accounting_period_events
  where period_id = v_period and action = 'reopen';
  if v_n <> 1 then
    raise exception 'FAIL: expected 1 reopen event, found %', v_n;
  end if;

  select note into v_status from accounting_period_events
  where period_id = v_period and action = 'reopen';
  if v_status is null or v_status not like '%late supplier invoice%' then
    raise exception 'FAIL: reopen event did not record the reason, got %', v_status;
  end if;
  raise notice 'PASS: a second finance user reopened it and the reason was recorded';

  ------------------------------------------------------------------
  -- 4. Closed still blocks posting; reopened allows it (the round trip)
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform fin_close_accounting_period(v_period, 'closing again for the round trip');
  reset role;

  perform pg_temp.expect_error(
    format($q$select post_journal_entry(%L, 'manual', gen_random_uuid(), current_date, 'blocked', %s)$q$,
           v_ta,
           format('jsonb_build_array(jsonb_build_object(''gl_account_id'', %L, ''debit'', 10, ''credit'', 0, ''currency'', ''UGX''), jsonb_build_object(''gl_account_id'', %L, ''debit'', 0, ''credit'', 10, ''currency'', ''UGX''))', v_gl_cash, v_gl_inc)),
    'closed accounting period', 'posting into a closed period');

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform fin_reopen_accounting_period(v_period, 'reopening so the round trip can post again');
  reset role;

  v_je := (post_journal_entry(
    v_ta, 'manual', gen_random_uuid(), current_date, 'allowed after reopen',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_gl_cash, 'debit', 10, 'credit', 0, 'currency', 'UGX'),
      jsonb_build_object('gl_account_id', v_gl_inc,  'debit', 0, 'credit', 10, 'currency', 'UGX')
    )
  )).id;

  if v_je is null then
    raise exception 'FAIL: posting after reopen did not produce an entry';
  end if;
  raise notice 'PASS: closing blocks postings and reopening restores them';

  ------------------------------------------------------------------
  -- 5. Delete: refused while journals fall inside, allowed when empty
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select fin_delete_accounting_period(%L, %L)', v_period,
           'trying to delete a period that has journals'),
    'cannot delete this accounting period', 'delete a period containing journals');

  -- The empty future period can go, and the delete is logged.
  perform fin_delete_accounting_period(v_period_empty, 'created in error, no activity');
  reset role;

  select count(*) into v_n from accounting_periods where id = v_period_empty;
  if v_n <> 0 then
    raise exception 'FAIL: empty period was not deleted';
  end if;
  -- The delete event survives the period (period_id is ON DELETE SET NULL),
  -- so it is found by its snapshotted range rather than by period_id. That is
  -- the point of the snapshot: a delete stays fully described afterwards.
  select count(*) into v_n from accounting_period_events
  where tenant_id = v_ta
    and action = 'delete'
    and period_start = date '2031-01-01'
    and period_end = date '2031-01-31';
  if v_n <> 1 then
    raise exception 'FAIL: expected 1 delete event surviving for the empty period, found %', v_n;
  end if;

  if exists (select 1 from accounting_period_events
             where tenant_id = v_ta and action = 'delete' and period_id is not null) then
    raise exception 'FAIL: delete event still points at a period row that no longer exists';
  end if;
  raise notice 'PASS: a period with journals is protected; an empty one can be deleted and is logged';

  ------------------------------------------------------------------
  -- 6. Journal rows cannot be DELETEd by a client role
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('delete from journal_entries where id = %L', v_je),
    'permission denied', 'client DELETE of a journal entry');
  perform pg_temp.expect_error(
    format('delete from journal_entry_lines where journal_entry_id = %L', v_je),
    'permission denied', 'client DELETE of journal entry lines');
  reset role;
  raise notice 'PASS: journal DELETE is revoked from client roles, not just trigger-blocked';

  ------------------------------------------------------------------
  -- 7. Tenant isolation
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_finb, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select fin_close_accounting_period(%L, null)', v_period),
    'not authorized', 'close another company''s period');
  perform pg_temp.expect_error(
    format('select fin_reopen_accounting_period(%L, %L)', v_period,
           'another company trying to reopen this period'),
    'not authorized', 'reopen another company''s period');
  perform pg_temp.expect_error(
    format('select fin_delete_accounting_period(%L, %L)', v_period,
           'another company trying to delete this period'),
    'not authorized', 'delete another company''s period');
  reset role;
  raise notice 'PASS: periods are isolated per tenant';

  raise notice 'ALL PERIOD CONTROL TESTS PASSED';
end $$;

rollback;
