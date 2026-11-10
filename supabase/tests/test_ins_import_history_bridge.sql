-- Insurance brokerage: staged history becomes real history at commit
-- (20261110140000_ins_import_history_bridge.sql).
--
-- The failure this covers: the wizard stages the receipts and remittances
-- sheets, validates and commits, but nothing ever promoted those rows into
-- ins_import_receipts / ins_import_remittances, so the opening position was
-- posted with no history at all - full receivable, empty clearing.
--
-- Covered:
--   H1  wizard path (stage sheets, validate, commit) promotes history
--   H2  the same portfolio imported both ways posts an identical opening
--   H3  co-insured policy: staged remittances reach the per-share allocation
--   H4  a batch with no history sheets still commits and posts
--   H5  re-recording history after promotion is a counted skip, no duplicates
--   H6  a staged receipt above the gross premium fails validation and blocks commit
--   H7  the internal helpers are not reachable by clients
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

-- The opening entry for a batch, as a comparable vector: account, side,
-- currency and amount for every line.
create function pg_temp.opening(p_batch uuid) returns text
language sql stable as $$
  select coalesce(string_agg(format('%s|%s|%s|%s',
             a.account_code,
             case when l.debit <> 0 then 'D' else 'C' end,
             l.currency,
             round(case when l.debit <> 0 then l.debit else l.credit end, 2)), ' ; '
           order by a.account_code,
                    case when l.debit <> 0 then 'D' else 'C' end, l.currency), '(none)')
    from journal_entries j
    join journal_entry_lines l on l.journal_entry_id = j.id
    join gl_accounts a on a.id = l.gl_account_id
   where j.source_type = 'ins_import_opening' and j.source_id = p_batch;
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

-- Stage sheets, validate, commit -- exactly what the wizard does.
create function pg_temp.wizard_batch(p_label text, p_sheets jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_rep jsonb; v_commit jsonb; k text;
begin
  select id into v_id from public.ins_import_create_batch(p_label, current_date);
  for k in select jsonb_object_keys(p_sheets) loop
    perform public.ins_import_stage_rows(v_id, k, p_sheets -> k);
  end loop;
  v_rep := public.ins_import_validate_batch(v_id);
  if (v_rep ->> 'error_count')::int <> 0 then
    return jsonb_build_object('batch_id', v_id, 'validated', false, 'report', v_rep);
  end if;
  v_commit := public.ins_import_commit_policies(v_id);
  return jsonb_build_object('batch_id', v_id, 'validated', true, 'commit', v_commit);
end $$;

---------------------------------------------------------------------
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.b_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem, gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'Bridge Brokerage A' from pg_temp.b_ids
union all select tb, 'Bridge Brokerage B' from pg_temp.b_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'brg-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.b_ids union all select mem from pg_temp.b_ids
      union all select mgr_b from pg_temp.b_ids) u;

insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Bridge Manager A', 'brg-' || i.mgr || '@test.local', false from pg_temp.b_ids i
union all select i.mem, i.ta, 'Bridge Member A', 'brg-' || i.mem || '@test.local', false from pg_temp.b_ids i
union all select i.mgr_b, i.tb, 'Bridge Manager B', 'brg-' || i.mgr_b || '@test.local', false from pg_temp.b_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.b_ids union all select tb, 'insurance' from pg_temp.b_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.b_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.b_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.b_ids;

insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
select i.ta, v.code, v.name, v.type, v.control
from pg_temp.b_ids i,
     (values ('1100', 'Accounts Receivable Control', 'asset', true),
             ('2010', 'Insurer Payable (Premiums)', 'liability', true),
             ('2400', 'Unearned Commission', 'liability', true),
             ('3200', 'Retained Earnings', 'equity', false),
             ('3900', 'Opening Balance Clearing', 'equity', false)) v(code, name, type, control);

insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
select i.ta, v.role, a.id
from pg_temp.b_ids i
cross join (values ('ar_control', '1100'), ('insurer_payable', '2010'),
                   ('unearned_commission', '2400'), ('retained_earnings', '3200'),
                   ('opening_balance_clearing', '3900')) v(role, code)
join gl_accounts a on a.tenant_id = i.ta and a.account_code = v.code;

