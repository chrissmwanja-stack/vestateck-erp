
-- Insurance brokerage, slice B1: renewal notices
-- (20261106200000_ins_renewal_notices.sql).
--
-- Covers: idempotent bulk generation over the 120-day window, one notice
-- per policy, draft -> sent (manager only), direct DML denial, cross-tenant
-- isolation, anon EXECUTE.
--
-- Run against a fresh local stack only. One transaction, ROLLBACK at end.

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
    -- The SET LOCAL is undone with the subtransaction when the statement fails.
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

---------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------
create temp table pg_temp.n_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'N Brokerage A' from pg_temp.n_ids union all select tb, 'N Brokerage B' from pg_temp.n_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'n-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.n_ids union all select mem from pg_temp.n_ids union all select mgr_b from pg_temp.n_ids) u;

insert into app_users (id, tenant_id, name, email)
select i.mgr, i.ta, 'N Manager A', 'n-' || i.mgr || '@test.local' from pg_temp.n_ids i
union all select i.mem, i.ta, 'N Member A', 'n-' || i.mem || '@test.local' from pg_temp.n_ids i
union all select i.mgr_b, i.tb, 'N Manager B', 'n-' || i.mgr_b || '@test.local' from pg_temp.n_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.n_ids union all select tb, 'insurance' from pg_temp.n_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.n_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.n_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.n_ids;

select set_config('ins.via_rpc', 'on', true);  -- fixture clients start verified
create temp table pg_temp.n_master as
with ins as (
  insert into ins_insurers (tenant_id, code, name) select ta, 'NINS', 'N Insurer' from pg_temp.n_ids returning id
), line as (
  insert into ins_product_lines (tenant_id, code, name, class) select ta, 'GEN', 'General', 'general' from pg_temp.n_ids returning id
), bdc as (
  insert into bd_clients (tenant_id, name)
  select ta, 'N Client' from pg_temp.n_ids returning id, tenant_id
), cli as (
  insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
  select tenant_id, id, 'corporate', 'verified' from bdc returning id
)
select i.id as insurer_id, l.id as product_line_id, c.id as client_id from ins i, line l, cli c;
select set_config('ins.via_rpc', 'off', true);

-- tenant B has its own master data (a policy may only reference its own tenant's records)
select set_config('ins.via_rpc', 'on', true);  -- fixture clients start verified
create temp table pg_temp.n_master_b as
with ins as (
  insert into ins_insurers (tenant_id, code, name) select tb, 'NINSB', 'N Insurer B' from pg_temp.n_ids returning id
), line as (
  insert into ins_product_lines (tenant_id, code, name, class) select tb, 'GENB', 'General B', 'general' from pg_temp.n_ids returning id
), bdc as (
  insert into bd_clients (tenant_id, name)
  select tb, 'N Client B' from pg_temp.n_ids returning id, tenant_id
), cli as (
  insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
  select tenant_id, id, 'corporate', 'verified' from bdc returning id
)
select i.id as insurer_id, l.id as product_line_id, c.id as client_id from ins i, line l, cli c;
select set_config('ins.via_rpc', 'off', true);

-- two active policies expiring soon in tenant A, one far-future, one in tenant B.
-- Written directly (as the owner, through the RPC channel), so the bound stamps
-- that ins_policies_bound_check demands for an active policy are supplied here.
select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.n_policies as
with m as (select * from pg_temp.n_master), mb as (select * from pg_temp.n_master_b), i as (select * from pg_temp.n_ids),
ins as (
  insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, status, inception_date, expiry_date,
                            gross_premium, currency, commission_amount, net_premium_to_insurer, bound_at)
  select i.ta, 'POL-SOON-1', m.client_id, m.insurer_id, m.product_line_id, 'active', current_date - 300, current_date + 30, 100000, 'UGX', 10000, 90000, now() from m, i
  union all
  select i.ta, 'POL-SOON-2', m.client_id, m.insurer_id, m.product_line_id, 'active', current_date - 300, current_date + 60, 200000, 'UGX', 20000, 180000, now() from m, i
  union all
  select i.ta, 'POL-FAR', m.client_id, m.insurer_id, m.product_line_id, 'active', current_date - 10, current_date + 300, 50000, 'UGX', 5000, 45000, now() from m, i
  union all
  select i.tb, 'POL-B', mb.client_id, mb.insurer_id, mb.product_line_id, 'active', current_date - 10, current_date + 20, 50000, 'UGX', 5000, 45000, now() from mb, i
  returning id, policy_no
)
select id, policy_no from ins;
select set_config('ins.via_rpc', 'off', true);

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  i pg_temp.n_ids;
  n uuid;
  cnt text;
begin
  select * into i from pg_temp.n_ids;

  -- member generates notices: only the two in-window tenant-A policies
  perform pg_temp.jwt(i.mem);
  select count(*)::text into cnt from public.ins_generate_renewal_notices();
  perform pg_temp.assert(cnt = '2', 'generates 2 notices, got ' || cnt);

  -- idempotent: second run creates none
  select count(*)::text into cnt from public.ins_generate_renewal_notices();
  perform pg_temp.assert(cnt = '0', 'second run idempotent, got ' || cnt);

  -- notice numbers stamped
  perform pg_temp.assert(
    pg_temp.scalar('select count(*)::text from public.ins_renewal_notices where notice_no like ''N-%''') = '2',
    'notice_no stamped');

  -- direct writes denied
  perform pg_temp.expect_state(
    format('insert into public.ins_renewal_notices (tenant_id, notice_no, policy_id) select %L, ''N-X'', id from public.ins_policies limit 1', i.ta),
    '42501', 'direct insert denied');

  select id into n from public.ins_renewal_notices order by created_at limit 1;

  -- member cannot mark sent (manager tier)
  perform pg_temp.expect_error(
    format('select public.ins_mark_renewal_notice_sent(%L)', n),
    'INS_ACCESS_DENIED', 'member marks sent');

  -- manager marks sent
  perform pg_temp.jwt(i.mgr);
  perform public.ins_mark_renewal_notice_sent(n, 'email');
  perform pg_temp.assert(
    pg_temp.scalar(format('select status from public.ins_renewal_notices where id = %L', n)) = 'sent',
    'sent after mark');
  perform pg_temp.expect_error(
    format('select public.ins_mark_renewal_notice_sent(%L)', n),
    'INS_NOTICE_NOT_DRAFT', 'double mark');

  -- cross-tenant: manager B cannot see or touch tenant A's notice
  perform pg_temp.jwt(i.mgr_b);
  perform pg_temp.expect_error(
    format('select public.ins_mark_renewal_notice_sent(%L)', n),
    'INS_NOTICE_NOT_FOUND', 'cross-tenant mark');
  perform pg_temp.assert(
    pg_temp.scalar_as_user(format('select count(*)::text from public.ins_renewal_notices where id = %L', n)) = '0',
    'cross-tenant select empty');
  perform pg_temp.assert(
    pg_temp.scalar(format('select count(*)::text from public.ins_renewal_notices where tenant_id = %L', i.ta)) = '2',
    'tenant A rows intact');
end $$;

select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_generate_renewal_notices','ins_mark_renewal_notice_sent')
     and grantee = 'anon'),
  'anon has no EXECUTE on notice RPCs');

rollback;
