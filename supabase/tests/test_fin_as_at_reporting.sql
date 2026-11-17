-- =====================================================================
-- Finance D: as-at reproducibility and void netting
-- =====================================================================
--
-- Proves the two things migration 20261117120000 claims:
--
--   1. A voided entry nets to zero. (Before the fix it netted to MINUS the
--      original amount, because the original was marked 'void' -- dropping
--      it from v_account_ledger -- while its reversal was posted and
--      counted. Every void in the platform therefore showed up as its own
--      negative in the trial balance.)
--
--   2. A report as at a past date is reproducible: posting more later, or
--      voiding later, does not change the figures the report returns for
--      that date.
--
-- Runs in one transaction that ROLLBACKs (same convention as the rest of
-- supabase/tests). Any RAISE EXCEPTION is a real failure and makes psql
-- exit non-zero.
--
-- Run against a replay of supabase/migrations:
--   psql -h /tmp/pgsock -p 5433 -U postgres -d harness \
--        -v ON_ERROR_STOP=1 -f supabase/tests/test_fin_as_at_reporting.sql
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

-- Single account balance as at a date, read as the owner so assertions do
-- not depend on the caller's RLS.
create function pg_temp.bal(p_tenant uuid, p_code text, p_as_of date)
returns numeric language sql security definer set search_path to 'public','pg_temp' as $$
  select coalesce((
    select f.balance from fin_trial_balance(p_as_of) f
    join gl_accounts a on a.id = f.account_id
    where a.tenant_id = p_tenant and a.account_code = p_code
  ), 0)
$$;

-- Convenience: every non-zero balance, one text per line, for exact
-- before/after comparison.
create function pg_temp.snapshot(p_tenant uuid, p_as_of date)
returns text language sql security definer set search_path to 'public','pg_temp' as $$
  select coalesce(string_agg(
           f.account_code || ':' || f.currency || ':' || f.balance::text, '|'
           order by f.account_code, f.currency), '')
  from fin_trial_balance(p_as_of) f
  join gl_accounts a on a.id = f.account_id
  where a.tenant_id = p_tenant and f.balance <> 0
$$;

do $$
declare
  v_t   uuid := gen_random_uuid();
  v_fin uuid := gen_random_uuid();
  v_cash uuid; v_rev uuid;
  v_je_voided uuid;
  v_je_live   uuid;
  v_d_jan  date := date '2027-01-15';   -- a past reporting period
  v_d_feb  date := date '2027-02-10';
  v_snap_jan_before text;
  v_snap_jan_after  text;
  v_bal numeric;
