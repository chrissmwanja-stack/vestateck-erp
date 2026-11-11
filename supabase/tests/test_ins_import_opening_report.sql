-- Insurance brokerage: the post-commit opening report
-- (20261111100000_ins_import_opening_report.sql).
--
-- receivables, payables and unearned_commission are recorded by the control
-- totals sync but cannot gate the commit (they only exist once the opening
-- position is posted, and legacy unearned commission may differ by design).
-- ins_import_opening_report compares them after posting: the opening journal,
-- the open items and the legacy totals, side by side, per currency.
--
-- Covered:
--   R1  not posted yet -> refused; posted and agreeing -> every cell matches
--   R2  a legacy total that disagrees is REPORTED but never blocked the commit
--   R3  a measure the sheet did not record is "not recorded", not a difference
--   R4  a currency only the legacy sheet knows about is a difference, not absent
--   R5  a fully settled policy posts zero payable/unearned and says so
--   R6  access: members read, another tenant sees nothing
--
-- Run against a fresh local stack only (`supabase db reset`). One
-- transaction, ROLLBACK at the end; any RAISE EXCEPTION fails the run.

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then return; end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.policy(p_no text) returns uuid
language sql stable as $$
  select id from ins_policies where policy_no = p_no and tenant_id = get_my_tenant_id();
$$;

create function pg_temp.line(p_batch uuid, p_code text, p_side text) returns numeric
language sql stable as $$
  select coalesce(sum(case when p_side = 'D' then l.debit else l.credit end), 0)
    from journal_entries j
    join journal_entry_lines l on l.journal_entry_id = j.id
    join gl_accounts a on a.id = l.gl_account_id
   where j.source_type = 'ins_import_opening' and j.source_id = p_batch
     and a.account_code = p_code;
$$;

create function pg_temp.line_ccy(p_batch uuid, p_code text, p_side text, p_ccy text) returns numeric
language sql stable as $$
  select coalesce(sum(case when p_side = 'D' then l.debit else l.credit end), 0)
    from journal_entries j
    join journal_entry_lines l on l.journal_entry_id = j.id
    join gl_accounts a on a.id = l.gl_account_id
   where j.source_type = 'ins_import_opening' and j.source_id = p_batch
     and a.account_code = p_code and l.currency = p_ccy;
$$;

create function pg_temp.count_code(p_batch uuid, p_code text) returns integer
language sql stable as $$
  select count(*)::int
    from journal_entries j
    join journal_entry_lines l on l.journal_entry_id = j.id
    join gl_accounts a on a.id = l.gl_account_id
   where j.source_type = 'ins_import_opening' and j.source_id = p_batch
     and a.account_code = p_code;
$$;

create function pg_temp.recon(p_batch uuid, p_currency text, p_measure text) returns text
language sql stable as $$
  select format('%s|%s|%s', trim_scale(r.imported_amount),
                coalesce(trim_scale(r.control_amount)::text, 'null'),
                coalesce(r.match::text, 'null'))
    from public.ins_import_reconciliation(p_batch) r
   where r.currency = p_currency and r.measure = p_measure;
$$;

-- Stage, validate, commit: returns the batch id (asserts it validated).
create function pg_temp.batch(p_label text, p_policy_no text, p_gross text,
                              p_receipts text, p_remits text, p_controls jsonb,
                              p_approve_reason text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_rep jsonb; v_reviewer uuid;
begin
  select id into v_id from public.ins_import_create_batch(p_label, current_date);
  perform public.ins_import_stage_rows(v_id, 'policies', jsonb_build_array(jsonb_build_object(
    'legacy_policy_no', p_policy_no, 'client_name', 'Bank Client', 'insurer', 'BNKINS1',
    'product_line', 'GEN', 'inception_date', '2026-01-01', 'expiry_date', '2026-12-31',
    'currency', 'UGX', 'gross_premium', p_gross, 'commission_rate_pct', '10')));
  if p_receipts is not null then
    perform public.ins_import_stage_rows(v_id, 'receipts', jsonb_build_array(jsonb_build_object(
      'legacy_policy_no', p_policy_no, 'receipt_date', '2026-02-01',
      'reference', 'R-' || p_policy_no, 'amount', p_receipts)));
  end if;
  if p_remits is not null then
    perform public.ins_import_stage_rows(v_id, 'remittances', jsonb_build_array(jsonb_build_object(
      'legacy_policy_no', p_policy_no, 'remit_date', '2026-03-01',
      'reference', 'M-' || p_policy_no, 'amount', p_remits)));
  end if;
  if p_controls is not null then
    perform public.ins_import_stage_rows(v_id, 'control_totals', p_controls);
  end if;
  v_rep := public.ins_import_validate_batch(v_id);
  if (v_rep ->> 'error_count')::int <> 0 then
    raise exception 'fixture: batch "%" did not validate: %', p_label, v_rep::text;
  end if;
  -- A recorded balance that disagrees with the float is binding
  -- (20261110170000), so a batch like that is approved by a second person
  -- before it can commit - which is the point of these scenarios.
  if p_approve_reason is not null then
    select k.mgr2 into v_reviewer from pg_temp.k_ids k;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_reviewer, 'role', 'authenticated')::text, true);
    perform public.ins_import_override_control_totals(v_id, p_approve_reason);
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select k.mgr from pg_temp.k_ids k), 'role', 'authenticated')::text, true);
  end if;
  perform public.ins_import_commit_policies(v_id);
  return v_id;
