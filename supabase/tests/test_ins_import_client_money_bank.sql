-- Insurance brokerage: leg 4, the client-money bank balance at cut-over
-- (20261110190000_ins_import_client_money_bank.sql).
--
-- The float the booked history implies is receipts minus remittances. The
-- opening position now debits the balance the reviewer counted at cut-over
-- (control total `client_money`) to the client-money bank account, and pushes
-- the difference into opening_balance_clearing. When the two agree the
-- clearing line is not posted at all, which is what "clearing nets to zero"
-- in IN_FORCE_IMPORT.md section 4.5/5 actually asks for.
--
-- Covered:
--   L1  balance recorded and equal to the float  -> bank leg, no clearing line
--   L2  balance lower than the float             -> bank leg + debit clearing
--   L3  balance higher than the float            -> bank leg + credit clearing
--   L4  no balance recorded                      -> the float stays in clearing
--   L5  a chart with no client_money_bank        -> refused only when a
--                                                   balance was recorded
--   L6  a balance that disagrees blocks commit, and a manager can approve it
--   L7  a negative balance never reaches the ledger
--   L8  mixed currencies: the leg is per currency
--
-- Run against a fresh local stack only (`supabase db reset`, or
-- pgharness/build.sh here). One transaction, ROLLBACK at the end.

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

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  o    pg_temp.k_ids;
  b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; b6 uuid; b7 uuid; b8 uuid; b9 uuid;
  r    jsonb;