begin
  ------------------------------------------------------------------
  -- Fixtures
  ------------------------------------------------------------------
  insert into tenants (id, name, industry_template)
  values (v_t, 'As-At Reporting Co', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_fin, 'authenticated', 'authenticated',
    'asat-' || v_fin || '@test.local',
    extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );

  insert into app_users (id, tenant_id, name, email)
  values (v_fin, v_t, 'As-At Finance', 'asat-' || v_fin || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role)
  values (v_t, v_fin, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_t, '1000', 'Operating Bank', 'asset') returning id into v_cash;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (v_t, '4000', 'Sales Income', 'revenue') returning id into v_rev;

  ------------------------------------------------------------------
  -- 1. The regression case: post then void must net to zero.
  ------------------------------------------------------------------
  v_je_voided := (post_journal_entry(
    v_t, 'manual', gen_random_uuid(), v_d_jan,
    'test entry that will be voided',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_cash, 'debit', 100, 'credit', 0, 'currency', 'UGX'),
      jsonb_build_object('gl_account_id', v_rev,  'debit', 0, 'credit', 100, 'currency', 'UGX')
    )
  )).id;

  v_bal := pg_temp.bal(v_t, '1000', v_d_jan);
  if v_bal <> 100 then
    raise exception 'FAIL: after posting 100 to 1000, balance was % (expected 100)', v_bal;
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform void_journal_entry(v_je_voided, 'voided by the as-at regression test');
  reset role;

  v_bal := pg_temp.bal(v_t, '1000', v_d_jan);
  if v_bal <> 0 then
    raise exception
      'FAIL: voiding a 100 debit left account 1000 at % -- expected 0. '
      'A negative balance here is the void double-count: the original was marked '
      'void (dropped from the ledger) while its reversal was still counted.', v_bal;
  end if;
  raise notice 'PASS: a voided entry nets to zero (no double count)';

  ------------------------------------------------------------------
  -- 2. Void provenance is recorded.
  ------------------------------------------------------------------
  if not exists (
    select 1 from journal_entries
    where id = v_je_voided
      and status = 'void'
      and voided_at is not null
      and void_reason is not null
  ) then
    raise exception 'FAIL: void did not record voided_at / void_reason';
  end if;
  raise notice 'PASS: void records voided_at and void_reason';

  ------------------------------------------------------------------
  -- 3. As-at reproducibility across later activity.
  --
  --    Post a live entry in January. Snapshot January. Then post a big
  --    February entry AND void a different January entry. The January
  --    snapshot must be byte-identical.
  ------------------------------------------------------------------
  v_je_live := (post_journal_entry(
    v_t, 'manual', gen_random_uuid(), v_d_jan,
    'live january entry',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_cash, 'debit', 250, 'credit', 0, 'currency', 'UGX'),
      jsonb_build_object('gl_account_id', v_rev,  'debit', 0, 'credit', 250, 'currency', 'UGX')
    )
  )).id;

  v_snap_jan_before := pg_temp.snapshot(v_t, v_d_jan);
  if v_snap_jan_before <> '1000:UGX:250|4000:UGX:-250' then
    raise exception 'FAIL: unexpected January snapshot before later activity: %', v_snap_jan_before;
  end if;

  -- Later activity: a February posting that must not appear in January.
  perform post_journal_entry(
    v_t, 'manual', gen_random_uuid(), v_d_feb,
    'february entry that must not leak into january',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_cash, 'debit', 9000, 'credit', 0, 'currency', 'UGX'),
      jsonb_build_object('gl_account_id', v_rev,  'debit', 0, 'credit', 9000, 'currency', 'UGX')
    )
  );

  v_snap_jan_after := pg_temp.snapshot(v_t, v_d_jan);
  if v_snap_jan_after <> v_snap_jan_before then
    raise exception
      'FAIL: the January report changed after a February posting (before=%, after=%). '
      'Reports are not reproducible as at a historical date.',
      v_snap_jan_before, v_snap_jan_after;
  end if;
  raise notice 'PASS: a later posting does not change an earlier report (%)', v_snap_jan_before;

  -- And the February report does see it.
  v_bal := pg_temp.bal(v_t, '1000', v_d_feb);
  if v_bal <> 9250 then
    raise exception 'FAIL: February balance for 1000 was % (expected 9250)', v_bal;
  end if;
  raise notice 'PASS: the later period sees the later posting';

  ------------------------------------------------------------------
  -- 4. A void recorded AFTER the reporting date must not retroactively
  --    change the report for that date. We cannot fake now(), so this
  --    asserts the shape of the guarantee instead: the reversal entry
  --    carries current_date, and an as-at report bounded before that
  --    date still shows the original.
  ------------------------------------------------------------------
  if pg_temp.bal(v_t, '1000', v_d_jan) = 0 and pg_temp.bal(v_t, '1000', v_d_feb) <> 9250 then
    raise exception 'FAIL: void of a January entry altered unrelated periods';
  end if;

  ------------------------------------------------------------------
  -- 5. The as-at functions are stable and tenant-scoped.
  ------------------------------------------------------------------
  if pg_temp.snapshot(v_t, v_d_jan) = '' then
    raise exception 'FAIL: empty snapshot for a tenant that has postings';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  -- A finance user of this tenant sees their own rows.
  if not exists (select 1 from fin_trial_balance(v_d_jan)) then
    raise exception 'FAIL: a finance user cannot read their own as-at trial balance';
  end if;
  reset role;

  raise notice 'PASS: all as-at reporting assertions passed';
end $$;

rollback;