end $$;

---------------------------------------------------------------------
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.k_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mgr2,
       gen_random_uuid() as mem, gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'Bank Brokerage A' from pg_temp.k_ids
union all select tb, 'Bank Brokerage B' from pg_temp.k_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'bnk-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.k_ids union all select mgr2 from pg_temp.k_ids
      union all select mem from pg_temp.k_ids union all select mgr_b from pg_temp.k_ids) u;

insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Bank Manager A', 'bnk-' || i.mgr || '@test.local', false from pg_temp.k_ids i
union all select i.mgr2, i.ta, 'Bank Reviewer A', 'bnk-' || i.mgr2 || '@test.local', true from pg_temp.k_ids i
union all select i.mem, i.ta, 'Bank Member A', 'bnk-' || i.mem || '@test.local', false from pg_temp.k_ids i
union all select i.mgr_b, i.tb, 'Bank Manager B', 'bnk-' || i.mgr_b || '@test.local', false from pg_temp.k_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.k_ids union all select tb, 'insurance' from pg_temp.k_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.k_ids
union all select ta, mgr2, 'insurance', 'manager' from pg_temp.k_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.k_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.k_ids;

insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
select i.ta, v.code, v.name, v.type, v.control
from pg_temp.k_ids i,
     (values ('1020', 'Client Money Bank', 'asset', true),
             ('1100', 'Accounts Receivable Control', 'asset', true),
             ('2010', 'Insurer Payable (Premiums)', 'liability', true),
             ('2400', 'Unearned Commission', 'liability', true),
             ('3200', 'Retained Earnings', 'equity', false),
             ('3900', 'Opening Balance Clearing', 'equity', false)) v(code, name, type, control);

insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
select i.ta, v.role, a.id
from pg_temp.k_ids i
cross join (values ('client_money_bank', '1020'), ('ar_control', '1100'),
                   ('insurer_payable', '2010'), ('unearned_commission', '2400'),
                   ('retained_earnings', '3200'), ('opening_balance_clearing', '3900')) v(role, code)
join gl_accounts a on a.tenant_id = i.ta and a.account_code = v.code;

select set_config('reg.via_rpc', 'on', true);
select set_config('fx.via_rpc', 'on', true);
do $$
declare r uuid; f uuid; ta uuid; approver uuid;
begin
  select k.ta, k.mgr2 into ta, approver from pg_temp.k_ids k;
  insert into regulatory_parameters
    (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture')
  returning id into r;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now()
   where id = r;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
  values (ta, 'USD', current_date, 3800, 'fixture') returning id into f;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now()
   where id = f;
end $$;
select set_config('reg.via_rpc', 'off', true);
select set_config('fx.via_rpc', 'off', true);

select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.k_master as
with i1 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'BNKINS1', 'Bank Insurer One', true from pg_temp.k_ids returning id),
     pl as (insert into ins_product_lines (tenant_id, code, name, class, is_active)
            select ta, 'GEN', 'General', 'general', true from pg_temp.k_ids returning id),
     bd as (insert into bd_clients (tenant_id, name)
            select ta, 'Bank Client' from pg_temp.k_ids returning id, tenant_id),
     cl as (insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
            select tenant_id, id, 'corporate', 'verified' from bd returning id)
select i1.id as insurer1, pl.id as product_line_id, cl.id as client_id from i1, pl, cl;
select set_config('ins.via_rpc', 'off', true);