begin
  select * into o from pg_temp.k_ids;
  perform pg_temp.jwt(o.mgr);

  -- The shape of every batch below: gross 1,000,000, commission 100,000,
  -- receipts 650,000, remittances 300,000 => float 350,000, receivable 350,000,
  -- payable 600,000, deferred commission 100,000.

  -------------------------------------------------------------------
  -- L1. The reviewer's balance equals the float: clearing nets to zero
  -------------------------------------------------------------------
  b1 := pg_temp.batch('L1 bank equals float', 'L1-P1', '1000000', '650000', '300000', $j$[
    {"currency":"UGX","gross_premium":"1000000","commission":"100000","receipts":"650000","remittances":"300000","client_money":"350000"}]$j$::jsonb);
  r := public.ins_import_post_opening_position(b1);
  perform pg_temp.assert(pg_temp.line(b1, '1020', 'D') = 350000,
    'L1 the client-money bank is debited with the counted balance: ' || r::text);
  perform pg_temp.assert(pg_temp.count_code(b1, '3900') = 0,
    'L1 clearing is not posted at all when the bank balance explains the float');
  perform pg_temp.assert((r ->> 'client_money_bank_total')::numeric = 350000,
    'L1 the payload reports the bank leg');
  perform pg_temp.assert(pg_temp.line(b1, '1100', 'D') = 350000
                         and pg_temp.line(b1, '2010', 'C') = 600000
                         and pg_temp.line(b1, '2400', 'C') = 100000,
    'L1 the other legs are unchanged');
  raise notice 'PASS: L1 a counted balance that matches the float clears to zero';

  -------------------------------------------------------------------
  -- L2. The bank holds less than the float: the rest stays visible
  -------------------------------------------------------------------
  b2 := pg_temp.batch('L2 bank below float', 'L2-P1', '1000000', '650000', '300000', $j$[
    {"currency":"UGX","client_money":"200000"}]$j$::jsonb,
     'Two receipts cleared after the cut-over date and are still in transit');
  perform public.ins_import_post_opening_position(b2);
  perform pg_temp.assert(pg_temp.line(b2, '1020', 'D') = 200000, 'L2 the counted balance reaches the bank');
  perform pg_temp.assert(pg_temp.line(b2, '3900', 'D') = 150000,
    'L2 the unexplained 150,000 stays in clearing instead of being assumed to be in the bank');
  raise notice 'PASS: L2 money the history expects but the bank does not hold stays in clearing';

  -------------------------------------------------------------------
  -- L3. The bank holds more than the float
  -------------------------------------------------------------------
  b3 := pg_temp.batch('L3 bank above float', 'L3-P1', '1000000', '650000', '300000', $j$[
    {"currency":"UGX","client_money":"400000"}]$j$::jsonb,
     'The client money account also holds premiums outside this portfolio');
  perform public.ins_import_post_opening_position(b3);
  perform pg_temp.assert(pg_temp.line(b3, '1020', 'D') = 400000, 'L3 the counted balance reaches the bank');
  perform pg_temp.assert(pg_temp.line(b3, '3900', 'C') = 50000,
    'L3 the 50,000 the history cannot explain sits on the credit side of clearing');
  raise notice 'PASS: L3 a surplus in the bank is shown, not silently absorbed';

  -------------------------------------------------------------------
  -- L4. No balance recorded: exactly the previous behaviour
  -------------------------------------------------------------------
  b4 := pg_temp.batch('L4 no balance', 'L4-P1', '1000000', '650000', '300000', null);
  perform public.ins_import_post_opening_position(b4);
  perform pg_temp.assert(pg_temp.count_code(b4, '1020') = 0, 'L4 no bank leg without a recorded balance');
  perform pg_temp.assert(pg_temp.line(b4, '3900', 'D') = 350000,
    'L4 the float stays in clearing, as before');
  raise notice 'PASS: L4 without a counted balance nothing changes';

  -------------------------------------------------------------------
  -- L5. A chart without the client-money account
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mgr);
  delete from gl_posting_rules
   where tenant_id = o.ta and account_role = 'client_money_bank';

  b5 := pg_temp.batch('L5 no bank rule', 'L5-P1', '1000', '600', '300', $j$[
    {"currency":"UGX","client_money":"200"}]$j$::jsonb,
     'Counted balance, approved while the chart is being repaired');
  perform pg_temp.expect_error(format('select public.ins_import_post_opening_position(%L)', b5),
    'INS_POSTING_RULE_MISSING', 'L5 a recorded balance needs a client_money_bank account');
  perform pg_temp.assert(not exists (select 1 from journal_entries
                                      where source_type = 'ins_import_opening' and source_id = b5),
    'L5 nothing was posted');

  -- the same batch without a recorded balance posts without the rule
  b6 := pg_temp.batch('L5 no balance either', 'L5-P2', '1000', '600', '300', null);
  perform public.ins_import_post_opening_position(b6);
  perform pg_temp.assert(pg_temp.line(b6, '3900', 'D') = 300,
    'L5 a tenant without the account still posts when no balance was recorded');

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
  select o.ta, 'client_money_bank', a.id from gl_accounts a
   where a.tenant_id = o.ta and a.account_code = '1020';
  raise notice 'PASS: L5 the bank account is required only when a balance was recorded';

  -------------------------------------------------------------------
  -- L6. A bank balance that disagrees blocks the commit until approved
  -------------------------------------------------------------------
  select id into b7 from public.ins_import_create_batch('L6 bank disagrees', current_date);
  perform public.ins_import_stage_rows(b7, 'policies', $j$[
    {"legacy_policy_no":"L6-P1","client_name":"Bank Client","insurer":"BNKINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b7, 'receipts', $j$[
    {"legacy_policy_no":"L6-P1","receipt_date":"2026-02-01","reference":"RL6","amount":"650000"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b7, 'control_totals', $j$[
    {"currency":"UGX","bank":"999999"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b7);

  perform pg_temp.assert(pg_temp.recon(b7, 'UGX', 'client_money') = '650000|999999|false',
    'L6 the float is compared with the counted balance before anything is posted: '
    || pg_temp.recon(b7, 'UGX', 'client_money'));
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b7),
    'INS_IMPORT_CONTROL_MISMATCH', 'L6 a bank balance that disagrees stops the commit');

  perform pg_temp.jwt(o.mgr2);
  perform public.ins_import_override_control_totals(b7,
    'The client money account also holds a premium received after the cut-over date');
  perform pg_temp.jwt(o.mgr);
  perform public.ins_import_commit_policies(b7);
  perform pg_temp.assert((select status from ins_import_batches where id = b7) = 'committed',
    'L6 the approved batch commits');
  raise notice 'PASS: L6 the counted balance is binding, and approvable by a second person';

  -------------------------------------------------------------------
  -- L7. A negative balance never reaches the ledger
  -------------------------------------------------------------------
  select id into b8 from public.ins_import_create_batch('L7 negative balance', current_date);
  perform public.ins_import_stage_rows(b8, 'policies', $j$[
    {"legacy_policy_no":"L7-P1","client_name":"Bank Client","insurer":"BNKINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b8, 'receipts', $j$[
    {"legacy_policy_no":"L7-P1","receipt_date":"2026-02-01","reference":"RL7","amount":"600"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b8, 'control_totals', $j$[
    {"currency":"UGX","client_money":"-5"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b8);

  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b8),
    'INS_IMPORT_CONTROL_MISMATCH', 'L7 a negative balance is a recorded difference, so it stops the commit');
  perform pg_temp.jwt(o.mgr2);
  perform public.ins_import_override_control_totals(b8, 'The clerk typed a negative balance by mistake');
  perform pg_temp.jwt(o.mgr);
  perform public.ins_import_commit_policies(b8);
  perform pg_temp.expect_error(format('select public.ins_import_post_opening_position(%L)', b8),
    'INS_IMPORT_BANK_NEGATIVE', 'L7 the ledger refuses a negative client-money balance');
  perform pg_temp.assert(not exists (select 1 from journal_entries
                                      where source_type = 'ins_import_opening' and source_id = b8),
    'L7 nothing was posted');
  raise notice 'PASS: L7 a negative balance cannot reach the ledger';

  -------------------------------------------------------------------
  -- L8. Mixed currencies: the leg is per currency
  -------------------------------------------------------------------
  select id into b9 from public.ins_import_create_batch('L8 mixed currency', current_date);
  perform public.ins_import_stage_rows(b9, 'policies', $j$[
    {"legacy_policy_no":"L8-UGX","client_name":"Bank Client","insurer":"BNKINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"},
    {"legacy_policy_no":"L8-USD","client_name":"Bank Client","insurer":"BNKINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"USD",
     "gross_premium":"10000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b9, 'receipts', $j$[
    {"legacy_policy_no":"L8-UGX","receipt_date":"2026-02-01","reference":"RU","amount":"650000"},
    {"legacy_policy_no":"L8-USD","receipt_date":"2026-02-01","reference":"RD","amount":"4000"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b9, 'remittances', $j$[
    {"legacy_policy_no":"L8-UGX","remit_date":"2026-03-01","reference":"MU","amount":"300000"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b9, 'control_totals', $j$[
    {"currency":"UGX","client_money":"350000"},
    {"currency":"USD","client_money":"4000"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b9);
  perform public.ins_import_commit_policies(b9);
  r := public.ins_import_post_opening_position(b9);

  perform pg_temp.assert(pg_temp.line_ccy(b9, '1020', 'D', 'UGX') = 350000
                         and pg_temp.line_ccy(b9, '1020', 'D', 'USD') = 4000,
    'L8 each currency carries its own bank balance');
  perform pg_temp.assert(pg_temp.count_code(b9, '3900') = 0,
    'L8 both currencies clear to zero because both balances were counted');
  perform pg_temp.assert((r -> 'client_money_bank_by_currency' ->> 'UGX')::numeric = 350000
                         and (r -> 'client_money_bank_by_currency' ->> 'USD')::numeric = 4000,
    'L8 the payload reports the leg per currency: ' || r::text);
  perform pg_temp.assert(not exists (
      select 1 from (
        select l.currency, sum(l.debit) - sum(l.credit) as d, sum(l.base_debit) - sum(l.base_credit) as b
          from journal_entry_lines l
          join journal_entries j on j.id = l.journal_entry_id
         where j.source_id = b9 group by l.currency) x
       where abs(x.d) > 0.005 or abs(x.b) > 0.005),
    'L8 every currency still balances, in itself and in base');
  raise notice 'PASS: L8 the bank leg is per currency';
end $$;

rollback;
