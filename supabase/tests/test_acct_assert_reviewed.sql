-- Stage 4: acct_assert_reviewed gate (20261107235905). One tx, ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.expect_error(p_sql text, p_needle text, p_label text) returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then return; end if;
    raise exception 'FAIL: % wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % should have failed with %', p_label, p_needle;
end $$;
create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as $$
begin if not coalesce(p_ok,false) then raise exception 'FAIL: %', p_msg; end if; end $$;
create function pg_temp.jwt(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role','authenticated')::text, true); $$;
create function pg_temp.scalar(p_sql text) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare v text; begin execute p_sql into v; return v; end $$;

create temp table pg_temp.g_ids as select gen_random_uuid() as ta, gen_random_uuid() as mgr, gen_random_uuid() as adm;
insert into tenants (id, name) select ta, 'Gate A' from pg_temp.g_ids;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated','authenticated','g-'||u.id||'@t.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}','{}',now(),now(),'',''
from (select mgr as id from pg_temp.g_ids union all select adm from pg_temp.g_ids) u;
-- Two company admins (is_tenant_admin()): one proposes, the other approves and reviews.
insert into app_users (id, tenant_id, name, email, is_company_admin) select i.mgr, i.ta, 'Mgr','g-'||i.mgr||'@t.local', true from pg_temp.g_ids i union all select i.adm, i.ta, 'Adm','g-'||i.adm||'@t.local', true from pg_temp.g_ids i;

do $$
declare i pg_temp.g_ids; cid uuid;
begin
  select * into i from pg_temp.g_ids;
  -- make the recognition key a LEGAL key for this test
  update public.accounting_setting_definitions set requires_legal_review = true where key = 'ins.commission_recognition';

  perform pg_temp.jwt(i.adm);
  perform public.acct_setting_propose('ins.commission_recognition', 'on_insurer_settlement', current_date, 'gate test rationale');
  select id into cid from public.company_accounting_settings where setting_key='ins.commission_recognition' and status='draft' limit 1;
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_approve(cid);

  -- approved but unreviewed legal key -> gate refuses
  perform pg_temp.expect_error(
    'select public.acct_assert_reviewed(''ins.commission_recognition'')',
    'ACCT_LEGAL_UNREVIEWED', 'unreviewed legal key blocked');

  -- after review by someone other than the proposer -> passes
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_record_review(cid, 'Accountant', 'Memo 2026-11-07');
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_assert_reviewed(''ins.commission_recognition'')') = 'on_insurer_settlement',
    'reviewed legal key passes');

  -- non-legal key never gated
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_assert_reviewed(''ins.commission_earning'')') = 'deferred_over_time',
    'non-legal key returns default without review');
end $$;
rollback;