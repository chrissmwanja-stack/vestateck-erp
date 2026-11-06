-- Insurance brokerage, slice Q1: quotation pipeline
-- (20261106170000_ins_quotes.sql).
--
-- Covers: quote creation/numbering, the state machine
-- draft -> submitted -> accepted/declined -> placed, manager-only
-- decisions, placement creating a draft policy, RPC-only write
-- discipline (direct DML denied), anon EXECUTE denial, and cross-tenant
-- isolation.
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
    execute p_sql;
  exception when others then
    if sqlstate = p_state then return; end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
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
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.q_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as out, gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'Q Brokerage A' from pg_temp.q_ids
union all
select tb, 'Q Brokerage B' from pg_temp.q_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'q-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.q_ids union all select mem union all select out union all select mgr_b) u;

insert into app_users (id, tenant_id, name, email)
select i.mgr, i.ta, 'Q Manager A', 'q-' || i.mgr || '@test.local' from pg_temp.q_ids i
union all select i.mem, i.ta, 'Q Member A', 'q-' || i.mem || '@test.local' from pg_temp.q_ids i
union all select i.out, i.ta, 'Q Outsider A', 'q-' || i.out || '@test.local' from pg_temp.q_ids i
union all select i.mgr_b, i.tb, 'Q Manager B', 'q-' || i.mgr_b || '@test.local' from pg_temp.q_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.q_ids union all select tb, 'insurance' from pg_temp.q_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.q_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.q_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.q_ids;

-- master data for tenant A
create temp table pg_temp.q_master as
with ins as (
  insert into ins_insurers (tenant_id, code, name, is_active)
  select ta, 'QINS', 'Q Insurer', true from pg_temp.q_ids returning id
), line as (
  insert into ins_product_lines (tenant_id, code, name, class, is_active)
  select ta, 'GEN', 'General', 'general', true from pg_temp.q_ids returning id
), cli as (
  insert into ins_clients (tenant_id, name, kyc_status)
  select ta, 'Q Client', 'verified' from pg_temp.q_ids returning id
)
select i.id as insurer_id, l.id as product_line_id, c.id as client_id from ins i, line l, cli c;

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  i pg_temp.q_ids;
  m pg_temp.q_master;
  q uuid;
  pol uuid;
begin
  select * into i from pg_temp.q_ids;
  select * into m from pg_temp.q_master;

  -- outsider cannot create a quote
  perform pg_temp.jwt(i.out);
  perform pg_temp.expect_error(
    format('select public.ins_create_quote(%L,%L,%L, 1000000, ''UGX'', 120000, 10, null, null)',
           m.client_id, m.insurer_id, m.product_line_id),
    'INS_ACCESS_DENIED', 'outsider create quote');

  -- member creates a draft quote; number is stamped
  perform pg_temp.jwt(i.mem);
  select id into q from public.ins_create_quote(
    m.client_id, m.insurer_id, m.product_line_id, 1000000, 'UGX', 120000, 10, current_date + 30, 'first quote');
  perform pg_temp.assert(pg_temp.scalar(format('select quote_no from public.ins_quotes where id = %L', q)) like 'Q-%',
    'quote_no stamped');
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_quotes where id = %L', q)) = 'draft',
    'new quote is draft');

  -- direct table writes are denied (RPC-only discipline)
  perform pg_temp.expect_state(
    format('insert into public.ins_quotes (tenant_id, quote_no, client_id, insurer_id, product_line_id) values (%L, ''Q-X'', %L, %L, %L)',
           i.ta, m.client_id, m.insurer_id, m.product_line_id),
    '42501', 'direct insert ins_quotes');
  perform pg_temp.expect_state(
    format('update public.ins_quotes set notes = ''hacked'' where id = %L', q),
    '42501', 'direct update ins_quotes');

  -- member cannot decide (manager tier)
  perform pg_temp.expect_error(
    format('select public.ins_decide_quote(%L, ''accepted'')', q),
    'INS_ACCESS_DENIED', 'member decides quote');

  -- manager cannot decide a draft
  perform pg_temp.jwt(i.mgr);
  perform pg_temp.expect_error(
    format('select public.ins_decide_quote(%L, ''accepted'')', q),
    'INS_QUOTE_NOT_SUBMITTED', 'decide before submit');

  -- submit, then resubmit refused
  perform pg_temp.jwt(i.mem);
  perform public.ins_submit_quote(q);
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_quotes where id = %L', q)) = 'submitted',
    'submitted after submit');
  perform pg_temp.expect_error(
    format('select public.ins_submit_quote(%L)', q),
    'INS_QUOTE_NOT_DRAFT', 'double submit');

  -- bad decision value refused
  perform pg_temp.jwt(i.mgr);
  perform pg_temp.expect_error(
    format('select public.ins_decide_quote(%L, ''maybe'')', q),
    'INS_QUOTE_BAD_DECISION', 'bad decision');

  -- accept, then place -> draft policy created and linked
  perform public.ins_decide_quote(q, 'accepted', 'INS-REF-1');
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_quotes where id = %L', q)) = 'accepted',
    'accepted after decide');
  select id into pol from public.ins_place_quote(q);
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_quotes where id = %L', q)) = 'placed',
    'placed after place');
  perform pg_temp.assert(pg_temp.scalar(format('select accepted_policy_id from public.ins_quotes where id = %L', q)) = pol::text,
    'quote links to policy');
  perform pg_temp.assert(pg_temp.scalar(format('select status from public.ins_policies where id = %L', pol)) = 'draft',
    'placed policy is a draft');
  perform pg_temp.assert(pg_temp.scalar(format('select gross_premium::text from public.ins_policies where id = %L', pol)) = '120000.00',
    'policy carries quote premium');

  -- cannot place twice
  perform pg_temp.expect_error(
    format('select public.ins_place_quote(%L)', q),
    'INS_QUOTE_NOT_ACCEPTED', 'double place');

  -- cross-tenant: manager B cannot see or touch tenant A's quote
  perform pg_temp.jwt(i.mgr_b);
  perform pg_temp.expect_error(
    format('select public.ins_submit_quote(%L)', q),
    'INS_QUOTE_NOT_FOUND', 'cross-tenant submit');
  perform pg_temp.assert(
    pg_temp.scalar(format('select count(*)::text from public.ins_quotes where id = %L', q)) = '0',
    'cross-tenant select sees no rows');
  perform pg_temp.assert(
    pg_temp.scalar(format('select count(*)::text from public.ins_quotes where tenant_id = %L and id = %L', i.ta, q)) = '1',
    'row still intact in tenant A');
end $$;

-- anon EXECUTE check (catalog-level, runs as owner)
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_create_quote','ins_submit_quote','ins_decide_quote','ins_place_quote')
     and grantee = 'anon'),
  'anon has no EXECUTE on quote RPCs');

rollback;
