-- Insurance brokerage: in-force import, step 1 (staging + validation)
-- (20261107140000_ins_import_staging.sql).
--
-- Covers: manager-only access, batch creation rules, staging and replace,
-- validation error codes per sheet, policy-level aggregate checks (receipts,
-- remittances, shares), resolved values and per-currency report totals,
-- batch status transitions, lock once committed, accounting-policy version
-- pinned to 1, mapping profile upsert, RPC-only write discipline, anon
-- EXECUTE denial and cross-tenant isolation.
--
-- Run against a fresh local stack only (`supabase start` / `supabase db reset`).
-- One transaction, ROLLBACK at the end; any RAISE EXCEPTION fails the run.

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

create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    -- Probe as the API role: the owner role bypasses RLS and would never be denied.
    set local role authenticated;
    execute p_sql;
  exception when others then
    if sqlstate = p_state then return; end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  reset role;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
end $$;

create function pg_temp.scalar_as_user(p_sql text) returns text
language plpgsql as $$
declare v text;
begin
  set local role authenticated;
  execute p_sql into v;
  reset role;
  return v;
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

-- Sorted, comma-joined error codes of one staged row (null when it has none).
create function pg_temp.codes(p_batch uuid, p_sheet text, p_line int) returns text
language sql security definer set search_path = public, pg_temp as $$
  select string_agg(e ->> 'code', ',' order by e ->> 'code')
    from public.ins_import_rows r, jsonb_array_elements(r.errors) e
   where r.batch_id = p_batch and r.sheet = p_sheet and r.line = p_line;
$$;

---------------------------------------------------------------------
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.q_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as out, gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'Imp Brokerage A' from pg_temp.q_ids
union all
select tb, 'Imp Brokerage B' from pg_temp.q_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'imp-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.q_ids union all select mem from pg_temp.q_ids union all select out from pg_temp.q_ids union all select mgr_b from pg_temp.q_ids) u;

insert into app_users (id, tenant_id, name, email)
select i.mgr, i.ta, 'Imp Manager A', 'imp-' || i.mgr || '@test.local' from pg_temp.q_ids i
union all select i.mem, i.ta, 'Imp Member A', 'imp-' || i.mem || '@test.local' from pg_temp.q_ids i
union all select i.out, i.ta, 'Imp Outsider A', 'imp-' || i.out || '@test.local' from pg_temp.q_ids i
union all select i.mgr_b, i.tb, 'Imp Manager B', 'imp-' || i.mgr_b || '@test.local' from pg_temp.q_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.q_ids union all select tb, 'insurance' from pg_temp.q_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.q_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.q_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.q_ids;

-- master data for tenant A
select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.q_master as
with ins as (
  insert into ins_insurers (tenant_id, code, name, is_active)
  select ta, 'IMPINS', 'Imp Insurer', true from pg_temp.q_ids returning id
), line as (
  insert into ins_product_lines (tenant_id, code, name, class, is_active)
  select ta, 'GEN', 'General', 'general', true from pg_temp.q_ids returning id
), bdc as (
  insert into bd_clients (tenant_id, name)
  select ta, 'Imp Client' from pg_temp.q_ids returning id, tenant_id
), cli as (
  insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
  select tenant_id, id, 'corporate', 'verified' from bdc returning id
)
select i.id as insurer_id, l.id as product_line_id, c.id as client_id from ins i, line l, cli c;

-- an existing policy number, to prove POLICY_EXISTS
insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id,
                          inception_date, expiry_date)
select ta, 'EXIST-1', m.client_id, m.insurer_id, m.product_line_id, date '2026-01-01', date '2026-12-31'
from pg_temp.q_ids, pg_temp.q_master m;
select set_config('ins.via_rpc', 'off', true);

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  i   pg_temp.q_ids;
  b   uuid;
  n   integer;
  rep jsonb;
  today text := to_char(current_date, 'YYYY-MM-DD');
