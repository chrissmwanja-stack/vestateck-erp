-- Insurance brokerage, slice S1: insurer statement reconciliation
-- (20261106220000_ins_insurer_statement_reconciliation.sql).
-- One transaction, ROLLBACK at end; fresh local stack only.

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

---------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------
create temp table pg_temp.s_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'S Brokerage A' from pg_temp.s_ids union all select tb, 'S Brokerage B' from pg_temp.s_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  's-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.s_ids union all select mem from pg_temp.s_ids union all select mgr_b from pg_temp.s_ids) u;

insert into app_users (id, tenant_id, name, email)
select i.mgr, i.ta, 'S Manager A', 's-' || i.mgr || '@test.local' from pg_temp.s_ids i
union all select i.mem, i.ta, 'S Member A', 's-' || i.mem || '@test.local' from pg_temp.s_ids i
union all select i.mgr_b, i.tb, 'S Manager B', 's-' || i.mgr_b || '@test.local' from pg_temp.s_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.s_ids union all select tb, 'insurance' from pg_temp.s_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.s_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.s_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.s_ids;

select set_config('ins.via_rpc', 'on', true);  -- fixture clients start verified
create temp table pg_temp.s_master as
with ins as (
  insert into ins_insurers (tenant_id, code, name) select ta, 'SINS', 'S Insurer' from pg_temp.s_ids returning id
), line as (
  insert into ins_product_lines (tenant_id, code, name, class) select ta, 'GEN', 'General', 'general' from pg_temp.s_ids returning id
), bdc as (
  insert into bd_clients (tenant_id, name)
  select ta, 'S Client' from pg_temp.s_ids returning id, tenant_id
), cli as (
  insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
  select tenant_id, id, 'corporate', 'verified' from bdc returning id
)
select i.id as insurer_id, l.id as product_line_id, c.id as client_id from ins i, line l, cli c;
select set_config('ins.via_rpc', 'off', true);

select set_config('ins.via_rpc', 'on', true);  -- fixtures written directly as the owner
create temp table pg_temp.s_policy as
with m as (select * from pg_temp.s_master), i as (select * from pg_temp.s_ids),
pol as (
  insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, status, inception_date, expiry_date,
                            gross_premium, currency, commission_amount, net_premium_to_insurer, bound_at)
  select i.ta, 'POL-S1', m.client_id, m.insurer_id, m.product_line_id, 'active', current_date - 100, current_date + 265,
         100000, 'UGX', 10000, 90000, now() from m, i
  returning id as policy_id
)
select policy_id from pol;

create temp table pg_temp.s_claim as
with p as (select * from pg_temp.s_policy), i as (select * from pg_temp.s_ids),
clm as (
  insert into ins_claims (tenant_id, claim_no, policy_id, status, loss_date, notified_date, loss_description, paid_amount)
  select i.ta, 'CLM-S1', p.policy_id, 'settled', current_date - 5, current_date - 4, 'Test', 20000 from p, i
  returning id as claim_id
)
select claim_id from clm;
select set_config('ins.via_rpc', 'off', true);

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  i pg_temp.s_ids;
  m pg_temp.s_master;
  pol uuid;
  stmt uuid;
  mismatches text;
begin
  select * into i from pg_temp.s_ids;
  select * into m from pg_temp.s_master;
  select policy_id into pol from pg_temp.s_policy;

  -- member cannot record a statement (manager tier)
  perform pg_temp.jwt(i.mem);
  perform pg_temp.expect_error(
    format('select public.ins_record_insurer_statement(%L, ''ST-1'', current_date - 30, current_date, ''[]''::jsonb)', m.insurer_id),
    'INS_ACCESS_DENIED', 'member cannot record a statement');

  -- a manager is refused an empty statement
  perform pg_temp.jwt(i.mgr);
  perform pg_temp.expect_error(
    format('select public.ins_record_insurer_statement(%L, ''ST-1'', current_date - 30, current_date, ''[]''::jsonb)', m.insurer_id),
    'INS_STATEMENT_NO_LINES', 'empty lines refused');

  -- manager records a statement; one line matches premium (100000),
  -- claims match (20000), commission mismatches (insurer says 12000, we have 0)
  perform pg_temp.jwt(i.mgr);
  select id into stmt from public.ins_record_insurer_statement(
    m.insurer_id, 'ST-1', current_date - 30, current_date,
    jsonb_build_array(jsonb_build_object('policy_id', pol, 'premium', 100000, 'commission', 12000, 'claims_paid', 20000)));

  select count(*)::text into mismatches from public.ins_insurer_statement_reconciliation(stmt) where not match;
  perform pg_temp.assert(mismatches = '1', 'exactly the commission line mismatches, got ' || mismatches);
  perform pg_temp.assert(
    pg_temp.scalar(format('select count(*)::text from public.ins_insurer_statement_reconciliation(%L) where match', stmt)) = '2',
    'premium and claims match');

  -- foreign policy in a line is refused
  perform pg_temp.expect_error(
    format('select public.ins_record_insurer_statement(%L, ''ST-2'', current_date - 30, current_date, jsonb_build_array(jsonb_build_object(''policy_id'', gen_random_uuid(), ''premium'', 1)))', m.insurer_id),
    'INS_STATEMENT_FOREIGN_POLICY', 'foreign policy line');

  -- member cannot decide status; manager marks reconciled
  perform pg_temp.jwt(i.mem);
  perform pg_temp.expect_error(
    format('select public.ins_decide_insurer_statement(%L, ''reconciled'')', stmt),
    'INS_ACCESS_DENIED', 'member decides statement');
  perform pg_temp.jwt(i.mgr);
  perform public.ins_decide_insurer_statement(stmt, 'reconciled');
  perform pg_temp.assert(
    pg_temp.scalar(format('select status from public.ins_insurer_statements where id = %L', stmt)) = 'reconciled',
    'statement reconciled');

  -- cross-tenant: manager B cannot reconcile tenant A's statement
  perform pg_temp.jwt(i.mgr_b);
  perform pg_temp.expect_error(
    format('select public.ins_insurer_statement_reconciliation(%L)', stmt),
    'INS_STATEMENT_NOT_FOUND', 'cross-tenant reconcile');
  perform pg_temp.assert(
    pg_temp.scalar_as_user(format('select count(*)::text from public.ins_insurer_statements where id = %L', stmt)) = '0',
    'cross-tenant select empty');
end $$;

select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_record_insurer_statement','ins_insurer_statement_reconciliation','ins_decide_insurer_statement')
     and grantee = 'anon'),
  'anon has no EXECUTE on statement RPCs');

rollback;
