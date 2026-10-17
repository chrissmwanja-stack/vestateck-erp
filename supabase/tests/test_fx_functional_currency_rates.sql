-- Phase A, A3 slice 1: functional currency setting and exchange rates
-- (tenant_ledger_settings, fin_ledger_currency, fx_rates, fx_rate_approve,
-- fx_rate_withdraw, platform_fx_rate, fx_get_rate).
--
-- Covers: every existing company still has UGX; the setting changes
-- fin_ledger_currency for that company only and locks once a journal is posted;
-- clients cannot write the setting; rate drafts are validated; maker-checker
-- approval; approved rates immutable; withdrawal frees the slot; the functional
-- currency is rate 1; missing, stale and unconfigured-age lookups fail loudly;
-- latest approved rate on or before the date wins and drafts are never used;
-- tenant isolation; denials.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

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

create function pg_temp.as_user(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_tc uuid := gen_random_uuid();
  v_admin1 uuid := gen_random_uuid();
  v_admin2 uuid := gen_random_uuid();
  v_fin1   uuid := gen_random_uuid();
  v_fin2   uuid := gen_random_uuid();
  v_out    uuid := gen_random_uuid();
  v_admin_b uuid := gen_random_uuid();

  v_r1 uuid; v_r2 uuid; v_r3 uuid; v_rd uuid; v_wd uuid; v_param uuid;
  v_row fx_rates%rowtype;
  v_num numeric; v_n integer; v_txt text;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'FX Co A'), (v_tb, 'FX Co B'), (v_tc, 'FX Co C');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'fxr-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_admin1), (v_admin2), (v_fin1), (v_fin2), (v_out), (v_admin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (v_admin1,  v_ta, 'FX Admin 1', 'fxr-' || v_admin1  || '@test.local', true),
    (v_admin2,  v_ta, 'FX Admin 2', 'fxr-' || v_admin2  || '@test.local', true),
    (v_fin1,    v_ta, 'FX Fin 1',   'fxr-' || v_fin1    || '@test.local', false),
    (v_fin2,    v_ta, 'FX Fin 2',   'fxr-' || v_fin2    || '@test.local', false),
    (v_out,     v_ta, 'FX Outsider','fxr-' || v_out     || '@test.local', false),
    (v_admin_b, v_tb, 'FX Admin B', 'fxr-' || v_admin_b || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, v_fin1, 'finance'), (v_ta, v_fin2, 'finance');

  -------------------------------------------------------------------
  -- 1. Nothing changes for existing companies
  -------------------------------------------------------------------
  if fin_ledger_currency(v_ta) <> 'UGX' then raise exception 'FAIL: a company with no setting must be UGX'; end if;
  select count(*) into v_n from tenants t where fin_ledger_currency(t.id) <> 'UGX';
  if v_n <> 0 then raise exception 'FAIL: % companies are not UGX without any setting', v_n; end if;
  select provolatile into v_txt from pg_proc where oid = 'public.fin_ledger_currency(uuid)'::regprocedure;
  if v_txt <> 's' then raise exception 'FAIL: fin_ledger_currency should now be STABLE (found %)', v_txt; end if;
  if not has_function_privilege('authenticated', 'public.fin_ledger_currency(uuid)'::regprocedure, 'EXECUTE')
     or has_function_privilege('anon', 'public.fin_ledger_currency(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'FAIL: fin_ledger_currency grants changed (authenticated yes, anon no expected)';
  end if;
  raise notice 'PASS: every company is still UGX; grants and callers unchanged';

  -------------------------------------------------------------------
  -- 2. The setting: per company, locked by posting, not client-writable
  -------------------------------------------------------------------
  insert into tenant_ledger_settings (tenant_id, functional_currency) values (v_tc, 'USD');
  if fin_ledger_currency(v_tc) <> 'USD' then raise exception 'FAIL: company C should now be USD'; end if;
  if fin_ledger_currency(v_ta) <> 'UGX' then raise exception 'FAIL: company A must stay UGX'; end if;
  update tenant_ledger_settings set functional_currency = 'EUR' where tenant_id = v_tc;   -- allowed: nothing posted yet
  if fin_ledger_currency(v_tc) <> 'EUR' then raise exception 'FAIL: change before posting should work'; end if;

  insert into journal_entries (tenant_id, entry_date, source_type) values (v_tc, date '2026-10-01', 'manual');
  perform pg_temp.expect_error(
    format($q$update tenant_ledger_settings set functional_currency = 'USD' where tenant_id = %L$q$, v_tc),
    'FX_FUNCTIONAL_LOCKED', 'change currency after posting');
  update tenant_ledger_settings set functional_currency = 'EUR' where tenant_id = v_tc;     -- same value is not a change

  insert into journal_entries (tenant_id, entry_date, source_type) values (v_ta, date '2026-10-01', 'manual');
  perform pg_temp.expect_error(
    format($q$insert into tenant_ledger_settings (tenant_id, functional_currency) values (%L, 'USD')$q$, v_ta),
    'FX_FUNCTIONAL_LOCKED', 'set currency for a company that already posted');
  perform pg_temp.expect_error(
    format($q$insert into tenant_ledger_settings (tenant_id, functional_currency) values (%L, 'usd')$q$, v_tb),
    'tenant_ledger_settings_currency_check', 'malformed currency code');
  perform pg_temp.expect_error(
    format($q$update tenant_ledger_settings set tenant_id = %L where tenant_id = %L$q$, v_tb, v_tc),
    'FX_TENANT_IMMUTABLE', 'move a setting to another company');

  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(
    $q$insert into tenant_ledger_settings (tenant_id, functional_currency) values (get_my_tenant_id(), 'USD')$q$,
    'permission denied', 'client writes the setting');
  select count(*) into v_n from tenant_ledger_settings;
  if v_n <> 0 then raise exception 'FAIL: company A has no setting row and must not see company C''s (%)', v_n; end if;
  reset role;
  raise notice 'PASS: setting is per company, locked by posting, validated, and not client-writable';

  -------------------------------------------------------------------
  -- 3. Rate drafts
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin1);
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'USD', date '2026-10-01', 0, 'x')$q$,
    'fx_rates_rate_check', 'zero rate');
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'USD', date '2026-10-01', -5, 'x')$q$,
    'fx_rates_rate_check', 'negative rate');
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'USD', date '2026-10-01', 3700, '  ')$q$,
    'fx_rates_source_check', 'blank source');
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'usd', date '2026-10-01', 3700, 'x')$q$,
    'fx_rates_currency_check', 'malformed currency');
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'UGX', date '2026-10-01', 1, 'x')$q$,
    'FX_RATE_CURRENCY', 'rate for the functional currency');
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'USD', current_date + 1, 3700, 'x')$q$,
    'FX_RATE_FUTURE', 'future-dated rate');
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source, status, approved_by, approved_at)
       values (get_my_tenant_id(), 'USD', date '2026-10-01', 3700, 'x', 'approved', get_my_tenant_id(), now())$q$,
    'FX_RATE_STATUS', 'insert already approved');

  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
  values (v_ta, 'USD', date '2026-10-01', 3650, 'Bank mid-rate, typed wrong') returning id into v_r1;
  update fx_rates set rate = 3700, source = 'Bank mid-rate, ref BM-1001' where id = v_r1;   -- drafts are editable
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'USD', date '2026-10-01', 3701, 'dup')$q$,
    'fx_rates_live_idx', 'second live rate for the same currency and date');
  reset role;
  raise notice 'PASS: drafts validated; functional currency, future dates, blank sources and duplicates refused';

  -------------------------------------------------------------------
  -- 4. Maker-checker, immutability, withdrawal
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin1);
  perform pg_temp.expect_error(format('select fx_rate_approve(%L)', v_r1), 'FX_RATE_SELF_APPROVAL', 'enterer approves own rate');
  reset role;
  perform pg_temp.as_user(v_out);
  perform pg_temp.expect_error(format('select fx_rate_approve(%L)', v_r1), 'FX_RATE_FORBIDDEN', 'user with no role approves');
  reset role;
  perform pg_temp.as_user(v_admin_b);
  perform pg_temp.expect_error(format('select fx_rate_approve(%L)', v_r1), 'FX_RATE_NOT_FOUND', 'other company approves');
  reset role;

  perform pg_temp.as_user(v_fin2);
  select * into v_row from fx_rate_approve(v_r1);
  if v_row.status <> 'approved' or v_row.approved_by <> v_fin2 or v_row.approved_at is null then
    raise exception 'FAIL: approval fields wrong (% / %)', v_row.status, v_row.approved_by;
  end if;
  perform pg_temp.expect_error(format('select fx_rate_approve(%L)', v_r1), 'FX_RATE_NOT_DRAFT', 'approve twice');
  perform pg_temp.expect_error(format('update fx_rates set rate = 3800 where id = %L', v_r1), 'FX_RATE_IMMUTABLE', 'edit an approved rate');
  perform pg_temp.expect_error(format($q$update fx_rates set status = 'draft' where id = %L$q$, v_r1), 'FX_RATE_IMMUTABLE', 'reopen an approved rate');
  perform pg_temp.expect_error(format('select fx_rate_withdraw(%L, %L)', v_r1, 'withdraw approved'), 'FX_RATE_NOT_DRAFT', 'withdraw an approved rate');
  perform pg_temp.expect_error(format('delete from fx_rates where id = %L', v_r1), 'permission denied', 'delete a rate');
  reset role;

  -- Withdrawal: only the enterer or an admin, with a reason; it is final and frees the slot.
  perform pg_temp.as_user(v_fin1);
  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
  values (v_ta, 'USD', date '2026-10-02', 3710, 'draft to withdraw') returning id into v_wd;
  reset role;
  perform pg_temp.as_user(v_fin2);
  perform pg_temp.expect_error(format('select fx_rate_withdraw(%L, %L)', v_wd, 'not my draft'), 'FX_RATE_FORBIDDEN', 'non-admin withdraws another person''s draft');
  reset role;
  perform pg_temp.as_user(v_fin1);
  perform pg_temp.expect_error(format('select fx_rate_withdraw(%L, %L)', v_wd, 'no'), 'FX_RATE_REASON', 'short reason');
  perform fx_rate_withdraw(v_wd, 'entered on the wrong date');
  perform pg_temp.expect_error(format('update fx_rates set rate = 1 where id = %L', v_wd), 'FX_RATE_IMMUTABLE', 'edit a withdrawn rate');
  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
  values (v_ta, 'USD', date '2026-10-02', 3712, 'entered again') returning id into v_r2;   -- slot is free again
  reset role;
  raise notice 'PASS: maker-checker; approved rates are final and undeletable; withdrawal restricted, final, frees the slot';

  -------------------------------------------------------------------
  -- 5. Resolution
  -------------------------------------------------------------------
  v_num := (platform_fx_rate(v_ta, 'UGX', date '2026-10-01')).rate;
  if v_num <> 1 then raise exception 'FAIL: the functional currency must be rate 1'; end if;
  v_num := (platform_fx_rate(v_tc, 'EUR', date '2026-10-01')).rate;
  if v_num <> 1 then raise exception 'FAIL: company C''s functional currency (EUR) must be rate 1'; end if;
  perform pg_temp.expect_error(
    format($q$select platform_fx_rate(%L, 'USD', date '2026-09-30')$q$, v_ta),
    'FX_RATE_MISSING', 'date before the first approved rate');
  perform pg_temp.expect_error(
    format($q$select platform_fx_rate(%L, 'KES', date '2026-10-01')$q$, v_ta),
    'FX_RATE_MISSING', 'currency with no rates');
  -- A rate exists, but the maximum age is not configured: fails loudly, no default.
  perform pg_temp.expect_error(
    format($q$select platform_fx_rate(%L, 'USD', date '2026-10-01')$q$, v_ta),
    'REG_PARAM_MISSING', 'lookup before fx.rate_max_age_days is approved');

  perform pg_temp.as_user(v_admin1);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'fx.rate_max_age_days', 5, date '2026-01-01', 'UNVERIFIED: finance policy') returning id into v_param;
  reset role;
  -- Approval follows an assignment, not a role (20261016160000).
  perform pg_temp.as_user(v_admin1);
  perform reg_assign_approver(v_admin2, 'key', 'fx.rate_max_age_days', 'fx test: rate staleness policy');
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform reg_approve_parameter(v_param);
  reset role;

  if (platform_fx_rate(v_ta, 'USD', date '2026-10-01')).rate <> 3700 then raise exception 'FAIL: rate on its own date'; end if;
  if (platform_fx_rate(v_ta, 'USD', date '2026-10-06')).rate <> 3700 then raise exception 'FAIL: a rate exactly at the maximum age is still usable'; end if;
  perform pg_temp.expect_error(
    format($q$select platform_fx_rate(%L, 'USD', date '2026-10-07')$q$, v_ta),
    'FX_RATE_STALE', 'rate older than the approved maximum age');

  -- The 2 Oct draft is not used until approved; a newer approved rate then takes over from its date.
  perform pg_temp.expect_error(
    format($q$select platform_fx_rate(%L, 'USD', date '2026-10-07')$q$, v_ta),
    'FX_RATE_STALE', 'draft rate must not rescue a stale lookup');
  perform pg_temp.as_user(v_fin2);
  perform fx_rate_approve(v_r2);                                                           -- 2 Oct, 3712, entered by fin1
  reset role;
  if (platform_fx_rate(v_ta, 'USD', date '2026-10-01')).rate <> 3700 then raise exception 'FAIL: earlier date must keep the earlier rate'; end if;
  if (platform_fx_rate(v_ta, 'USD', date '2026-10-04')).rate <> 3712 then raise exception 'FAIL: the latest approved rate on or before the date must win'; end if;
  if (platform_fx_rate(v_ta, 'USD', date '2026-10-07')).rate <> 3712 then raise exception 'FAIL: the newer approved rate should keep 7 Oct fresh'; end if;
  v_n := (select (platform_fx_rate(v_ta, 'USD', date '2026-10-04')).id::text is not null)::int;
  if v_n <> 1 then raise exception 'FAIL: a looked-up rate must identify its row for traceability'; end if;
  raise notice 'PASS: functional currency is 1; missing, stale and unconfigured-age fail loudly; latest approved rate wins; drafts unused';

  -------------------------------------------------------------------
  -- 6. Client lookup and isolation
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin1);
  select rate into v_num from fx_get_rate('USD', date '2026-10-04');
  if v_num <> 3712 then raise exception 'FAIL: fx_get_rate returned %', v_num; end if;
  select count(*) into v_n from fx_rates;
  if v_n < 2 then raise exception 'FAIL: finance should see its company''s rates'; end if;
  reset role;

  perform pg_temp.as_user(v_out);
  select count(*) into v_n from fx_rates;
  if v_n <> 0 then raise exception 'FAIL: a user with no role must not see rates (%)', v_n; end if;
  perform pg_temp.expect_error($q$select fx_get_rate('USD', date '2026-10-04')$q$, 'FX_RATE_FORBIDDEN', 'outsider lookup');
  perform pg_temp.expect_error(
    $q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (get_my_tenant_id(), 'USD', date '2026-10-03', 3700, 'x')$q$,
    'row-level security', 'outsider insert');
  reset role;

  perform pg_temp.as_user(v_admin_b);
  select count(*) into v_n from fx_rates;
  if v_n <> 0 then raise exception 'FAIL: company B must not see company A rates (%)', v_n; end if;
  perform pg_temp.expect_error($q$select fx_get_rate('USD', date '2026-10-04')$q$, 'FX_RATE_MISSING', 'company B must not resolve company A''s rate');
  perform pg_temp.expect_error(
    format($q$insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (%L, 'USD', date '2026-10-03', 1, 'x')$q$, v_ta),
    'row-level security', 'company B writes into company A');
  reset role;
  raise notice 'PASS: finance reads and resolves; outsiders and other companies see and write nothing';

  -------------------------------------------------------------------
  -- 7. Denials
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(
    format($q$select platform_fx_rate(%L, 'USD', date '2026-10-04')$q$, v_ta), 'permission denied', 'client calls the internal resolver');
  reset role;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  perform pg_temp.expect_error('select count(*) from fx_rates', 'permission denied', 'anon reads rates');
  perform pg_temp.expect_error($q$select fx_get_rate('USD')$q$, 'permission denied', 'anon lookup');
  perform pg_temp.expect_error('select count(*) from tenant_ledger_settings', 'permission denied', 'anon reads settings');
  reset role;
  raise notice 'PASS: internal resolver not callable; anon denied';

  -------------------------------------------------------------------
  -- 8. Read-only guard attached
  -------------------------------------------------------------------
  select count(*) into v_n from pg_trigger
   where tgname = 'tenant_read_only_guard'
     and tgrelid in ('public.fx_rates'::regclass, 'public.tenant_ledger_settings'::regclass);
  if v_n <> 2 then raise exception 'FAIL: tenant_read_only_guard must be attached to both new tables (found %)', v_n; end if;
  raise notice 'PASS: tenant read-only guard attached to both tables';
end $$;

do $$ begin raise notice 'PASS: functional currency and exchange rates (A3 slice 1) tests'; end $$;

rollback;