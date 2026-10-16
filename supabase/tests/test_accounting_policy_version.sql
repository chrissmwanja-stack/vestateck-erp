-- Phase A, A2: accounting-policy version (accounting_policies, the stamping
-- triggers and acct_* functions).
--
-- Covers: baseline version 1 with no policies; caller cannot choose the version;
-- the stamp follows the accounting date (including backdated postings); a stamped
-- version cannot change; maker-checker approval; consecutive versions and dates;
-- approval refused when it would rewrite history (BACKDATED); withdrawn drafts
-- free their number; approved rows immutable; tenant isolation; denials; every
-- stamped table carries the column, default and both triggers; the timestamp
-- column path of the stamp function.
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

-- Posts a bare journal entry as the owner and returns its stamped version.
create function pg_temp.post_je(p_tenant uuid, p_date date) returns integer language plpgsql as $$
declare v integer;
begin
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (p_tenant, p_date, 'manual', 'policy version test')
  returning accounting_policy_version into v;
  return v;
end $$;

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_admin1 uuid := gen_random_uuid();
  v_admin2 uuid := gen_random_uuid();
  v_fin    uuid := gen_random_uuid();
  v_out    uuid := gen_random_uuid();
  v_admin_b1 uuid := gen_random_uuid();
  v_admin_b2 uuid := gen_random_uuid();

  v_p2 uuid; v_p3 uuid; v_p3b uuid; v_p4 uuid; v_w uuid; v_b2 uuid; v_b2ok uuid;
  v_row accounting_policies%rowtype;
  v_n integer; v_v integer;
  r record;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Policy Ver Co A'), (v_tb, 'Policy Ver Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'acctpol-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_admin1), (v_admin2), (v_fin), (v_out), (v_admin_b1), (v_admin_b2)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (v_admin1,   v_ta, 'Pol Admin 1',  'acctpol-' || v_admin1   || '@test.local', true),
    (v_admin2,   v_ta, 'Pol Admin 2',  'acctpol-' || v_admin2   || '@test.local', true),
    (v_fin,      v_ta, 'Pol Finance',  'acctpol-' || v_fin      || '@test.local', false),
    (v_out,      v_ta, 'Pol Outsider', 'acctpol-' || v_out      || '@test.local', false),
    (v_admin_b1, v_tb, 'Pol Admin B1', 'acctpol-' || v_admin_b1 || '@test.local', true),
    (v_admin_b2, v_tb, 'Pol Admin B2', 'acctpol-' || v_admin_b2 || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values (v_ta, v_fin, 'finance');

  -------------------------------------------------------------------
  -- 1. Structure: every stamped table has the column, default and triggers
  -------------------------------------------------------------------
  for r in
    select * from (values
      ('journal_entries','entry_date'), ('fin_open_items','document_date'),
      ('fin_settlements','settlement_date'), ('fin_credit_notes','credit_date'),
      ('ins_claim_payments','payment_date'), ('ins_commission_transfers','transfer_date'),
      ('ins_policy_financial_snapshots','bound_at'), ('ins_policy_reversals','reversal_date')
    ) as t(tbl, date_col)
  loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = r.tbl and column_name = 'accounting_policy_version'
        and is_nullable = 'NO' and column_default = '1') then
      raise exception 'FAIL: % lacks a NOT NULL accounting_policy_version defaulting to 1', r.tbl;
    end if;
    if not exists (
      select 1 from pg_trigger t
      where t.tgrelid = ('public.' || r.tbl)::regclass and t.tgname = 'trg_stamp_policy_version'
        and pg_get_triggerdef(t.oid) like '%platform_stamp_policy_version(''' || r.date_col || ''')%') then
      raise exception 'FAIL: % has no stamp trigger reading %', r.tbl, r.date_col;
    end if;
    if not exists (select 1 from pg_trigger t where t.tgrelid = ('public.' || r.tbl)::regclass and t.tgname = 'trg_policy_version_immutable') then
      raise exception 'FAIL: % has no immutability trigger', r.tbl;
    end if;
  end loop;
  raise notice 'PASS: all eight stamped tables carry the column (default 1), the stamp trigger and the immutability trigger';

  -------------------------------------------------------------------
  -- 2. Baseline: no policies means version 1; the caller cannot choose
  -------------------------------------------------------------------
  if pg_temp.post_je(v_ta, date '2026-06-01') <> 1 then
    raise exception 'FAIL: a company with no policy versions must stamp 1';
  end if;
  insert into journal_entries (tenant_id, entry_date, source_type, accounting_policy_version)
  values (v_ta, date '2026-06-02', 'manual', 7) returning accounting_policy_version into v_v;
  if v_v <> 1 then raise exception 'FAIL: the caller chose version %, the stamp must override it', v_v; end if;

  perform pg_temp.as_user(v_fin);
  if acct_get_policy_version(date '2026-06-01') <> 1 then raise exception 'FAIL: acct_get_policy_version baseline'; end if;
  reset role;
  raise notice 'PASS: baseline version 1; a caller-supplied version is overridden';

  -- A stamped version cannot be changed (the journal immutability trigger or ours refuses).
  perform pg_temp.expect_error(
    $q$update journal_entries set accounting_policy_version = 2 where description = 'policy version test'$q$,
    'IMMUTABLE', 'change a stamped version');
  raise notice 'PASS: a stamped version cannot be changed';

  -------------------------------------------------------------------
  -- 3. Draft rules
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(
    $q$insert into accounting_policies (tenant_id, version, name, description, effective_from, status, approved_by, approved_at)
       values (get_my_tenant_id(), 2, 'n', 'd', date '2027-01-01', 'approved', get_my_tenant_id(), now())$q$,
    'ACCT_POLICY_STATUS', 'insert already approved');
  perform pg_temp.expect_error(
    $q$insert into accounting_policies (tenant_id, version, name, description, effective_from)
       values (get_my_tenant_id(), 1, 'n', 'd', date '2027-01-01')$q$,
    'accounting_policies_version_check', 'version 1 is the implicit baseline');
  perform pg_temp.expect_error(
    $q$insert into accounting_policies (tenant_id, version, name, description, effective_from)
       values (get_my_tenant_id(), 2, 'n', '  ', date '2027-01-01')$q$,
    'accounting_policies_text_check', 'blank description');

  insert into accounting_policies (tenant_id, version, name, description, effective_from)
  values (v_ta, 2, 'Commission at placement', 'Phase B treatment; accountant reference pending', date '2027-01-01')
  returning id into v_p2;
  perform pg_temp.expect_error(
    $q$insert into accounting_policies (tenant_id, version, name, description, effective_from)
       values (get_my_tenant_id(), 2, 'dup', 'dup', date '2027-02-01')$q$,
    'accounting_policies_tenant_version_idx', 'second live row for the same version');
  update accounting_policies set description = 'Phase B treatment; accountant reference added' where id = v_p2;  -- drafts are editable
  reset role;
  raise notice 'PASS: drafts only; version 1 reserved; one live row per version; drafts editable';

  -------------------------------------------------------------------
  -- 4. Withdrawal frees the number
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin);
  insert into accounting_policies (tenant_id, version, name, description, effective_from)
  values (v_ta, 3, 'Finance draft', 'to be withdrawn', date '2027-09-01') returning id into v_w;
  perform pg_temp.expect_error(format('select acct_policy_withdraw(%L, %L)', v_p2, 'not mine to withdraw'),
    'ACCT_POLICY_FORBIDDEN', 'non-admin withdraws another person''s draft');
  perform pg_temp.expect_error(format('select acct_policy_withdraw(%L, %L)', v_w, 'no'),
    'ACCT_POLICY_REASON', 'short reason');
  perform acct_policy_withdraw(v_w, 'proposed in error');
  reset role;
  select * into v_row from accounting_policies where id = v_w;
  if v_row.status <> 'withdrawn' or v_row.withdrawn_reason <> 'proposed in error' then
    raise exception 'FAIL: withdrawn state wrong (% / %)', v_row.status, v_row.withdrawn_reason;
  end if;
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(format('update accounting_policies set description = ''x'' where id = %L', v_w),
    'ACCT_POLICY_IMMUTABLE', 'edit a withdrawn row');
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_w),
    'ACCT_POLICY_NOT_DRAFT', 'approve a withdrawn row');
  -- version 3 can be proposed again
  insert into accounting_policies (tenant_id, version, name, description, effective_from)
  values (v_ta, 3, 'Second treatment change', 'Re-proposed after withdrawal', date '2027-07-01') returning id into v_p3;
  reset role;
  raise notice 'PASS: withdrawal needs a reason, is restricted, is final, and frees the version number';

  -------------------------------------------------------------------
  -- 5. Approval: maker-checker, order, immutability
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_p2), 'ACCT_POLICY_SELF_APPROVAL', 'proposer approves own');
  reset role;
  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_p2), 'ACCT_POLICY_FORBIDDEN', 'non-admin approves');
  reset role;
  perform pg_temp.as_user(v_admin_b1);
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_p2), 'ACCT_POLICY_NOT_FOUND', 'other tenant admin approves');
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_p3), 'ACCT_POLICY_VERSION_ORDER', 'approve version 3 before 2');
  select * into v_row from acct_policy_approve(v_p2);
  if v_row.status <> 'approved' or v_row.approved_by <> v_admin2 or v_row.approved_at is null then
    raise exception 'FAIL: approval fields wrong (% / %)', v_row.status, v_row.approved_by;
  end if;
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_p2), 'ACCT_POLICY_NOT_DRAFT', 'approve twice');
  perform pg_temp.expect_error(format('update accounting_policies set description = ''x'' where id = %L', v_p2),
    'ACCT_POLICY_IMMUTABLE', 'edit an approved version');
  perform pg_temp.expect_error(format($q$update accounting_policies set status = 'draft' where id = %L$q$, v_p2),
    'ACCT_POLICY_IMMUTABLE', 'reopen an approved version');
  perform pg_temp.expect_error(format('select acct_policy_withdraw(%L, %L)', v_p2, 'withdraw approved'),
    'ACCT_POLICY_NOT_DRAFT', 'withdraw an approved version');
  reset role;
  raise notice 'PASS: self, non-admin and other-tenant approval refused; order enforced; approved versions are final';

  -------------------------------------------------------------------
  -- 6. Stamping follows the accounting date
  -------------------------------------------------------------------
  if pg_temp.post_je(v_ta, date '2026-12-31') <> 1 then raise exception 'FAIL: day before the effective date must stay on version 1'; end if;
  if pg_temp.post_je(v_ta, date '2027-01-01') <> 2 then raise exception 'FAIL: the effective date itself must be version 2'; end if;
  if pg_temp.post_je(v_ta, date '2027-06-30') <> 2 then raise exception 'FAIL: mid-2027 must be version 2'; end if;
  if (select count(*) from journal_entries where tenant_id = v_tb) <> 0 then raise exception 'FAIL: fixture'; end if;
  if pg_temp.post_je(v_tb, date '2027-06-30') <> 1 then raise exception 'FAIL: another company must not pick up this company''s version'; end if;
  raise notice 'PASS: the stamp follows the accounting date and the company';

  -- Version 3, then a late posting into the older period keeps the older version.
  perform pg_temp.as_user(v_admin2);
  perform acct_policy_approve(v_p3);
  reset role;
  if pg_temp.post_je(v_ta, date '2027-07-01') <> 3 then raise exception 'FAIL: version 3 from its effective date'; end if;
  if pg_temp.post_je(v_ta, date '2027-03-01') <> 2 then raise exception 'FAIL: a backdated posting must keep the version of its own date'; end if;
  raise notice 'PASS: a backdated posting carries the version in force on its own date';

  -------------------------------------------------------------------
  -- 7. Date order and history protection
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  insert into accounting_policies (tenant_id, version, name, description, effective_from)
  values (v_ta, 4, 'Too early', 'effective before version 3', date '2027-05-01') returning id into v_p4;
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_p4), 'ACCT_POLICY_DATE_ORDER', 'effective date not after previous version');
  reset role;

  -- Company B: an entry is already posted on 2026-05-01.
  perform pg_temp.post_je(v_tb, date '2026-05-01');
  perform pg_temp.as_user(v_admin_b1);
  insert into accounting_policies (tenant_id, version, name, description, effective_from)
  values (v_tb, 2, 'Would rewrite history', 'effective on a posted date', date '2026-05-01') returning id into v_b2;
  reset role;
  perform pg_temp.as_user(v_admin_b2);
  perform pg_temp.expect_error(format('select acct_policy_approve(%L)', v_b2), 'ACCT_POLICY_BACKDATED', 'approval that would rewrite history');
  reset role;
  perform pg_temp.as_user(v_admin_b1);
  perform acct_policy_withdraw(v_b2, 'date is before posted entries');
  insert into accounting_policies (tenant_id, version, name, description, effective_from)
  values (v_tb, 2, 'Clear of history', 'effective after the latest posting', date '2027-07-02') returning id into v_b2ok;
  reset role;
  perform pg_temp.as_user(v_admin_b2);
  perform acct_policy_approve(v_b2ok);
  reset role;
  raise notice 'PASS: approval refused for a date not after the previous version or not after the latest posted entry';

  -------------------------------------------------------------------
  -- 8. Visibility, lookup and isolation
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin_b1);
  select count(*) into v_n from accounting_policies where tenant_id = v_ta;
  if v_n <> 0 then raise exception 'FAIL: company B can see company A policy versions (%)', v_n; end if;
  if acct_get_policy_version(date '2027-08-01') <> 2 then raise exception 'FAIL: company B resolves its own version, expected 2'; end if;
  perform pg_temp.expect_error(
    format($q$insert into accounting_policies (tenant_id, version, name, description, effective_from)
              values (%L, 9, 'n', 'd', date '2030-01-01')$q$, v_ta),
    'row-level security', 'company B writes into company A');
  reset role;

  perform pg_temp.as_user(v_admin1);
  if acct_get_policy_version(date '2027-08-01') <> 3 then raise exception 'FAIL: company A resolves version 3 in August 2027'; end if;
  if acct_get_policy_version(date '2027-02-01') <> 2 then raise exception 'FAIL: company A resolves version 2 in February 2027'; end if;
  reset role;

  perform pg_temp.as_user(v_out);
  select count(*) into v_n from accounting_policies;
  if v_n <> 0 then raise exception 'FAIL: a user with no role must not see policy versions (%)', v_n; end if;
  perform pg_temp.expect_error(
    $q$insert into accounting_policies (tenant_id, version, name, description, effective_from)
       values (get_my_tenant_id(), 9, 'n', 'd', date '2030-01-01')$q$,
    'row-level security', 'outsider insert');
  reset role;

  perform pg_temp.as_user(v_fin);
  select count(*) into v_n from accounting_policies;
  if v_n < 2 then raise exception 'FAIL: finance should see its company''s policy versions'; end if;
  reset role;
  raise notice 'PASS: isolation between companies; outsiders see and write nothing; finance can read';

  -------------------------------------------------------------------
  -- 9. Denials
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('delete from accounting_policies where id = %L', v_p2), 'permission denied', 'delete a policy version');
  perform pg_temp.expect_error(
    format($q$select platform_accounting_policy_version(%L, date '2027-08-01')$q$, v_ta), 'permission denied', 'client calls the internal resolver');
  reset role;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  perform pg_temp.expect_error('select count(*) from accounting_policies', 'permission denied', 'anon reads policy versions');
  perform pg_temp.expect_error('select acct_get_policy_version()', 'permission denied', 'anon lookup');
  reset role;
  raise notice 'PASS: no deletes; internal resolver not callable; anon denied';

  -------------------------------------------------------------------
  -- 10. The stamp function on a timestamp column and on a missing date
  -------------------------------------------------------------------
  create temp table pg_temp.stamp_probe (tenant_id uuid, at_ts timestamptz, accounting_policy_version integer not null default 1);
  create trigger trg_probe before insert on pg_temp.stamp_probe
    for each row execute function public.platform_stamp_policy_version('at_ts');
  insert into pg_temp.stamp_probe (tenant_id, at_ts) values (v_ta, timestamptz '2027-03-01 10:00+00');
  insert into pg_temp.stamp_probe (tenant_id, at_ts) values (v_ta, timestamptz '2027-07-01 00:30+00');
  insert into pg_temp.stamp_probe (tenant_id, at_ts) values (v_ta, null);
  if (select accounting_policy_version from pg_temp.stamp_probe where at_ts = timestamptz '2027-03-01 10:00+00') <> 2 then
    raise exception 'FAIL: timestamp column should resolve version 2 for March 2027'; end if;
  if (select accounting_policy_version from pg_temp.stamp_probe where at_ts = timestamptz '2027-07-01 00:30+00') <> 3 then
    raise exception 'FAIL: timestamp column should resolve version 3 for 1 July 2027'; end if;
  if (select accounting_policy_version from pg_temp.stamp_probe where at_ts is null) <> platform_accounting_policy_version(v_ta, current_date) then
    raise exception 'FAIL: a missing date should resolve as of today'; end if;
  raise notice 'PASS: stamp function handles timestamp columns and missing dates';

  -------------------------------------------------------------------
  -- 11. Read-only guard attached
  -------------------------------------------------------------------
  if not exists (select 1 from pg_trigger where tgrelid = 'public.accounting_policies'::regclass and tgname = 'tenant_read_only_guard') then
    raise exception 'FAIL: tenant_read_only_guard is not attached to accounting_policies';
  end if;
  raise notice 'PASS: tenant read-only guard attached';
end $$;

do $$ begin raise notice 'PASS: accounting policy version (A2) tests'; end $$;

rollback;