begin
  select * into i from pg_temp.q_ids;

  -- access: only insurance managers
  perform pg_temp.jwt(i.out);
  perform pg_temp.expect_error($q$select public.ins_import_create_batch('x', current_date)$q$,
    'INS_ACCESS_DENIED', 'outsider create batch');
  perform pg_temp.jwt(i.mem);
  perform pg_temp.expect_error($q$select public.ins_import_create_batch('x', current_date)$q$,
    'INS_ACCESS_DENIED', 'non-manager member create batch');
  perform pg_temp.expect_error($q$select public.ins_import_save_profile('p', '{}'::jsonb)$q$,
    'INS_ACCESS_DENIED', 'non-manager save profile');

  -- batch creation rules
  perform pg_temp.jwt(i.mgr);
  perform pg_temp.expect_error($q$select public.ins_import_create_batch('  ', current_date)$q$,
    'INS_IMPORT_LABEL_REQUIRED', 'blank label');
  perform pg_temp.expect_error($q$select public.ins_import_create_batch('x', current_date + 1)$q$,
    'INS_IMPORT_CUTOVER_INVALID', 'future cut-over');
  select id into b from public.ins_import_create_batch('Legacy load', current_date - 7);
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_import_batches where id = %L', b)) = 'staged',
    'new batch is staged');
  perform pg_temp.assert(pg_temp.scalar(format('select accounting_policy_version::text from public.ins_import_batches where id = %L', b)) = '1',
    'batch carries accounting-policy version 1');
  perform pg_temp.expect_error(format('update public.ins_import_batches set accounting_policy_version = 2 where id = %L', b),
    'ins_import_batches_version_check', 'version cannot be anything but 1');

  -- staging input checks
  perform pg_temp.expect_error(format($q$select public.ins_import_stage_rows(%L, 'nonsense', '[]'::jsonb)$q$, b),
    'INS_IMPORT_SHEET_INVALID', 'bad sheet');
  perform pg_temp.expect_error(format($q$select public.ins_import_stage_rows(%L, 'policies', '{"a":1}'::jsonb)$q$, b),
    'INS_IMPORT_ROWS_INVALID', 'rows must be an array');
  perform pg_temp.expect_error(format($q$select public.ins_import_stage_rows(%L, 'policies', '[1,2]'::jsonb)$q$, b),
    'INS_IMPORT_ROWS_INVALID', 'rows must be objects');

  -- round 1: a deliberately dirty batch
  n := public.ins_import_stage_rows(b, 'policies', $j$[
    {"legacy_policy_no":"OK-1","client_name":"imp client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"1,000,000","commission_rate_pct":"10"},
    {"legacy_policy_no":"DUP-1","client_name":"Imp Client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"500000","commission_rate_pct":"10"},
    {"legacy_policy_no":"DUP-1","client_name":"Imp Client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"500000","commission_rate_pct":"10"},
    {"legacy_policy_no":"NOCLI-1","client_name":"Nobody Ltd","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"500000","commission_rate_pct":"10"},
    {"legacy_policy_no":"DATES-1","client_name":"Imp Client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-06-01","expiry_date":"2026-01-01","currency":"UGX","gross_premium":"500000","commission_rate_pct":"10"},
    {"legacy_policy_no":"MISM-1","client_name":"Imp Client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"1000000","commission_amount":"50000","commission_rate_pct":"10"},
    {"legacy_policy_no":"USD-1","client_name":"Imp Client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"USD","gross_premium":"1000","commission_rate_pct":"10"},
    {"legacy_policy_no":"EXIST-1","client_name":"Imp Client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"500000","commission_rate_pct":"10"},
    {"legacy_policy_no":"OVER-1","client_name":"Imp Client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"100000","commission_rate_pct":"10"}
  ]$j$::jsonb);
  perform pg_temp.assert(n = 9, 'nine policy rows staged');

  n := public.ins_import_stage_rows(b, 'receipts', format($j$[
    {"legacy_policy_no":"OK-1","receipt_date":"2026-03-01","reference":"R1","amount":"600000"},
    {"legacy_policy_no":"GHOST-1","receipt_date":"2026-03-01","reference":"R2","amount":"1000"},
    {"legacy_policy_no":"OK-1","receipt_date":"%s","reference":"R3","amount":"1000"},
    {"legacy_policy_no":"OVER-1","receipt_date":"2026-03-01","reference":"R4","amount":"80000"},
    {"legacy_policy_no":"OVER-1","receipt_date":"2026-03-02","reference":"R5","amount":"30000"}
  ]$j$, today)::jsonb);
  perform pg_temp.assert(n = 5, 'five receipt rows staged');

  rep := public.ins_import_validate_batch(b);

  perform pg_temp.assert(pg_temp.codes(b, 'policies', 1) is null, 'OK-1 is clean');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 2) = 'DUPLICATE_IN_FILE', 'duplicate (first)');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 3) = 'DUPLICATE_IN_FILE', 'duplicate (second)');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 4) = 'CLIENT_NOT_FOUND', 'unknown client');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 5) = 'DATE_ORDER', 'expiry before inception');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 6) = 'COMMISSION_MISMATCH', 'commission amount vs rate');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 7) = 'FX_RATE_MISSING', 'foreign currency without approved rate');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 8) = 'POLICY_EXISTS', 'existing policy number');
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 9) = 'RECEIPTS_EXCEED_PREMIUM', 'receipts exceed premium');
  perform pg_temp.assert(pg_temp.codes(b, 'receipts', 1) is null, 'receipt 1 clean');
  perform pg_temp.assert(pg_temp.codes(b, 'receipts', 2) = 'POLICY_NOT_IN_BATCH', 'receipt for unknown policy');
  perform pg_temp.assert(pg_temp.codes(b, 'receipts', 3) = 'AFTER_CUTOVER', 'receipt after cut-over');

  perform pg_temp.assert((rep ->> 'error_count')::int = 10, 'ten rows in error');
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_import_batches where id = %L', b)) = 'staged',
    'a dirty batch stays staged');
  perform pg_temp.assert(pg_temp.scalar(format($q$select (resolved ->> 'net_premium')::numeric::text from public.ins_import_rows where batch_id = %L and sheet = 'policies' and line = 1$q$, b)) = '900000.00',
    'net premium resolved');
  perform pg_temp.assert((rep -> 'totals_by_currency' -> 0 ->> 'policies')::int = 1
                     and (rep -> 'totals_by_currency' -> 0 ->> 'gross_premium')::numeric = 1000000
                     and (rep -> 'totals_by_currency' -> 0 ->> 'receipts')::numeric = 600000,
    'report totals count only valid policies and their valid receipts');

  -- round 2: one clean policy; remittances over the net premium; shares not 100; bad control total
  n := public.ins_import_stage_rows(b, 'policies', $j$[
    {"legacy_policy_no":"OK-1","client_name":"imp client","insurer":"IMPINS","product_line":"GEN","inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX","gross_premium":"1000000","commission_rate_pct":"10"}
  ]$j$::jsonb, true);
  n := public.ins_import_stage_rows(b, 'receipts', $j$[
    {"legacy_policy_no":"OK-1","receipt_date":"2026-03-01","reference":"R1","amount":"600000"}
  ]$j$::jsonb, true);
  n := public.ins_import_stage_rows(b, 'remittances', $j$[
    {"legacy_policy_no":"OK-1","remit_date":"2026-04-01","reference":"M1","amount":"450000"},
    {"legacy_policy_no":"OK-1","remit_date":"2026-04-02","reference":"M2","amount":"500000"}
  ]$j$::jsonb);
  n := public.ins_import_stage_rows(b, 'shares', $j$[
    {"legacy_policy_no":"OK-1","insurer":"IMPINS","share_pct":"60"},
    {"legacy_policy_no":"OK-1","insurer":"imp insurer","share_pct":"30"}
  ]$j$::jsonb);
  n := public.ins_import_stage_rows(b, 'control_totals', $j$[
    {"currency":"ugx","policy_count":"1","gross_premium":"abc"}
  ]$j$::jsonb);
  perform pg_temp.assert(pg_temp.scalar(format($q$select count(*)::text from public.ins_import_rows where batch_id = %L and sheet = 'policies'$q$, b)) = '1',
    'replace cleared the old policy rows');
  rep := public.ins_import_validate_batch(b);
  perform pg_temp.assert(pg_temp.codes(b, 'policies', 1) = 'REMITTANCES_EXCEED_NET,SHARES_NOT_100',
    'remittance and share aggregate checks');
  perform pg_temp.assert(pg_temp.codes(b, 'control_totals', 1) = 'BAD_AMOUNT', 'control total must be numeric');
  perform pg_temp.assert((rep ->> 'error_count')::int = 2, 'two rows in error in round 2');

  -- round 3: clean
  n := public.ins_import_stage_rows(b, 'remittances', $j$[
    {"legacy_policy_no":"OK-1","remit_date":"2026-04-01","reference":"M1","amount":"450000"}
  ]$j$::jsonb, true);
  n := public.ins_import_stage_rows(b, 'shares', $j$[
    {"legacy_policy_no":"OK-1","insurer":"IMPINS","share_pct":"60"},
    {"legacy_policy_no":"OK-1","insurer":"IMPINS","share_pct":"40"}
  ]$j$::jsonb, true);
  n := public.ins_import_stage_rows(b, 'control_totals', $j$[
    {"currency":"UGX","policy_count":"1","gross_premium":"1,000,000"}
  ]$j$::jsonb, true);
  rep := public.ins_import_validate_batch(b);
  perform pg_temp.assert((rep ->> 'error_count')::int = 0, 'clean batch has no errors');
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_import_batches where id = %L', b)) = 'validated',
    'a clean batch is validated');
  perform pg_temp.assert((rep -> 'totals_by_currency' -> 0 ->> 'remittances')::numeric = 450000
                     and (rep -> 'totals_by_currency' -> 0 ->> 'net_premium')::numeric = 900000
                     and (rep ->> 'accounting_policy_version')::int = 1,
    'clean report totals, version 1');

  -- any further staging sends the batch back for validation
  n := public.ins_import_stage_rows(b, 'receipts', $j$[
    {"legacy_policy_no":"OK-1","receipt_date":"2026-03-05","reference":"R9","amount":"1000"}
  ]$j$::jsonb);
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_import_batches where id = %L', b)) = 'staged',
    'staging after validation resets the batch to staged');

  -- mapping profile: upsert by name
  perform public.ins_import_save_profile('Legacy X', '{"legacy_policy_no":"Policy No"}'::jsonb);
  perform public.ins_import_save_profile('Legacy X', '{"legacy_policy_no":"Pol. Number"}'::jsonb);
  perform pg_temp.assert(pg_temp.scalar($q$select count(*)::text from public.ins_import_profiles where name = 'Legacy X'$q$) = '1',
    'profile upserted by name');
  perform pg_temp.assert(pg_temp.scalar($q$select mapping ->> 'legacy_policy_no' from public.ins_import_profiles where name = 'Legacy X'$q$) = 'Pol. Number',
    'profile mapping replaced');
  perform pg_temp.expect_error($q$select public.ins_import_save_profile('Bad', '[]'::jsonb)$q$,
    'INS_IMPORT_PROFILE_INVALID', 'profile mapping must be an object');

  -- RPC-only write discipline: direct DML as an API user is refused
  perform pg_temp.expect_state(format($q$insert into public.ins_import_batches (tenant_id, label, cut_over_date) values (%L, 'direct', current_date)$q$, i.ta),
    '42501', 'direct insert into batches');
  perform pg_temp.expect_state(format($q$insert into public.ins_import_rows (tenant_id, batch_id, sheet, line, raw) values (%L, %L, 'policies', 99, '{}'::jsonb)$q$, i.ta, b),
    '42501', 'direct insert into rows');

  -- cross-tenant: manager B cannot see or touch tenant A's batch
  perform pg_temp.jwt(i.mgr_b);
  perform pg_temp.expect_error(format($q$select public.ins_import_stage_rows(%L, 'policies', '[]'::jsonb)$q$, b),
    'INS_IMPORT_BATCH_NOT_FOUND', 'cross-tenant stage');
  perform pg_temp.expect_error(format('select public.ins_import_validate_batch(%L)', b),
    'INS_IMPORT_BATCH_NOT_FOUND', 'cross-tenant validate');
  perform pg_temp.assert(pg_temp.scalar_as_user(format('select count(*)::text from public.ins_import_batches where id = %L', b)) = '0',
    'cross-tenant select sees no batches');
  perform pg_temp.assert(pg_temp.scalar_as_user(format('select count(*)::text from public.ins_import_rows where batch_id = %L', b)) = '0',
    'cross-tenant select sees no rows');
  perform pg_temp.assert(pg_temp.scalar_as_user($q$select count(*)::text from public.ins_import_profiles$q$) = '0',
    'cross-tenant select sees no profiles');

  -- a committed batch is locked
  update public.ins_import_batches set status = 'committed' where id = b;
  perform pg_temp.jwt(i.mgr);
  perform pg_temp.expect_error(format($q$select public.ins_import_stage_rows(%L, 'policies', '[]'::jsonb)$q$, b),
    'INS_IMPORT_BATCH_LOCKED', 'stage into committed batch');
  perform pg_temp.expect_error(format('select public.ins_import_validate_batch(%L)', b),
    'INS_IMPORT_BATCH_LOCKED', 'validate committed batch');
end $$;

-- anon EXECUTE check (catalog-level, runs as owner)
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_import_create_batch','ins_import_stage_rows','ins_import_save_profile','ins_import_validate_batch',
                          'platform_ins_import_num','platform_ins_import_date','platform_ins_import_err')
     and grantee in ('anon', 'PUBLIC')),
  'anon / PUBLIC have no EXECUTE on import functions');
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('platform_ins_import_num','platform_ins_import_date','platform_ins_import_err')
     and grantee = 'authenticated'),
  'authenticated cannot execute the internal import helpers');

rollback;
