-- Insurance brokerage: in-force import, step 3 (opening position from history)
-- (20261110120000_ins_import_opening_from_history.sql).
--
-- Covers the nine scenarios the 10 Nov review asks for before a real
-- portfolio is migrated, plus the defects found in the same functions:
--
--   	S1  no receipts, no remittances          -> full receivable, full payable, commission deferred
--   	S2  client partially paid                -> receivable reduced by the receipts
--   	S3  insurer partially remitted           -> payable reduced, commission still deferred
--   	S4  insurer fully paid before cut-over   -> no payable, commission earned (retained earnings, not P&L)
--   	S5  co-insured (two insurers)            -> one payable per share, split by share, both deferred
--   	S6  co-insured, insurer fully paid       -> every share's commission earned, per share
--   	S7  foreign currency + a mixed batch     -> per-currency lines, per-currency clearing, no crash,
--   	                                            items priced from the booking entry
--   	S8  idempotency                          -> history-first ordering posts; a second call is a no-op;
--   	                                            no duplicate journals, items or commission entries
--   	S9  inconsistent history is refused      -> receipts > premium, remittances > net, history after
--   	                                            cut-over, history after posting, wrong tenant, member tier
--
-- Also asserted: the opening entry is exactly one journal per batch carrying
-- every currency; each currency balances on its own so no fx_rounding line is
-- produced; the clearing account holds receipts minus remittances; and
-- receivable + remittances reconcile to the billed premium.
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

