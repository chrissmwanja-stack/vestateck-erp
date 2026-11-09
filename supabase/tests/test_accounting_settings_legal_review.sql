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

-- Company admins (is_tenant_admin()); 'finance' is not an entitlable staff_roles module.
insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.a1, i.ta, 'Admin One', 'l-' || i.a1 || '@test.local', true from pg_temp.l_ids i
union all select i.a2, i.ta, 'Admin Two', 'l-' || i.a2 || '@test.local', true from pg_temp.l_ids i;

-- a legal-review key definition
insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, implemented_values, default_value, requires_legal_review)
values ('ins.agent_commission_wht', 'WHT on agent commission', 'legal applicability',
        array['applicable','not_applicable'], array['applicable','not_applicable'], 'applicable', true)
on conflict (key) do nothing;

-- a non-legal key
insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, implemented_values, default_value, requires_legal_review)
values ('ins.commission_recognition_test', 'Recognition', 'accounting choice',
        array['a','b'], array['a','b'], 'a', false)
on conflict (key) do nothing;

---------------------------------------------------------------------
-- Scenarios. A new setting can only be inserted as an unreviewed draft
-- (company_accounting_settings_guard), so reviews are recorded the way the
-- app does it: acct_setting_propose, then acct_setting_record_review.
-- The legal-review trigger sorts before the guard trigger, so it also fires
-- for a direct update with acct.via_rpc on.
---------------------------------------------------------------------
do $$
declare
  i pg_temp.l_ids;
  v_legal uuid;
  v_plain uuid;
begin
  select * into i from pg_temp.l_ids;

  -- Admin One proposes a legal-applicability key and a plain key.
  perform pg_temp.jwt(i.a1);
  v_legal := (select id from public.acct_setting_propose(
    'ins.agent_commission_wht', 'applicable', current_date, 'legal test rationale'));
  v_plain := (select id from public.acct_setting_propose(
    'ins.commission_recognition_test', 'b', current_date, 'accounting choice rationale'));

  -- legal key: the proposer cannot record the review
  perform pg_temp.expect_error(
    format('select * from public.acct_setting_record_review(%L, ''Admin One'', ''memo 1'')', v_legal),
    'ACCT_LEGAL_SELF_REVIEW', 'proposer reviews own legal key');

  -- legal key: someone else, but no reference (the RPC itself refuses a blank one)
  perform pg_temp.jwt(i.a2);
  perform pg_temp.expect_error(
    format('select * from public.acct_setting_record_review(%L, ''Admin Two'', '''')', v_legal),
    'ACCT_SETTING_REVIEW_DETAILS', 'legal key reviewed without reference (RPC)');

  -- legal key: the trigger itself refuses a blank reference on a direct update
  perform pg_temp.expect_error(
    format('set local acct.via_rpc = ''on''; update public.company_accounting_settings set review_status = ''reviewed'', reviewer_name = ''Admin Two'', review_reference = '''', reviewed_by = %L, reviewed_at = now() where id = %L', i.a2, v_legal),
    'ACCT_LEGAL_REFERENCE_REQUIRED', 'legal key reviewed without reference (trigger)');

  -- legal key: different reviewer + reference is accepted
  perform pg_temp.assert(
    pg_temp.scalar(format('select review_status from public.acct_setting_record_review(%L, ''Admin Two'', ''Accountant memo 2026-11-07'')', v_legal)) = 'reviewed',
    'legal key accepted with proper review');

  -- non-legal key: self-review allowed
  perform pg_temp.jwt(i.a1);
  perform pg_temp.assert(
    pg_temp.scalar(format('select review_status from public.acct_setting_record_review(%L, ''Admin One'', ''n/a'')', v_plain)) = 'reviewed',
    'non-legal key may be self-reviewed');
end $$;

rollback;