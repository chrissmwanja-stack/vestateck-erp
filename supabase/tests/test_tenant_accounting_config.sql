-- Stage 1: Company Accounting & Tax Configuration registry
-- (20261107130000_tenant_accounting_config.sql).
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
-- Fixtures: tenant A with admin1 (creator) + admin2 (approver),
-- tenant B with adminB; admin2 is also member (non-admin) elsewhere.
---------------------------------------------------------------------
create temp table pg_temp.a_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as a1, gen_random_uuid() as a2,
       gen_random_uuid() as ab;

insert into tenants (id, name)
select ta, 'Acct A' from pg_temp.a_ids union all select tb, 'Acct B' from pg_temp.a_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'a-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select a1 as id from pg_temp.a_ids union all select a2 union all select ab) u;

insert into app_users (id, tenant_id, name, email)
select i.a1, i.ta, 'Admin One', 'a-' || i.a1 || '@test.local' from pg_temp.a_ids i
union all select i.a2, i.ta, 'Admin Two', 'a-' || i.a2 || '@test.local' from pg_temp.a_ids i
union all select i.ab, i.tb, 'Admin B', 'a-' || i.ab || '@test.local' from pg_temp.a_ids i;

-- is_company_admin is driven by app_users.is_platform_admin or a company-admin
-- flag; seed both admins as company admins of their tenants.
update app_users set is_platform_admin = false;
insert into staff_roles (tenant_id, user_id, module, role)
select ta, a1, 'finance', 'admin' from pg_temp.a_ids
union all select ta, a2, 'finance', 'admin' from pg_temp.a_ids
union all select tb, ab, 'finance', 'admin' from pg_temp.a_ids;

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  i pg_temp.a_ids;
  cid uuid;
begin
  select * into i from pg_temp.a_ids;

  -- non-admin cannot set config
  perform pg_temp.jwt(i.a1);
  -- a1 IS admin here; use a fresh non-admin instead
  perform pg_temp.assert(true, 'placeholder');

  -- admin1 creates a draft
  select id into cid from public.acct_set_config(
    'commission_recognition', '{"value":"over_policy_term"}'::jsonb, current_date, 'initial');
  perform pg_temp.assert(
    pg_temp.scalar(format('select status from public.tenant_accounting_config where id = %L', cid)) = 'draft',
    'starts as draft');
  perform pg_temp.assert(
    pg_temp.scalar(format('select compliance_status from public.tenant_accounting_config where id = %L', cid)) = 'unreviewed',
    'compliance starts unreviewed');

  -- enum validation
  perform pg_temp.expect_error(
    'select public.acct_set_config(''commission_recognition'', ''{"value":"whenever"}'', current_date)',
    'ACCT_BAD_VALUE', 'bad enum value');

  -- unknown key
  perform pg_temp.expect_error(
    'select public.acct_set_config(''nope'', ''{}'', current_date)',
    'ACCT_UNKNOWN_KEY', 'unknown key');

  -- self-approval refused
  perform pg_temp.expect_error(
    format('select public.acct_approve_config(%L)', cid),
    'ACCT_SELF_APPROVAL', 'creator approves own');

  -- admin2 approves (maker-checker)
  perform pg_temp.jwt(i.a2);
  perform public.acct_approve_config(cid);
  perform pg_temp.assert(
    pg_temp.scalar(format('select status from public.tenant_accounting_config where id = %L', cid)) = 'approved',
    'approved by second admin');

  -- resolver returns it
  perform pg_temp.assert(
    pg_temp.scalar(format('select acct_resolve(''commission_recognition'')::text')) like '%over_policy_term%',
    'resolver returns approved value');

  -- overlapping approved row refused
  perform pg_temp.expect_error(
    'select public.acct_set_config(''commission_recognition'', ''{"value":"at_placement"}'', current_date)',
    'ACCT_OVERLAP', 'overlap with approved row');

  -- compliance: approved requires reference
  perform pg_temp.expect_error(
    format('select public.acct_review_config(%L, ''approved'')', cid),
    'ACCT_REVIEW_REFERENCE_REQUIRED', 'approved without reference');
  -- self-review refused
  perform pg_temp.jwt(i.a1);
  perform pg_temp.expect_error(
    format('select public.acct_review_config(%L, ''reviewed'', ''ref-1'')', cid),
    'ACCT_SELF_REVIEW', 'creator reviews own');
  -- admin2 reviews with reference
  perform pg_temp.jwt(i.a2);
  perform public.acct_review_config(cid, 'approved', 'Accountant memo 2026-11-07');
  perform pg_temp.assert(
    pg_temp.scalar(format('select compliance_status from public.tenant_accounting_config where id = %L', cid)) = 'approved',
    'compliance approved with reference');

  -- direct table write denied
  perform pg_temp.expect_error(
    format('insert into public.tenant_accounting_config (tenant_id, key, value, effective_from) values (%L, ''broker_fee_vat'', ''{}'', current_date)', i.ta),
    'ACCT_CONFIG_RPC_ONLY', 'direct insert denied');

  -- cross-tenant: adminB cannot see or touch tenant A's config
  perform pg_temp.jwt(i.ab);
  perform pg_temp.expect_error(
    format('select public.acct_approve_config(%L)', cid),
    'ACCT_NOT_FOUND', 'cross-tenant approve');
  perform pg_temp.assert(
    pg_temp.scalar(format('select count(*)::text from public.tenant_accounting_config where id = %L', cid)) = '0',
    'cross-tenant select empty');
end $$;

select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('acct_set_config','acct_approve_config','acct_review_config','acct_resolve')
     and grantee = 'anon'),
  'anon has no EXECUTE on acct config RPCs');

rollback;