create function pg_temp.scalar(p_sql text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text;
begin
  execute p_sql into v;
  return v;
end $$;

-- One journal line amount for a batch, by account code and side.
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

-- Open-item totals per batch and control role (policy_no is the document no).
create function pg_temp.items(p_batch uuid, p_role text) returns numeric
language sql stable as $$
  select coalesce(sum(i.amount), 0)
    from fin_open_items i
    join ins_policies p on p.policy_no = i.document_no
   where p.import_batch_id = p_batch and i.control_role = p_role;
$$;

create function pg_temp.items_n(p_batch uuid, p_role text) returns integer
language sql stable as $$
  select count(*)::int
    from fin_open_items i
    join ins_policies p on p.policy_no = i.document_no
   where p.import_batch_id = p_batch and i.control_role = p_role;
$$;

create function pg_temp.policy(p_no text) returns uuid
language sql stable as $$
  select id from ins_policies where policy_no = p_no and tenant_id = get_my_tenant_id();
$$;

-- Stage, validate and commit a batch as the signed-in user.
create function pg_temp.make_batch(p_label text, p_policies jsonb, p_shares jsonb default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_rep jsonb;
begin
  select id into v_id from public.ins_import_create_batch(p_label, current_date);
  perform public.ins_import_stage_rows(v_id, 'policies', p_policies);
  if p_shares is not null then
    perform public.ins_import_stage_rows(v_id, 'shares', p_shares);
  end if;
  v_rep := public.ins_import_validate_batch(v_id);
  if (v_rep ->> 'error_count')::int <> 0 then
    raise exception 'fixture: batch "%" did not validate: %', p_label, v_rep::text;
  end if;
  perform public.ins_import_commit_policies(v_id);
  return v_id;
end $$;

---------------------------------------------------------------------
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.o_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as mgr_b, gen_random_uuid() as adm;

insert into tenants (id, name)
select ta, 'Opening Brokerage A' from pg_temp.o_ids
union all select tb, 'Opening Brokerage B' from pg_temp.o_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'impo-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.o_ids union all select mem from pg_temp.o_ids
      union all select mgr_b from pg_temp.o_ids union all select adm from pg_temp.o_ids) u;

insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Opening Manager A', 'impo-' || i.mgr || '@test.local', false from pg_temp.o_ids i
union all select i.mem, i.ta, 'Opening Member A', 'impo-' || i.mem || '@test.local', false from pg_temp.o_ids i
union all select i.adm, i.ta, 'Opening Admin A', 'impo-' || i.adm || '@test.local', true from pg_temp.o_ids i
union all select i.mgr_b, i.tb, 'Opening Manager B', 'impo-' || i.mgr_b || '@test.local', false from pg_temp.o_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.o_ids union all select tb, 'insurance' from pg_temp.o_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.o_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.o_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.o_ids;

-- Chart of accounts and the five posting rules the opening position needs.
insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
select i.ta, v.code, v.name, v.type, v.control
from pg_temp.o_ids i,
     (values ('1100', 'Accounts Receivable Control', 'asset', true),
             ('2010', 'Insurer Payable (Premiums)', 'liability', true),
             ('2400', 'Unearned Commission', 'liability', true),
             ('3200', 'Retained Earnings', 'equity', false),
             ('3900', 'Opening Balance Clearing', 'equity', false)) v(code, name, type, control);

insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
select i.ta, v.role, a.id
from pg_temp.o_ids i
cross join (values ('ar_control', '1100'), ('insurer_payable', '2010'),
                   ('unearned_commission', '2400'), ('retained_earnings', '3200'),
                   ('opening_balance_clearing', '3900')) v(role, code)
join gl_accounts a on a.tenant_id = i.ta and a.account_code = v.code;

-- Approved FX rate for today (the cut-over date) and the staleness parameter.
select set_config('reg.via_rpc', 'on', true);
select set_config('fx.via_rpc', 'on', true);
create temp table pg_temp.o_fx as
select (select i.ta from pg_temp.o_ids i) as ta,
       (select i.adm from pg_temp.o_ids i) as approver;
do $$
declare r uuid; f uuid; i pg_temp.o_fx;
begin
  select * into i from pg_temp.o_fx;
  insert into regulatory_parameters
    (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (i.ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture')
  returning id into r;
  update regulatory_parameters set status = 'approved', approved_by = i.approver, approved_at = now()
   where id = r;

  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
  values (i.ta, 'USD', current_date, 3800, 'fixture') returning id into f;
  update fx_rates set status = 'approved', approved_by = i.approver, approved_at = now()
   where id = f;
end $$;
select set_config('reg.via_rpc', 'off', true);
select set_config('fx.via_rpc', 'off', true);

-- Master data: three insurers, two product lines, one client.
select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.o_master as
with i1 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'OPNINS1', 'Opening Insurer One', true from pg_temp.o_ids returning id),
     i2 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'OPNINS2', 'Opening Insurer Two', true from pg_temp.o_ids returning id),
     i3 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'OPNINS3', 'Opening Insurer Three', true from pg_temp.o_ids returning id),
     pl as (insert into ins_product_lines (tenant_id, code, name, class, is_active)
            select ta, 'GEN', 'General', 'general', true from pg_temp.o_ids returning id),
     bd as (insert into bd_clients (tenant_id, name)
            select ta, 'Opening Client' from pg_temp.o_ids returning id, tenant_id),
     cl as (insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
            select tenant_id, id, 'corporate', 'verified' from bd returning id)
select i1.id as insurer1, i2.id as insurer2, i3.id as insurer3,
       pl.id as product_line_id, cl.id as client_id
  from i1, i2, i3, pl, cl;
select set_config('ins.via_rpc', 'off', true);

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  o    pg_temp.o_ids;
  m    pg_temp.o_master;
  b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; b6 uuid; b7 uuid; b8 uuid;
  p    uuid;
  rep  jsonb;
  je   uuid;
  n    integer;
  to_b numeric;
