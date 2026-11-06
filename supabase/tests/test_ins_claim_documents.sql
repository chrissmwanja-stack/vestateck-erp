-- Insurance brokerage, slice C1: claim excess + document checklist
-- (20261106210000_ins_claim_excess_and_documents.sql).
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
-- Fixtures
---------------------------------------------------------------------
create temp table pg_temp.c_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'C Brokerage A' from pg_temp.c_ids union all select tb, 'C Brokerage B' from pg_temp.c_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'c-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.c_ids union all select mem union all select mgr_b) u;

insert into app_users (id, tenant_id, name, email)
select i.mgr, i.ta, 'C Manager A', 'c-' || i.mgr || '@test.local' from pg_temp.c_ids i
union all select i.mem, i.ta, 'C Member A', 'c-' || i.mem || '@test.local' from pg_temp.c_ids i
union all select i.mgr_b, i.tb, 'C Manager B', 'c-' || i.mgr_b || '@test.local' from pg_temp.c_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.c_ids union all select tb, 'insurance' from pg_temp.c_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.c_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.c_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.c_ids;

create temp table pg_temp.c_master as
with ins as (
  insert into ins_insurers (tenant_id, code, name) select ta, 'CINS', 'C Insurer' from pg_temp.c_ids returning id
), line as (
  insert into ins_product_lines (tenant_id, code, name, class) select ta, 'GEN', 'General', 'general' from pg_temp.c_ids returning id
), cli as (
  insert into ins_clients (tenant_id, name, kyc_status) select ta, 'C Client', 'verified' from pg_temp.c_ids returning id
)
select i.id as insurer_id, l.id as product_line_id, c.id as client_id from ins i, line l, cli c;

create temp table pg_temp.c_claim as
with m as (select * from pg_temp.c_master), i as (select * from pg_temp.c_ids),
pol as (
  insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, status, inception_date, expiry_date, gross_premium, currency)
  select i.ta, 'POL-C1', m.client_id, m.insurer_id, m.product_line_id, 'active', current_date - 100, current_date + 265, 100000, 'UGX' from m, i
  returning id
)
insert into ins_claims (tenant_id, claim_no, policy_id, status, loss_date, notified_date, loss_description, reserve_amount)
select i.ta, 'CLM-C1', pol.id, 'assessing', current_date - 5, current_date - 4, 'Test loss', 50000 from pol, i
returning id as claim_id;

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  i pg_temp.c_ids;
  cl uuid;
begin
  select * into i from pg_temp.c_ids;
  select claim_id into cl from pg_temp.c_claim;

  -- excess columns exist with the four allowed modes
  perform pg_temp.jwt(i.mem);
  perform pg_temp.assert(
    pg_temp.scalar(format('select excess_handling from public.ins_claims where id = %L', cl)) = 'insurer_deducts',
    'excess defaults to insurer_deducts');

  -- member marks a document provided
  perform public.ins_set_claim_document(cl, 'police_report', 'provided', 'ref 123');
  perform pg_temp.assert(
    pg_temp.scalar(format('select status from public.ins_claim_documents where claim_id = %L and doc_type = ''police_report''', cl)) = 'provided',
    'document provided');

  -- upsert is idempotent per (claim, doc_type)
  perform public.ins_set_claim_document(cl, 'police_report', 'provided', 'ref 456');
  perform pg_temp.assert(
    pg_temp.scalar(format('select count(*)::text from public.ins_claim_documents where claim_id = %L and doc_type = ''police_report''', cl)) = '1',
    'one row per doc_type');
  perform pg_temp.assert(
    pg_temp.scalar(format('select note from public.ins_claim_documents where claim_id = %L and doc_type = ''police_report''', cl)) = 'ref 456',
    'upsert updates note');

  -- members cannot verify (manager tier)
  perform pg_temp.expect_error(
    format('select public.ins_verify_claim_document(%L, ''police_report'')', cl),
    'INS_ACCESS_DENIED', 'member verifies');

  -- cannot verify a missing doc
  perform pg_temp.jwt(i.mgr);
  perform pg_temp.expect_error(
    format('select public.ins_verify_claim_document(%L, ''photos'')', cl),
    'INS_CLAIM_DOC_NOT_FOUND', 'verify missing doc');
  perform public.ins_set_claim_document(cl, 'photos', 'provided', null);
  -- 'verified' not allowed through the member RPC
  perform pg_temp.expect_error(
    format('select public.ins_set_claim_document(%L, ''photos'', ''verified'')', cl),
    'INS_CLAIM_DOC_BAD_STATUS', 'member RPC refuses verified');
  perform public.ins_verify_claim_document(cl, 'photos');
  perform pg_temp.assert(
    pg_temp.scalar(format('select status from public.ins_claim_documents where claim_id = %L and doc_type = ''photos''', cl)) = 'verified',
    'manager verifies');

  -- direct table write denied
  perform pg_temp.expect_state(
    format('insert into public.ins_claim_documents (tenant_id, claim_id, doc_type) values (%L, %L, ''x'')', i.ta, cl),
    '42501', 'direct insert denied');

  -- cross-tenant: manager B cannot touch tenant A's claim docs
  perform pg_temp.jwt(i.mgr_b);
  perform pg_temp.expect_error(
    format('select public.ins_set_claim_document(%L, ''police_report'', ''provided'')', cl),
    'INS_CLAIM_NOT_FOUND', 'cross-tenant doc write');
  perform pg_temp.assert(
    pg_temp.scalar(format('select count(*)::text from public.ins_claim_documents where claim_id = %L', cl)) = '0',
    'cross-tenant select empty');
end $$;

select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_set_claim_document','ins_verify_claim_document')
     and grantee = 'anon'),
  'anon has no EXECUTE on claim doc RPCs');

rollback;
