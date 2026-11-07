-- Add-on test: legal-review guard on company_accounting_settings
-- (20261107235901_accounting_settings_legal_review.sql).
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
-- Fixtures
---------------------------------------------------------------------
create temp table pg_temp.l_ids as
select gen_random_uuid() as ta, gen_random_uuid() as a1, gen_random_uuid() as a2;

insert into tenants (id, name) select ta, 'Legal A' from pg_temp.l_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'l-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select a1 as id from pg_temp.l_ids union all select a2 from pg_temp.l_ids) u;

insert into app_users (id, tenant_id, name, email)
select i.a1, i.ta, 'Admin One', 'l-' || i.a1 || '@test.local' from pg_temp.l_ids i
union all select i.a2, i.ta, 'Admin Two', 'l-' || i.a2 || '@test.local' from pg_temp.l_ids i;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, a1, 'finance', 'admin' from pg_temp.l_ids
union all select ta, a2, 'finance', 'admin' from pg_temp.l_ids;

-- a legal-review key definition
insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, default_value, requires_legal_review)
values ('ins.agent_commission_wht', 'WHT on agent commission', 'legal applicability',
        array['applicable','not_applicable'], 'applicable', true)
on conflict (key) do nothing;

-- a non-legal key
insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, default_value, requires_legal_review)
values ('ins.commission_recognition_test', 'Recognition', 'accounting choice',
        array['a','b'], 'a', false)
on conflict (key) do nothing;

---------------------------------------------------------------------
-- Scenarios (direct inserts go through the RPC guard, so use the
-- settings RPC if present, else insert with ins.via_rpc set)
---------------------------------------------------------------------
do $$
declare
  i pg_temp.l_ids;
begin
  select * into i from pg_temp.l_ids;
  perform pg_temp.jwt(i.a1);

  -- legal key: reviewed by the proposer is refused
  perform pg_temp.expect_error(
    format('set local ins.via_rpc = ''on''; insert into public.company_accounting_settings (tenant_id, setting_key, value, effective_from, rationale, review_status, reviewer_name, review_reference, reviewed_by, reviewed_at, created_by) values (%L, ''ins.agent_commission_wht'', ''applicable'', current_date, ''legal test rationale'', ''reviewed'', ''Admin One'', ''memo 1'', %L, now(), %L)', i.ta, i.a1, i.a1),
    'ACCT_LEGAL_SELF_REVIEW', 'proposer reviews own legal key');

  -- legal key: reviewed by someone else but no reference is refused
  perform pg_temp.expect_error(
    format('set local ins.via_rpc = ''on''; insert into public.company_accounting_settings (tenant_id, setting_key, value, effective_from, rationale, review_status, reviewer_name, review_reference, reviewed_by, reviewed_at, created_by) values (%L, ''ins.agent_commission_wht'', ''applicable'', current_date, ''legal test rationale'', ''reviewed'', ''Admin Two'', '''', %L, now(), %L)', i.ta, i.a2, i.a1),
    'ACCT_LEGAL_REFERENCE_REQUIRED', 'legal key reviewed without reference');

  -- legal key: different reviewer + reference is accepted
  perform pg_temp.assert(
    pg_temp.scalar(format('set local ins.via_rpc = ''on''; insert into public.company_accounting_settings (tenant_id, setting_key, value, effective_from, rationale, review_status, reviewer_name, review_reference, reviewed_by, reviewed_at, created_by) values (%L, ''ins.agent_commission_wht'', ''applicable'', current_date, ''legal test rationale'', ''reviewed'', ''Admin Two'', ''Accountant memo 2026-11-07'', %L, now(), %L) returning review_status', i.ta, i.a2, i.a1)) = 'reviewed',
    'legal key accepted with proper review');

  -- non-legal key: self-review allowed
  perform pg_temp.assert(
    pg_temp.scalar(format('set local ins.via_rpc = ''on''; insert into public.company_accounting_settings (tenant_id, setting_key, value, effective_from, rationale, review_status, reviewer_name, review_reference, reviewed_by, reviewed_at, created_by) values (%L, ''ins.commission_recognition_test'', ''b'', current_date, ''accounting choice rationale'', ''reviewed'', ''Admin One'', ''n/a'', %L, now(), %L) returning review_status', i.ta, i.a1, i.a1)) = 'reviewed',
    'non-legal key may be self-reviewed');
end $$;

rollback;