-- One report cell as "posted|open items|control|match|subledger_match".
create function pg_temp.rep(p_batch uuid, p_currency text, p_measure text) returns text
language sql stable as $$
  select format('%s|%s|%s|%s|%s',
                trim_scale(r.posted_amount),
                coalesce(trim_scale(r.open_item_amount)::text, 'null'),
                coalesce(trim_scale(r.control_amount)::text, 'null'),
                coalesce(r.match::text, 'null'),
                coalesce(r.subledger_match::text, 'null'))
    from public.ins_import_opening_report(p_batch) r
   where r.currency = p_currency and r.measure = p_measure;
$$;

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  o  pg_temp.k_ids;
  b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid;
  r  jsonb;
begin
  select * into o from pg_temp.k_ids;
  perform pg_temp.jwt(o.mgr);

  -- Shape of the standard batch: gross 1,000,000, commission 100,000,
  -- receipts 650,000, remittances 300,000 => receivable 350,000,
  -- payable 600,000, deferred (unearned) commission 100,000.

  -------------------------------------------------------------------
  -- R1. Not posted yet, then posted and agreeing
  -------------------------------------------------------------------
  b1 := pg_temp.batch('R1 agrees', 'R1-P1', '1000000', '650000', '300000', $j$[
    {"currency":"UGX","gross_premium":"1000000","commission":"100000","receipts":"650000","remittances":"300000",
     "client_money":"350000","receivables":"350000","payables":"600000","unearned_commission":"100000"}]$j$::jsonb);
  perform pg_temp.expect_error(format('select * from public.ins_import_opening_report(%L)', b1),
    'INS_IMPORT_OPENING_NOT_POSTED', 'R1 there is nothing to report before the opening is posted');

  r := public.ins_import_post_opening_position(b1);
  perform pg_temp.assert((select count(*) from public.ins_import_opening_report(b1)) = 3,
    'R1 one currency x three measures: ' || r::text);
  perform pg_temp.assert(pg_temp.rep(b1, 'UGX', 'receivables') = '350000|350000|350000|true|true',
    'R1 receivables: journal, open items and legacy agree: ' || coalesce(pg_temp.rep(b1, 'UGX', 'receivables'), 'no row'));
  perform pg_temp.assert(pg_temp.rep(b1, 'UGX', 'payables') = '600000|600000|600000|true|true',
    'R1 payables: journal, open items and legacy agree: ' || coalesce(pg_temp.rep(b1, 'UGX', 'payables'), 'no row'));
  perform pg_temp.assert(pg_temp.rep(b1, 'UGX', 'unearned_commission') = '100000|null|100000|true|null',
    'R1 unearned commission has no sub-ledger, so that cell says nothing: ' || coalesce(pg_temp.rep(b1, 'UGX', 'unearned_commission'), 'no row'));
  raise notice 'PASS: R1 the report compares journal, open items and legacy totals';

  -------------------------------------------------------------------
  -- R2. A disagreeing legacy total is reported, and never blocked the commit
  -------------------------------------------------------------------
  -- pg_temp.batch commits without any approval, so reaching the report at all
  -- proves these three measures are not part of the gate.
  b2 := pg_temp.batch('R2 legacy differs', 'R2-P1', '1000000', '650000', '300000', $j$[
    {"currency":"UGX","gross_premium":"1000000","commission":"100000","receipts":"650000","remittances":"300000",
     "client_money":"350000","receivables":"360000","payables":"600000","unearned_commission":"250000"}]$j$::jsonb);
  perform pg_temp.assert((select status from ins_import_batches where id = b2) = 'committed',
    'R2 differences in these three measures do not stop the commit');
  perform public.ins_import_post_opening_position(b2);
  perform pg_temp.assert(pg_temp.rep(b2, 'UGX', 'receivables') = '350000|350000|360000|false|true',
    'R2 the receivable difference is reported: ' || coalesce(pg_temp.rep(b2, 'UGX', 'receivables'), 'no row'));
  perform pg_temp.assert(pg_temp.rep(b2, 'UGX', 'unearned_commission') = '100000|null|250000|false|null',
    'R2 the unearned difference is reported (Option A may differ from the legacy basis by design)');
  perform pg_temp.assert(pg_temp.rep(b2, 'UGX', 'payables') = '600000|600000|600000|true|true',
    'R2 the agreeing measure still says so');
  raise notice 'PASS: R2 differences are reported, not enforced';

  -------------------------------------------------------------------
  -- R3. Not recorded is not a difference
  -------------------------------------------------------------------
  b3 := pg_temp.batch('R3 not recorded', 'R3-P1', '1000000', '650000', '300000', $j$[
    {"currency":"UGX","gross_premium":"1000000","commission":"100000","receipts":"650000","remittances":"300000",
     "client_money":"350000"}]$j$::jsonb);
  perform public.ins_import_post_opening_position(b3);
  perform pg_temp.assert(pg_temp.rep(b3, 'UGX', 'receivables') = '350000|350000|null|null|true',
    'R3 an unrecorded measure reports null, not a false difference: ' || coalesce(pg_temp.rep(b3, 'UGX', 'receivables'), 'no row'));
  perform pg_temp.assert(pg_temp.rep(b3, 'UGX', 'payables') = '600000|600000|null|null|true',
    'R3 same for payables');
  raise notice 'PASS: R3 "not recorded" stays distinct from "differs"';

  -------------------------------------------------------------------
  -- R4. A currency only the legacy sheet knows about
  -------------------------------------------------------------------
  b4 := pg_temp.batch('R4 lost currency', 'R4-P1', '1000000', '650000', '300000', $j$[
    {"currency":"UGX","gross_premium":"1000000","commission":"100000","receipts":"650000","remittances":"300000",
     "client_money":"350000","receivables":"350000","payables":"600000","unearned_commission":"100000"},
    {"currency":"EUR","receivables":"5,000,000"}]$j$::jsonb);
  perform public.ins_import_post_opening_position(b4);
  perform pg_temp.assert(pg_temp.rep(b4, 'EUR', 'receivables') = '0|0|5000000|false|true',
    'R4 the lost currency is a difference, not an absent row: ' || coalesce(pg_temp.rep(b4, 'EUR', 'receivables'), 'no row'));
  perform pg_temp.assert(pg_temp.rep(b4, 'EUR', 'payables') = '0|0|null|null|true',
    'R4 and its unrecorded measures stay "not recorded"');
  perform pg_temp.assert(pg_temp.rep(b4, 'UGX', 'receivables') = '350000|350000|350000|true|true',
    'R4 the currency that was booked is unaffected');
  raise notice 'PASS: R4 a currency present only in the legacy sheet is reported';

  -------------------------------------------------------------------
  -- R5. A fully settled policy: nothing receivable, nothing payable
  -------------------------------------------------------------------
  -- receipts = gross, remittances = net premium: commission is earned at
  -- cut-over, so nothing is deferred and nothing is outstanding.
  b5 := pg_temp.batch('R5 settled', 'R5-P1', '1000000', '1000000', '900000', $j$[
    {"currency":"UGX","gross_premium":"1000000","commission":"100000","receipts":"1000000","remittances":"900000",
     "receivables":"0","payables":"0","unearned_commission":"0"}]$j$::jsonb);
  perform public.ins_import_post_opening_position(b5);
  perform pg_temp.assert(pg_temp.rep(b5, 'UGX', 'receivables') = '0|0|0|true|true',
    'R5 a settled policy has no receivable: ' || coalesce(pg_temp.rep(b5, 'UGX', 'receivables'), 'no row'));
  perform pg_temp.assert(pg_temp.rep(b5, 'UGX', 'payables') = '0|0|0|true|true', 'R5 no payable');
  perform pg_temp.assert(pg_temp.rep(b5, 'UGX', 'unearned_commission') = '0|null|0|true|null',
    'R5 commission was earned at cut-over, so none is unearned');
  raise notice 'PASS: R5 zero is reported as zero and matches a recorded zero';

  -------------------------------------------------------------------
  -- R6. Access
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mem);
  perform pg_temp.assert((select count(*) from public.ins_import_opening_report(b1)) = 3,
    'R6 a member can read the report');
  perform pg_temp.jwt(o.mgr_b);
  perform pg_temp.expect_error(format('select * from public.ins_import_opening_report(%L)', b1),
    'INS_IMPORT_BATCH_NOT_FOUND', 'R6 another tenant cannot read this batch''s report');
  perform pg_temp.jwt(o.mgr);
  raise notice 'PASS: R6 read access follows the reconciliation';
end $$;

select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
    where routine_schema = 'public' and routine_name = 'ins_import_opening_report'
      and grantee in ('anon', 'PUBLIC')),
  'the report is not executable by anon or PUBLIC');
select pg_temp.assert(
  (select count(*) = 1 from information_schema.routine_privileges
    where routine_schema = 'public' and routine_name = 'ins_import_opening_report'
      and grantee = 'authenticated' and privilege_type = 'EXECUTE'),
  'the report is executable by authenticated users');

rollback;
