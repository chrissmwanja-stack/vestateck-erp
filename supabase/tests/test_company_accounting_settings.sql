-- Company accounting settings, stage 1 (20261107150000_company_accounting_settings.sql).
--
-- Covers: definitions registry (only implemented values are selectable); default
-- when nothing is configured; propose / approve / withdraw / review permissions;
-- maker-checker (no self-approval); effective-date rules (ordered, never backdated
-- before a posted entry); value in force by date; approved rows immutable; review
-- recorded once and attributed; append-only audit log; RPC-only writes; tenant
-- isolation; no anon or PUBLIC access.
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

create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_admin1 uuid := gen_random_uuid();
  v_admin2 uuid := gen_random_uuid();
  v_fin    uuid := gen_random_uuid();
  v_out    uuid := gen_random_uuid();
  v_admin_b uuid := gen_random_uuid();

  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_w uuid;
  v_row company_accounting_settings%rowtype;
  v_j jsonb;
  v_n integer;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Acct Setting Co A'), (v_tb, 'Acct Setting Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'acctset-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_admin1), (v_admin2), (v_fin), (v_out), (v_admin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (v_admin1, v_ta, 'Set Admin 1', 'acctset-' || v_admin1 || '@test.local', true),
    (v_admin2, v_ta, 'Set Admin 2', 'acctset-' || v_admin2 || '@test.local', true),
    (v_fin,    v_ta, 'Set Finance', 'acctset-' || v_fin    || '@test.local', false),
    (v_out,    v_ta, 'Set Outsider','acctset-' || v_out    || '@test.local', false),
    (v_admin_b, v_tb, 'Set Admin B','acctset-' || v_admin_b || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values (v_ta, v_fin, 'finance');

  -------------------------------------------------------------------
  -- 1. Registry and default
  -------------------------------------------------------------------
  perform pg_temp.assert(
    exists (select 1 from accounting_setting_definitions
             where key = 'ins.commission_recognition'
               and default_value = 'on_insurer_settlement'
               and 'on_insurer_settlement' = any (allowed_values)),
    'ins.commission_recognition is registered with its default');

  perform pg_temp.as_user(v_fin);
  v_j := acct_get_setting('ins.commission_recognition');
  perform pg_temp.assert(v_j ->> 'value' = 'on_insurer_settlement' and v_j ->> 'source' = 'default'
                         and v_j ->> 'review_status' = 'unreviewed',
    'nothing configured: default value, source default, unreviewed');
  perform pg_temp.expect_error($q$select acct_get_setting('no.such.setting')$q$,
    'ACCT_SETTING_UNKNOWN', 'unknown setting');
  perform pg_temp.assert(jsonb_array_length(acct_settings_overview()) >= 1, 'overview lists the defined settings');
  reset role;
  raise notice 'PASS: registry and default';

  -------------------------------------------------------------------
  -- 2. Proposing: who, what, which values
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_out);
  perform pg_temp.expect_error(
    $q$select acct_setting_propose('ins.commission_recognition', 'on_insurer_settlement', date '2027-01-01', 'outsider tries this')$q$,
    'ACCT_SETTING_FORBIDDEN', 'outsider proposes');
  reset role;

  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(
    $q$select acct_setting_propose('ins.commission_recognition', 'over_policy_term', date '2027-01-01', 'a treatment not built yet')$q$,
    'ACCT_SETTING_VALUE_NOT_ALLOWED', 'value the code does not implement');
  perform pg_temp.expect_error(
    $q$select acct_setting_propose('no.such.setting', 'x', date '2027-01-01', 'unknown key for test')$q$,
    'ACCT_SETTING_UNKNOWN', 'unknown key');
  perform pg_temp.expect_error(
    $q$select acct_setting_propose('ins.commission_recognition', 'on_insurer_settlement', date '2027-01-01', 'short')$q$,
    'ACCT_SETTING_RATIONALE', 'short rationale');
  perform pg_temp.expect_error(
    $q$select acct_setting_propose('ins.commission_recognition', 'on_insurer_settlement', null, 'no date given here')$q$,
    'ACCT_SETTING_DATE_REQUIRED', 'missing effective date');
  select id into v_s1 from acct_setting_propose(
    'ins.commission_recognition', 'on_insurer_settlement', date '2027-01-01', 'Confirmed with our accountant at onboarding');
  reset role;

  select * into v_row from company_accounting_settings where id = v_s1;
  perform pg_temp.assert(v_row.status = 'draft' and v_row.review_status = 'unreviewed' and v_row.tenant_id = v_ta
                         and v_row.created_by = v_fin, 'proposal is an unreviewed draft attributed to the proposer');
  perform pg_temp.assert((select count(*) from company_accounting_setting_events
                           where setting_id = v_s1 and event = 'proposed' and actor = v_fin) = 1,
    'proposal is logged with the actor');

  -- a draft is not yet in force
  perform pg_temp.as_user(v_fin);
  perform pg_temp.assert(acct_get_setting('ins.commission_recognition', date '2027-06-01') ->> 'source' = 'default',
    'a draft does not take effect');
  reset role;
  raise notice 'PASS: only implemented values can be proposed; proposals are attributed drafts';

  -------------------------------------------------------------------
  -- 3. Approval: maker-checker, admin only
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(format('select acct_setting_approve(%L)', v_s1),
    'ACCT_SETTING_FORBIDDEN', 'non-admin approves');
  reset role;
  -- the proposer, if also an admin, still cannot approve their own
  perform pg_temp.as_user(v_admin1);
  select id into v_s2 from acct_setting_propose(
    'ins.commission_recognition', 'on_insurer_settlement', date '2027-03-01', 'Admin-proposed re-confirmation');
  perform pg_temp.expect_error(format('select acct_setting_approve(%L)', v_s2),
    'ACCT_SETTING_SELF_APPROVAL', 'proposer approves own choice');
  reset role;

  perform pg_temp.as_user(v_admin2);
  perform acct_setting_approve(v_s1);
  perform pg_temp.expect_error(format('select acct_setting_approve(%L)', v_s1),
    'ACCT_SETTING_NOT_DRAFT', 'approve twice');
  -- a later date is required for the next approval, and 2027-03-01 is later than 2027-01-01
  perform acct_setting_approve(v_s2);
  reset role;

  select * into v_row from company_accounting_settings where id = v_s1;
  perform pg_temp.assert(v_row.status = 'approved' and v_row.approved_by = v_admin2, 'approval attributed to the second person');
  perform pg_temp.assert((select count(*) from company_accounting_setting_events
                           where setting_id = v_s1 and event = 'approved' and actor = v_admin2) = 1,
    'approval is logged with the actor');

  perform pg_temp.as_user(v_fin);
  v_j := acct_get_setting('ins.commission_recognition', date '2027-02-01');
  perform pg_temp.assert(v_j ->> 'source' = 'configured' and v_j ->> 'effective_from' = '2027-01-01'
                         and (v_j ->> 'setting_id')::uuid = v_s1, 'value in force on 2027-02-01 is the first choice');
  v_j := acct_get_setting('ins.commission_recognition', date '2027-03-01');
  perform pg_temp.assert((v_j ->> 'setting_id')::uuid = v_s2, 'value in force on 2027-03-01 is the later choice');
  v_j := acct_get_setting('ins.commission_recognition', date '2026-12-31');
  perform pg_temp.assert(v_j ->> 'source' = 'default', 'before the first effective date the default applies');
  reset role;
  raise notice 'PASS: maker-checker approval; value in force follows effective dates';

  -------------------------------------------------------------------
  -- 4. Effective-date rules
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin);
  select id into v_s3 from acct_setting_propose(
    'ins.commission_recognition', 'on_insurer_settlement', date '2027-02-01', 'Earlier than the approved March choice');
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('select acct_setting_approve(%L)', v_s3),
    'ACCT_SETTING_DATE_ORDER', 'approve a choice dated before the previous approved one');
  reset role;

  -- an entry already posted blocks a date on or before it
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (v_ta, date '2027-09-15', 'manual', 'setting backdate test');
  perform pg_temp.as_user(v_fin);
  select id into v_w from acct_setting_propose(
    'ins.commission_recognition', 'on_insurer_settlement', date '2027-09-01', 'Dated before a posted entry');
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('select acct_setting_approve(%L)', v_w),
    'ACCT_SETTING_BACKDATED', 'approve a choice dated before a posted entry');
  reset role;
  raise notice 'PASS: effective dates are ordered and cannot rewrite history';

  -------------------------------------------------------------------
  -- 5. Withdrawal
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_out);
  perform pg_temp.expect_error(format('select acct_setting_withdraw(%L, %L)', v_w, 'not mine to withdraw'),
    'ACCT_SETTING_FORBIDDEN', 'outsider withdraws');
  reset role;
  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(format('select acct_setting_withdraw(%L, %L)', v_w, 'no'),
    'ACCT_SETTING_REASON', 'short reason');
  perform acct_setting_withdraw(v_w, 'dated before a posted entry');
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('select acct_setting_approve(%L)', v_w),
    'ACCT_SETTING_NOT_DRAFT', 'approve a withdrawn choice');
  reset role;
  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(format('select acct_setting_withdraw(%L, %L)', v_s1, 'trying to undo an approved choice'),
    'ACCT_SETTING_NOT_DRAFT', 'withdraw an approved choice');
  reset role;
  perform pg_temp.assert((select count(*) from company_accounting_setting_events
                           where setting_id = v_w and event = 'withdrawn' and detail ->> 'reason' = 'dated before a posted entry') = 1,
    'withdrawal is logged with its reason');
  raise notice 'PASS: withdrawal needs a reason, is restricted and is final';

  -------------------------------------------------------------------
  -- 6. Review attestation
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(format('select acct_setting_record_review(%L, %L, %L)', v_s1, 'A. Accountant', 'REF-1'),
    'ACCT_SETTING_FORBIDDEN', 'non-admin records a review');
  reset role;
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(format('select acct_setting_record_review(%L, %L, %L)', v_s1, '', 'REF-1'),
    'ACCT_SETTING_REVIEW_DETAILS', 'review without a reviewer name');
  perform pg_temp.expect_error(format('select acct_setting_record_review(%L, %L, %L)', v_s1, 'A. Accountant', ''),
    'ACCT_SETTING_REVIEW_DETAILS', 'review without a reference');
  perform acct_setting_record_review(v_s1, 'A. Accountant', 'Letter 2026-11-20');
  perform pg_temp.expect_error(format('select acct_setting_record_review(%L, %L, %L)', v_s1, 'B. Other', 'REF-2'),
    'ACCT_SETTING_ALREADY_REVIEWED', 'second review of the same choice');
  perform pg_temp.expect_error(format('select acct_setting_record_review(%L, %L, %L)', v_w, 'A. Accountant', 'REF-3'),
    'ACCT_SETTING_NOT_DRAFT', 'review a withdrawn choice');
  reset role;

  select * into v_row from company_accounting_settings where id = v_s1;
  perform pg_temp.assert(v_row.review_status = 'reviewed' and v_row.reviewer_name = 'A. Accountant'
                         and v_row.reviewed_by = v_admin1 and v_row.status = 'approved',
    'review recorded on an approved choice without changing it');
  perform pg_temp.assert((select count(*) from company_accounting_setting_events
                           where setting_id = v_s1 and event = 'reviewed' and actor = v_admin1) = 1,
    'review is logged with the actor');
  perform pg_temp.as_user(v_fin);
  perform pg_temp.assert(acct_get_setting('ins.commission_recognition', date '2027-02-01') ->> 'review_status' = 'reviewed',
    'resolution reports the review status');
  reset role;
  raise notice 'PASS: review is an attributed, one-time attestation';

  -------------------------------------------------------------------
  -- 7. Immutability and RPC-only writes
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format($q$update company_accounting_settings set value = 'on_insurer_settlement', rationale = 'edited after the fact' where id = %L$q$, v_s1),
    'ACCT_SETTING_VIA_RPC', 'direct update as owner');

  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(
    format($q$update company_accounting_settings set rationale = 'edited after the fact' where id = %L$q$, v_s1),
    'permission denied', 'direct update as an API user');
  perform pg_temp.expect_error(
    $q$insert into company_accounting_settings (tenant_id, setting_key, value, effective_from, rationale)
       values (get_my_tenant_id(), 'ins.commission_recognition', 'on_insurer_settlement', date '2030-01-01', 'direct insert bypass')$q$,
    'permission denied', 'direct insert as an API user');
  perform pg_temp.expect_error(
    format($q$delete from company_accounting_settings where id = %L$q$, v_s1),
    'permission denied', 'direct delete as an API user');
  reset role;

  -- audit log cannot be edited or deleted by API users
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error($q$update company_accounting_setting_events set event = 'approved'$q$,
    'permission denied', 'edit the audit log');
  perform pg_temp.expect_error($q$delete from company_accounting_setting_events$q$,
    'permission denied', 'delete from the audit log');
  reset role;
  perform pg_temp.expect_error($q$update company_accounting_setting_events set event = 'approved'$q$,
    'ACCT_SETTING_LOG_APPEND_ONLY', 'edit the audit log as owner');
  raise notice 'PASS: writes are RPC-only; approved rows and the audit log cannot be changed';

  -------------------------------------------------------------------
  -- 8. Tenant isolation
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin_b);
  select count(*) into v_n from company_accounting_settings;
  perform pg_temp.assert(v_n = 0, 'company B cannot read company A settings');
  select count(*) into v_n from company_accounting_setting_events;
  perform pg_temp.assert(v_n = 0, 'company B cannot read company A audit events');
  perform pg_temp.expect_error(format('select acct_setting_approve(%L)', v_s2),
    'ACCT_SETTING_NOT_FOUND', 'cross-tenant approve');
  perform pg_temp.assert(acct_get_setting('ins.commission_recognition', date '2027-06-01') ->> 'source' = 'default',
    'company B resolves to the default, not company A''s choice');
  reset role;

  perform pg_temp.as_user(v_out);
  select count(*) into v_n from company_accounting_settings;
  perform pg_temp.assert(v_n = 0, 'a user with no finance, insurance or admin role sees no settings');
  reset role;
  raise notice 'PASS: tenant isolation and read scope';

  -------------------------------------------------------------------
  -- 9. No anon / PUBLIC access
  -------------------------------------------------------------------
  perform pg_temp.assert(
    (select count(*) = 0 from information_schema.routine_privileges
      where routine_schema = 'public'
        and routine_name in ('acct_get_setting', 'acct_settings_overview', 'acct_setting_propose',
                             'acct_setting_approve', 'acct_setting_withdraw', 'acct_setting_record_review',
                             'platform_acct_setting_value')
        and grantee in ('anon', 'PUBLIC')),
    'anon / PUBLIC have no EXECUTE on the settings functions');
  perform pg_temp.assert(
    (select count(*) = 0 from information_schema.routine_privileges
      where routine_schema = 'public' and routine_name = 'platform_acct_setting_value'
        and grantee = 'authenticated'),
    'authenticated cannot execute the internal resolver');
  perform pg_temp.assert(
    (select count(*) = 0 from information_schema.role_table_grants
      where table_schema = 'public'
        and table_name in ('accounting_setting_definitions', 'company_accounting_settings', 'company_accounting_setting_events')
        and grantee in ('anon', 'PUBLIC')),
    'anon / PUBLIC have no table privileges');
  raise notice 'PASS: no anon or PUBLIC access';
end $$;

rollback;