select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.b_master as
with i1 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'BRGINS1', 'Bridge Insurer One', true from pg_temp.b_ids returning id),
     i2 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'BRGINS2', 'Bridge Insurer Two', true from pg_temp.b_ids returning id),
     pl as (insert into ins_product_lines (tenant_id, code, name, class, is_active)
            select ta, 'GEN', 'General', 'general', true from pg_temp.b_ids returning id),
     bd as (insert into bd_clients (tenant_id, name)
            select ta, 'Bridge Client' from pg_temp.b_ids returning id, tenant_id),
     cl as (insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
            select tenant_id, id, 'corporate', 'verified' from bd returning id)
select i1.id as insurer1, i2.id as insurer2, pl.id as product_line_id, cl.id as client_id
  from i1, i2, pl, cl;
select set_config('ins.via_rpc', 'off', true);

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  o    pg_temp.b_ids;
  r    jsonb;
  b1   uuid; b2   uuid; b3   uuid; b4   uuid; b5   uuid; b6   uuid;
  p1   uuid;
  v_wizard text;
  v_api    text;
  n    integer;
  amt  numeric;
begin
  select * into o from pg_temp.b_ids;
  perform pg_temp.jwt(o.mgr);

  -------------------------------------------------------------------
  -- H1. Wizard path: staged sheets promote at commit
  -------------------------------------------------------------------
  r := pg_temp.wizard_batch('H1 wizard', jsonb_build_object(
    'policies', $j$[
      {"legacy_policy_no":"H1-P1","client_name":"Bridge Client","insurer":"BRGINS1","product_line":"GEN",
       "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
       "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb,
    'receipts', $j$[
      {"legacy_policy_no":"H1-P1","receipt_date":"2026-03-01","reference":"R-1","amount":"400000"},
      {"legacy_policy_no":"H1-P1","receipt_date":"2026-05-01","reference":"R-2","amount":"250000"}]$j$::jsonb,
    'remittances', $j$[
      {"legacy_policy_no":"H1-P1","remit_date":"2026-04-01","reference":"M-1","amount":"300000"}]$j$::jsonb));
  perform pg_temp.assert((r ->> 'validated')::boolean, 'H1 batch validates: ' || (r -> 'report')::text);
  b1 := (r ->> 'batch_id')::uuid;
  perform pg_temp.assert((r -> 'commit' ->> 'history_receipts_recorded')::int = 2,
    'H1 commit reports two receipts promoted: ' || (r -> 'commit')::text);
  perform pg_temp.assert((r -> 'commit' ->> 'history_remittances_recorded')::int = 1,
    'H1 commit reports one remittance promoted');

  perform pg_temp.assert((select count(*) from ins_import_receipts
                           where batch_id = b1 and tenant_id = o.ta) = 2,
    'H1 the typed receipt table holds both staged rows');
  perform pg_temp.assert((select sum(amount) from ins_import_receipts where batch_id = b1) = 650000,
    'H1 the promoted receipts keep their amounts');
  perform pg_temp.assert((select count(*) from ins_import_remittances where batch_id = b1) = 1,
    'H1 the typed remittance table holds the staged row');
  perform pg_temp.assert((select r.policy_id from ins_import_receipts r where r.batch_id = b1 limit 1)
                         = pg_temp.policy('H1-P1'),
    'H1 promoted rows point at the committed policy, not the staged row');

  r := public.ins_import_post_opening_position(b1);
  perform pg_temp.assert(pg_temp.line(b1, '1100', 'D') = 350000,
    'H1 receivable is billed minus the promoted receipts (1,000,000 - 650,000)');
  perform pg_temp.assert(pg_temp.line(b1, '2010', 'C') = 600000,
    'H1 payable is net premium minus the promoted remittance (900,000 - 300,000)');
  perform pg_temp.assert(pg_temp.line(b1, '2400', 'C') = 100000, 'H1 commission is deferred');
  perform pg_temp.assert(pg_temp.line(b1, '3900', 'D') = 350000,
    'H1 clearing holds receipts minus remittances (650,000 - 300,000)');
  raise notice 'PASS: H1 staged sheets promote at commit and drive the opening position';

  -------------------------------------------------------------------
  -- H2. The same portfolio imported both ways posts the same opening
  -------------------------------------------------------------------
  v_wizard := pg_temp.opening(b1);

  select id into b2 from public.ins_import_create_batch('H2 via API', current_date);
  perform public.ins_import_stage_rows(b2, 'policies', $j$[
    {"legacy_policy_no":"H2-P1","client_name":"Bridge Client","insurer":"BRGINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b2);
  perform public.ins_import_commit_policies(b2);
  p1 := pg_temp.policy('H2-P1');
  perform public.ins_import_record_history(b2, jsonb_build_array(
      jsonb_build_object('policy_id', p1, 'receipt_date', date '2026-03-01', 'reference', 'R-1', 'amount', 400000),
      jsonb_build_object('policy_id', p1, 'receipt_date', date '2026-05-01', 'reference', 'R-2', 'amount', 250000)),
    jsonb_build_array(
      jsonb_build_object('policy_id', p1, 'remit_date', date '2026-04-01', 'reference', 'M-1', 'amount', 300000)));
  perform public.ins_import_post_opening_position(b2);

  v_api := pg_temp.opening(b2);
  perform pg_temp.assert(v_wizard = v_api,
    format('H2 the two import paths post an identical opening (wizard: %s / API: %s)', v_wizard, v_api));
  raise notice 'PASS: H2 staged sheets and the JSON API post the same opening';

  -------------------------------------------------------------------
  -- H3. Co-insured: the staged remittance reaches the per-share split
  -------------------------------------------------------------------
  r := pg_temp.wizard_batch('H3 co-insured', jsonb_build_object(
    'policies', $j$[
      {"legacy_policy_no":"H3-P1","client_name":"Bridge Client","insurer":"BRGINS1","product_line":"GEN",
       "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
       "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb,
    'shares', $j$[
      {"legacy_policy_no":"H3-P1","insurer":"BRGINS1","share_pct":"60"},
      {"legacy_policy_no":"H3-P1","insurer":"BRGINS2","share_pct":"40"}]$j$::jsonb,
    'receipts', $j$[
      {"legacy_policy_no":"H3-P1","receipt_date":"2026-02-01","reference":"RC","amount":"400"}]$j$::jsonb,
    'remittances', $j$[
      {"legacy_policy_no":"H3-P1","remit_date":"2026-03-01","reference":"RM","amount":"450"}]$j$::jsonb));
  perform pg_temp.assert((r ->> 'validated')::boolean, 'H3 batch validates: ' || (r -> 'report')::text);
  b3 := (r ->> 'batch_id')::uuid;
  perform public.ins_import_post_opening_position(b3);

  perform pg_temp.assert(pg_temp.line(b3, '1100', 'D') = 600, 'H3 receivable is billed minus the receipts');
  perform pg_temp.assert(pg_temp.line(b3, '2010', 'C') = 450,
    'H3 payables total net premium minus the remittance (900 - 450)');
  perform pg_temp.assert(pg_temp.line(b3, '3900', 'D') = 0 and pg_temp.line(b3, '3900', 'C') = 50,
    'H3 clearing is receipts minus remittances (400 - 450 = -50), carried as a credit');
  perform pg_temp.assert((select count(*) from fin_open_items i
                           join ins_policies p on p.policy_no = i.document_no
                          where p.import_batch_id = b3 and i.control_role = 'insurer_payable') = 2,
    'H3 the remittance is allocated across both shares, so both keep a payable');
  perform pg_temp.assert((select sum(i.amount) from fin_open_items i
                           join ins_policies p on p.policy_no = i.document_no
                          where p.import_batch_id = b3 and i.control_role = 'insurer_payable') = 450,
    'H3 the two payables sum to the unremitted balance');
  raise notice 'PASS: H3 staged remittances reach the per-share allocation';

  -------------------------------------------------------------------
  -- H4. No history sheets: commit and post as before
  -------------------------------------------------------------------
  select id into b4 from public.ins_import_create_batch('H4 no history', current_date);
  perform public.ins_import_stage_rows(b4, 'policies', $j$[
    {"legacy_policy_no":"H4-P1","client_name":"Bridge Client","insurer":"BRGINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"100","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b4);
  r := public.ins_import_commit_policies(b4);
  perform pg_temp.assert((r ->> 'history_receipts_recorded')::int = 0
                         and (r ->> 'history_remittances_recorded')::int = 0,
    'H4 a batch without history sheets promotes nothing, and does not fail');
  perform public.ins_import_post_opening_position(b4);
  perform pg_temp.assert(pg_temp.line(b4, '1100', 'D') = 100
                         and pg_temp.line(b4, '2010', 'C') = 90,
    'H4 the opening is the full premium when no history was staged');
  raise notice 'PASS: H4 a batch with no history sheets still commits and posts';

  -------------------------------------------------------------------
  -- H5. Re-recording after promotion is a skip, not a duplicate
  -------------------------------------------------------------------
  -- a committed batch that is not posted yet: history is still open for
  -- adjustment, and the promoted row is recognised as already present
  r := pg_temp.wizard_batch('H5 duplicates', jsonb_build_object(
    'policies', $j$[
      {"legacy_policy_no":"H5-P1","client_name":"Bridge Client","insurer":"BRGINS1","product_line":"GEN",
       "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
       "gross_premium":"100","commission_rate_pct":"10"}]$j$::jsonb,
    'receipts', $j$[
      {"legacy_policy_no":"H5-P1","receipt_date":"2026-02-01","reference":"RD","amount":"40"}]$j$::jsonb));
  perform pg_temp.assert((r ->> 'validated')::boolean, 'H5 batch validates');
  b6 := (r ->> 'batch_id')::uuid;

  r := public.ins_import_record_history(b6, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('H5-P1'), 'receipt_date', date '2026-02-01',
                       'reference', 'RD', 'amount', 40)), '[]'::jsonb);
  perform pg_temp.assert((r ->> 'receipts_recorded')::int = 0
                         and (r ->> 'receipts_already_present')::int = 1,
    'H5 a receipt already promoted is counted as present');
  perform pg_temp.assert((select count(*) from ins_import_receipts where batch_id = b6) = 1,
    'H5 no duplicate row is inserted');
  -- and once the opening position is posted, history closes for good
  perform public.ins_import_post_opening_position(b6);
  perform pg_temp.expect_error(format($q$select public.ins_import_record_history(%L, %L::jsonb, '[]'::jsonb)$q$,
      b6, jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('H5-P1'),
        'receipt_date', date '2026-03-01', 'reference', 'LATE', 'amount', 10))),
    'INS_IMPORT_OPENING_POSTED', 'H5 history is frozen once the opening position is posted');
  raise notice 'PASS: H5 promotion and record_history agree on duplicates';

  -------------------------------------------------------------------
  -- H6. A staged receipt above the premium fails validation and blocks commit
  -------------------------------------------------------------------
  r := pg_temp.wizard_batch('H6 over-receipt', jsonb_build_object(
    'policies', $j$[
      {"legacy_policy_no":"H6-P1","client_name":"Bridge Client","insurer":"BRGINS1","product_line":"GEN",
       "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
       "gross_premium":"100","commission_rate_pct":"10"}]$j$::jsonb,
    'receipts', $j$[
      {"legacy_policy_no":"H6-P1","receipt_date":"2026-02-01","reference":"RR","amount":"150"}]$j$::jsonb));
  perform pg_temp.assert(not (r ->> 'validated')::boolean,
    'H6 a receipt above the gross premium stops validation');
  b5 := (r ->> 'batch_id')::uuid;
  perform pg_temp.assert((select count(*) from ins_import_rows
                           where batch_id = b5 and sheet = 'policies' and status = 'error'
                             and errors::text like '%RECEIPTS_EXCEED_PREMIUM%') = 1,
    'H6 the policy row carries RECEIPTS_EXCEED_PREMIUM');
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b5),
    'INS_IMPORT_NOT_VALIDATED', 'H6 a batch with an error row cannot be committed');
  perform pg_temp.assert((select count(*) from ins_import_receipts where batch_id = b5) = 0,
    'H6 nothing was promoted for the refused batch');
  raise notice 'PASS: H6 an over-receipt is caught in validation and blocks commit';

  -------------------------------------------------------------------
  -- H7. Members and other tenants are refused; helpers are internal
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mem);
  perform pg_temp.expect_error(
    format('select public.ins_import_promote_history(%L)', b4),
    'INS_ACCESS_DENIED', 'H7 a member cannot promote history');
  perform pg_temp.jwt(o.mgr_b);
  perform pg_temp.expect_error(
    format('select public.ins_import_promote_history(%L)', b4),
    'INS_IMPORT_BATCH_NOT_FOUND', 'H7 another tenant cannot promote this batch');
  perform pg_temp.jwt(o.mgr);
  raise notice 'PASS: H7 the promotion helpers are owner-only';
end $$;

-- Catalog: neither helper is exposed to clients.
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_import_history_add', 'ins_import_promote_history')
     and grantee in ('anon', 'authenticated', 'PUBLIC')),
  'the history helpers are not executable by clients');

-- And commit_policies, which is the supported entry point, still is.
select pg_temp.assert(
  (select count(*) = 1 from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'ins_import_commit_policies'
     and grantee = 'authenticated' and privilege_type = 'EXECUTE'),
  'authenticated can still execute commit_policies');

rollback;