begin
  select * into o from pg_temp.o_ids;
  select * into m from pg_temp.o_master;
  perform pg_temp.jwt(o.mgr);

  -------------------------------------------------------------------
  -- S1. Nothing collected, nothing remitted
  -------------------------------------------------------------------
  b1 := pg_temp.make_batch('S1 no history', $j$[
    {"legacy_policy_no":"S1-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb);

  rep := public.ins_import_post_opening_position(b1);
  perform pg_temp.assert((rep ->> 'already_posted')::boolean = false, 'S1 posts');
  perform pg_temp.assert(pg_temp.line(b1, '1100', 'D') = 1000000, 'S1 receivable is the full billed premium');
  perform pg_temp.assert(pg_temp.line(b1, '2010', 'C') = 900000, 'S1 payable is the full net premium');
  perform pg_temp.assert(pg_temp.line(b1, '2400', 'C') = 100000, 'S1 commission is deferred');
  perform pg_temp.assert(pg_temp.line(b1, '3200', 'C') = 0, 'S1 nothing is earned at cut-over');
  perform pg_temp.assert(pg_temp.count_code(b1, '3900') = 0, 'S1 no clearing line when no money has moved');
  perform pg_temp.assert((rep ->> 'receivable_total')::numeric = 1000000
                         and (rep ->> 'payable_total')::numeric = 900000
                         and (rep ->> 'deferred_commission_total')::numeric = 100000
                         and (rep ->> 'earned_commission_total')::numeric = 0, 'S1 summary: ' || rep::text);
  perform pg_temp.assert(pg_temp.items(b1, 'ar_control') = 1000000 and pg_temp.items_n(b1, 'ar_control') = 1,
    'S1 one receivable open item for the billed premium');
  perform pg_temp.assert(pg_temp.items(b1, 'insurer_payable') = 900000 and pg_temp.items_n(b1, 'insurer_payable') = 1,
    'S1 one payable open item for the net premium');
  perform pg_temp.assert((select count(*) from ins_commission_entries e
                           join ins_policies p on p.id = e.policy_id
                          where p.import_batch_id = b1 and e.status = 'deferred' and e.amount = 100000) = 1,
    'S1 one deferred commission entry');
  raise notice 'PASS: S1 nothing collected - full receivable, full payable, commission deferred';

  -------------------------------------------------------------------
  -- S2. Client has paid part of the premium
  -------------------------------------------------------------------
  b2 := pg_temp.make_batch('S2 partial receipt', $j$[
    {"legacy_policy_no":"S2-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_record_history(b2, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S2-P1'), 'receipt_date', current_date - 30,
                       'reference', 'RCPT-1', 'amount', 400000)), '[]'::jsonb);
  rep := public.ins_import_post_opening_position(b2);
  perform pg_temp.assert(pg_temp.line(b2, '1100', 'D') = 600000, 'S2 receivable is billed minus receipts');
  perform pg_temp.assert(pg_temp.line(b2, '2010', 'C') = 900000, 'S2 payable is untouched by client cash');
  perform pg_temp.assert(pg_temp.line(b2, '2400', 'C') = 100000, 'S2 commission is still deferred');
  perform pg_temp.assert(pg_temp.line(b2, '3900', 'D') = 400000, 'S2 clearing holds the money received');
  perform pg_temp.assert(pg_temp.items(b2, 'ar_control') = 600000, 'S2 the open item carries the outstanding balance');
  -- the identity the review asks for: receivable + receipts = billed premium
  perform pg_temp.assert(pg_temp.line(b2, '1100', 'D') + 400000 = 1000000,
    'S2 receivable plus receipts reconciles to the billed premium');
  raise notice 'PASS: S2 partially paid by the client - receivable reduced, payable unchanged';

  -------------------------------------------------------------------
  -- S3. Client paid, broker remitted part to the insurer
  -------------------------------------------------------------------
  b3 := pg_temp.make_batch('S3 partial remittance', $j$[
    {"legacy_policy_no":"S3-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_record_history(b3, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S3-P1'), 'receipt_date', current_date - 40,
                       'reference', 'RCPT-2', 'amount', 700000)),
    jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S3-P1'), 'remit_date', current_date - 20,
                       'reference', 'REMIT-1', 'amount', 300000)));
  rep := public.ins_import_post_opening_position(b3);
  perform pg_temp.assert(pg_temp.line(b3, '1100', 'D') = 300000, 'S3 receivable is billed minus receipts');
  perform pg_temp.assert(pg_temp.line(b3, '2010', 'C') = 600000, 'S3 payable is net premium minus remittances');
  perform pg_temp.assert(pg_temp.line(b3, '2400', 'C') = 100000 and pg_temp.line(b3, '3200', 'C') = 0,
    'S3 a partly remitted insurer has earned nothing yet, so the whole commission stays deferred');
  perform pg_temp.assert(pg_temp.line(b3, '3900', 'D') = 400000, 'S3 clearing is receipts minus remittances');
  perform pg_temp.assert(pg_temp.items(b3, 'insurer_payable') = 600000, 'S3 the payable item is the unremitted balance');
  raise notice 'PASS: S3 partially remitted to the insurer - payable reduced, commission still deferred';

  -------------------------------------------------------------------
  -- S4. Insurer fully paid before cut-over (Option A: commission earned)
  -------------------------------------------------------------------
  b4 := pg_temp.make_batch('S4 insurer settled', $j$[
    {"legacy_policy_no":"S4-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2025-01-01","expiry_date":"2025-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_record_history(b4, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S4-P1'), 'receipt_date', current_date - 90,
                       'reference', 'RCPT-3', 'amount', 1000000)),
    jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S4-P1'), 'remit_date', current_date - 60,
                       'reference', 'REMIT-2', 'amount', 900000)));
  rep := public.ins_import_post_opening_position(b4);
  perform pg_temp.assert(pg_temp.line(b4, '1100', 'D') = 0, 'S4 nothing is receivable');
  perform pg_temp.assert(pg_temp.line(b4, '2010', 'C') = 0, 'S4 nothing is payable to the insurer');
  perform pg_temp.assert(pg_temp.line(b4, '2400', 'C') = 0, 'S4 no commission is deferred');
  perform pg_temp.assert(pg_temp.line(b4, '3200', 'C') = 100000,
    'S4 the whole commission is earned and credited to retained earnings, not to current-period income');
  perform pg_temp.assert((select count(*) from journal_entries j join journal_entry_lines l on l.journal_entry_id = j.id
                           join gl_accounts a on a.id = l.gl_account_id
                          where j.source_id = b4 and a.account_code = '4000') = 0,
    'S4 commission income is not touched at cut-over');
  perform pg_temp.assert(pg_temp.line(b4, '3900', 'D') = 100000, 'S4 clearing holds the retained commission');
  perform pg_temp.assert(pg_temp.items_n(b4, 'ar_control') = 0 and pg_temp.items_n(b4, 'insurer_payable') = 0,
    'S4 a fully settled policy creates no open items');
  perform pg_temp.assert((select count(*) from ins_commission_entries e
                           join ins_policies p on p.id = e.policy_id where p.import_batch_id = b4) = 0,
    'S4 a fully settled policy creates no deferred commission entry');
  raise notice 'PASS: S4 insurer paid before cut-over - commission earned, no receivable or payable';

  -------------------------------------------------------------------
  -- S5. Co-insured policy: one payable per insurer share
  -------------------------------------------------------------------
  b5 := pg_temp.make_batch('S5 co-insured', $j$[
    {"legacy_policy_no":"S5-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb, $j$[
    {"legacy_policy_no":"S5-P1","insurer":"OPNINS1","share_pct":"70"},
    {"legacy_policy_no":"S5-P1","insurer":"OPNINS2","share_pct":"30"}]$j$::jsonb);
  rep := public.ins_import_post_opening_position(b5);
  perform pg_temp.assert(pg_temp.line(b5, '1100', 'D') = 1000, 'S5 receivable is the billed premium');
  perform pg_temp.assert(pg_temp.line(b5, '2010', 'C') = 900, 'S5 payables total the net premium');
  perform pg_temp.assert(pg_temp.items_n(b5, 'insurer_payable') = 2,
    'S5 one payable open item per participating insurer, not one for the lead');
  perform pg_temp.assert(pg_temp.items(b5, 'insurer_payable') = 900, 'S5 the two payables sum to the net premium');
  perform pg_temp.assert((select count(*) from fin_open_items i
                           join ins_policies p on p.policy_no = i.document_no
                           join ins_policy_insurer_shares s on s.id = i.source_id
                          where p.import_batch_id = b5 and i.control_role = 'insurer_payable') = 2,
    'S5 each payable item points at its own share row');
  perform pg_temp.assert((select bool_and(round(i.amount, 2) = round(s.payable_amount, 2))
                            from fin_open_items i
                            join ins_policies p on p.policy_no = i.document_no
                            join ins_policy_insurer_shares s on s.id = i.source_id
                           where p.import_batch_id = b5 and i.control_role = 'insurer_payable'),
    'S5 each payable equals that share''s own payable (no lead-insurer concentration)');
  perform pg_temp.assert((select count(distinct s.insurer_id) from fin_open_items i
                           join ins_policies p on p.policy_no = i.document_no
                           join ins_policy_insurer_shares s on s.id = i.source_id
                          where p.import_batch_id = b5 and i.control_role = 'insurer_payable') = 2,
    'S5 the payables sit with two different insurers');
  perform pg_temp.assert(pg_temp.line(b5, '2400', 'C') = 100, 'S5 commission is deferred once, in total');
  perform pg_temp.assert((select count(*) from ins_commission_entries e
                           join ins_policies p on p.id = e.policy_id
                          where p.import_batch_id = b5) = 2,
    'S5 one deferred commission entry per share, each tied to its share');
  raise notice 'PASS: S5 co-insured - payables split by insurer share';

  -------------------------------------------------------------------
  -- S6. Co-insured policy whose insurers are both fully paid
  -------------------------------------------------------------------
  b6 := pg_temp.make_batch('S6 co-insured settled', $j$[
    {"legacy_policy_no":"S6-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2025-01-01","expiry_date":"2025-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb, $j$[
    {"legacy_policy_no":"S6-P1","insurer":"OPNINS1","share_pct":"70"},
    {"legacy_policy_no":"S6-P1","insurer":"OPNINS3","share_pct":"30"}]$j$::jsonb);
  perform public.ins_import_record_history(b6, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S6-P1'), 'receipt_date', current_date - 90,
                       'reference', 'RCPT-4', 'amount', 1000)),
    jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S6-P1'), 'remit_date', current_date - 60,
                       'reference', 'REMIT-3', 'amount', 900)));
  rep := public.ins_import_post_opening_position(b6);
  perform pg_temp.assert(pg_temp.line(b6, '2010', 'C') = 0, 'S6 no payable remains');
  perform pg_temp.assert(pg_temp.line(b6, '3200', 'C') = 100, 'S6 the whole commission is earned');
  perform pg_temp.assert(pg_temp.line(b6, '2400', 'C') = 0, 'S6 nothing is deferred');
  perform pg_temp.assert((select count(*) from ins_commission_entries e
                           join ins_policies p on p.id = e.policy_id where p.import_batch_id = b6) = 0,
    'S6 no deferred entries for a settled co-insured policy');
  raise notice 'PASS: S6 co-insured and fully paid - every share earns its commission';

  -------------------------------------------------------------------
  -- S7. Foreign currency inside a mixed batch
  -------------------------------------------------------------------
  b7 := pg_temp.make_batch('S7 mixed currency', $j$[
    {"legacy_policy_no":"S7-UGX","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"2000000","commission_rate_pct":"10"},
    {"legacy_policy_no":"S7-USD","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"USD",
     "gross_premium":"10000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_record_history(b7, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S7-USD'), 'receipt_date', current_date - 10,
                       'reference', 'RCPT-USD', 'amount', 4000)), '[]'::jsonb);
  rep := public.ins_import_post_opening_position(b7);   -- the old function raised here
  select id into je from journal_entries
   where source_type = 'ins_import_opening' and source_id = b7;
  perform pg_temp.assert(je is not null, 'S7 a mixed-currency batch posts one journal');
  perform pg_temp.assert((select count(*) from journal_entries
                           where source_type = 'ins_import_opening' and source_id = b7) = 1,
    'S7 exactly one opening journal per batch (the source unique index)');
  perform pg_temp.assert(pg_temp.line_ccy(b7, '1100', 'D', 'UGX') = 2000000
                         and pg_temp.line_ccy(b7, '1100', 'D', 'USD') = 6000,
    'S7 each currency keeps its own receivable (2,000,000 UGX billed, 10,000 USD less 4,000 received)');
  perform pg_temp.assert(pg_temp.line_ccy(b7, '3900', 'D', 'USD') = 4000
                         and pg_temp.line_ccy(b7, '3900', 'D', 'UGX') = 0,
    'S7 clearing is per currency: only the USD policy has cash behind it');
  -- per currency, debits and credits balance on their own and no rounding line appears
  perform pg_temp.assert(not exists (
      select 1 from (
        select l.currency,
               sum(l.debit) - sum(l.credit) as d,
               sum(l.base_debit) - sum(l.base_credit) as b
          from journal_entry_lines l where l.journal_entry_id = je group by l.currency
      ) x where abs(x.d) > 0.005 or abs(x.b) > 0.005),
    'S7 every currency balances in itself and in base, so no fx_rounding line is needed');
  perform pg_temp.assert((select count(*) from journal_entry_lines
                           where journal_entry_id = je and is_rounding) = 0,
    'S7 no rounding line was produced');
  perform pg_temp.assert((select sum(l.credit) from journal_entry_lines l
                           where l.journal_entry_id = je and l.currency = 'USD') = 10000,
    'S7 the USD currency balances on its own (9000 payable + 1000 commission)');
  perform pg_temp.assert((select sum(l.debit) from journal_entry_lines l
                           where l.journal_entry_id = je and l.currency = 'USD') = 10000,
    'S7 the USD receivable (6000) plus its clearing (4000) fund those credits');
  -- foreign items are priced from the booking entry they now carry
  perform pg_temp.assert((select bool_and(i.fx_rate = 3800 and i.journal_entry_id = je and i.currency = 'USD')
                            from fin_open_items i join ins_policies p on p.policy_no = i.document_no
                           where p.import_batch_id = b7 and i.currency = 'USD'),
    'S7 USD open items carry the journal''s rate and name the entry that booked them');
  perform pg_temp.assert((select sum(i.base_amount) from fin_open_items i join ins_policies p on p.policy_no = i.document_no
                           where p.import_batch_id = b7 and i.currency = 'USD')
                         = round((9000 + 6000) * 3800, 2),
    'S7 USD open items convert at the approved rate');
  raise notice 'PASS: S7 foreign currency in a mixed batch - per-currency lines, no crash, priced items';

  -------------------------------------------------------------------
  -- S8. Idempotency and ordering (history first, then post, then post again)
  -------------------------------------------------------------------
  b8 := pg_temp.make_batch('S8 idempotency', $j$[
    {"legacy_policy_no":"S8-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"500000","commission_rate_pct":"10"}]$j$::jsonb);

  -- history BEFORE the opening position: the old guard treated this as already posted
  rep := public.ins_import_record_history(b8, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S8-P1'), 'receipt_date', current_date - 5,
                       'reference', 'RCPT-5', 'amount', 200000)), '[]'::jsonb);
  perform pg_temp.assert((rep ->> 'receipts_recorded')::int = 1, 'S8 history records');
  -- the same row again, before posting: skipped, not duplicated
  rep := public.ins_import_record_history(b8, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('S8-P1'), 'receipt_date', current_date - 5,
                       'reference', 'RCPT-5', 'amount', 200000)), '[]'::jsonb);
  perform pg_temp.assert((rep ->> 'receipts_recorded')::int = 0
                         and (rep ->> 'receipts_already_present')::int = 1,
    'S8 re-recording the same history row is a counted skip');
  perform pg_temp.assert((select count(*) from ins_import_receipts r
                           join ins_policies p on p.id = r.policy_id
                          where p.import_batch_id = b8) = 1,
    'S8 one history row, not two');
  rep := public.ins_import_post_opening_position(b8);
  perform pg_temp.assert((rep ->> 'already_posted')::boolean = false,
    'S8 history recorded before posting does not suppress the opening position');
  perform pg_temp.assert(pg_temp.line(b8, '1100', 'D') = 300000,
    'S8 the receivable still reflects the recorded receipt');
  je := (rep ->> 'journal_entry_id')::uuid;

  -- re-running is a no-op that names the original journal
  rep := public.ins_import_post_opening_position(b8);
  perform pg_temp.assert((rep ->> 'already_posted')::boolean = true, 'S8 a second post is a no-op');
  perform pg_temp.assert((rep ->> 'journal_entry_id')::uuid = je, 'S8 the no-op names the original journal');
  perform pg_temp.assert((select count(*) from journal_entries
                           where source_type = 'ins_import_opening' and source_id = b8) = 1,
    'S8 still exactly one opening journal');
  perform pg_temp.assert(pg_temp.items(b8, 'ar_control') = 300000
                         and pg_temp.items_n(b8, 'ar_control') = 1,
    'S8 no duplicate open items');
  perform pg_temp.assert((select count(*) from ins_commission_entries e
                           join ins_policies p on p.id = e.policy_id where p.import_batch_id = b8) = 1,
    'S8 no duplicate commission entries');
  -- and history can no longer change once the opening position is posted
  perform pg_temp.expect_error(format($q$select public.ins_import_record_history(%L, %L::jsonb, '[]'::jsonb)$q$,
      b8, jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('S8-P1'),
        'receipt_date', current_date - 5, 'reference', 'RCPT-5', 'amount', 200000))),
    'INS_IMPORT_OPENING_POSTED', 'history after the opening position is refused');
  raise notice 'PASS: S8 idempotent - history-first posts, a second post is a no-op, nothing duplicates';

  -------------------------------------------------------------------
  -- S9. Inconsistent history and access
  -------------------------------------------------------------------
  -- a fresh, unposted batch: the caps are checked before the guard can mask them
  b3 := pg_temp.make_batch('S9 caps', $j$[
    {"legacy_policy_no":"S9-C1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"}]$j$::jsonb);
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, %L::jsonb, '[]'::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('S9-C1'),
        'receipt_date', current_date - 1, 'reference', 'TOO-MUCH', 'amount', 1500000))),
    'INS_IMPORT_RECEIPTS_EXCEED_PREMIUM', 'receipts above the gross premium');
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, '[]'::jsonb, %L::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('S9-C1'),
        'remit_date', current_date - 1, 'reference', 'TOO-MUCH', 'amount', 950000))),
    'INS_IMPORT_REMITTANCES_EXCEED_PAYABLE', 'remittances above the net premium');

  select id into p from ins_policies where policy_no = 'S7-UGX';
  perform pg_temp.assert(p is not null, 'S9 fixture policy exists');
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, %L::jsonb, '[]'::jsonb)$q$, b7,
      jsonb_build_array(jsonb_build_object('policy_id', p,
        'receipt_date', current_date, 'reference', 'AFTER', 'amount', 1))),
    'INS_IMPORT_OPENING_POSTED', 'history after posting is refused');

  -- a fresh batch for the date check (the batch above is already posted)
  b3 := pg_temp.make_batch('S9 after cutover', $j$[
    {"legacy_policy_no":"S9-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"100","commission_rate_pct":"10"}]$j$::jsonb);
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, %L::jsonb, '[]'::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('S9-P1'),
        'receipt_date', current_date + 1, 'reference', 'FUTURE', 'amount', 10))),
    'INS_IMPORT_HISTORY_AFTER_CUTOFF', 'a receipt dated after the cut-over');

  perform pg_temp.jwt(o.mem);
  perform pg_temp.expect_error(format('select public.ins_import_post_opening_position(%L)', b3),
    'INS_ACCESS_DENIED', 'member tier cannot post the opening position');
  perform pg_temp.jwt(o.mgr_b);
  perform pg_temp.expect_error(format('select public.ins_import_post_opening_position(%L)', b3),
    'INS_IMPORT_BATCH_NOT_FOUND', 'another tenant cannot post this batch');
  perform pg_temp.jwt(o.mgr);
  raise notice 'PASS: S9 inconsistent history and access are refused';
end $$;

-- Catalog-level: the opening RPCs are not reachable by anon or PUBLIC.
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_import_post_opening_position', 'ins_import_record_history')
     and grantee in ('anon', 'PUBLIC')),
  'anon / PUBLIC have no EXECUTE on the opening-position RPCs');
select pg_temp.assert(
  (select count(*) = 1 from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'ins_import_post_opening_position'
     and grantee = 'authenticated' and privilege_type = 'EXECUTE'),
  'authenticated can execute the opening-position RPC');

-- The new posting role is on both lists and in the insurance template.
select pg_temp.assert('retained_earnings' = any (platform_gl_posting_roles()),
  'retained_earnings is a posting role');
select pg_temp.assert(
  (select count(*) = 1 from industry_template_items
   where template_key = 'insurance' and kind = 'posting_rule' and name = 'retained_earnings'),
  'the insurance template maps retained_earnings');
select pg_temp.assert(
  (select count(*) = 1 from industry_template_items
   where template_key = 'insurance' and kind = 'gl_account' and name = '3200'),
  'the insurance template carries the retained earnings account');

rollback;
