-- ins.cancellation_treatment default method (20261107235907). One tx, ROLLBACK.
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
create temp table pg_temp.c_ids as select gen_random_uuid() as ta, gen_random_uuid() as mgr, gen_random_uuid() as adm;
insert into tenants (id, name) select ta, 'CancelCfg A' from pg_temp.c_ids;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated','authenticated','c-'||u.id||'@t.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}','{}',now(),now(),'',''
from (select mgr as id from pg_temp.c_ids union all select adm) u;
insert into app_users (id, tenant_id, name, email) select i.mgr, i.ta, 'Mgr','c-'||i.mgr||'@t.local' from pg_temp.c_ids i union all select i.adm, i.ta, 'Adm','c-'||i.adm||'@t.local' from pg_temp.c_ids i;
insert into staff_roles (tenant_id, user_id, module, role) select ta, mgr, 'insurance','manager' from pg_temp.c_ids union all select ta, adm, 'finance','admin' from pg_temp.c_ids;
do $$
declare i pg_temp.c_ids; cid uuid;
begin
  select * into i from pg_temp.c_ids;
  perform pg_temp.jwt(i.adm);
  perform public.acct_setting_propose('ins.cancellation_treatment', 'no_refund', current_date, 'default no-refund treatment');
  select id into cid from public.company_accounting_settings where setting_key='ins.cancellation_treatment' and status='draft' limit 1;
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_approve(cid);
  -- resolver returns the configured default
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_get_setting(''ins.cancellation_treatment'')') = 'no_refund',
    'config default resolves');
  -- mapping helper: emulate the submit RPC's mapping
  perform pg_temp.assert(
    pg_temp.scalar('select case public.acct_get_setting(''ins.cancellation_treatment'') when ''no_refund'' then ''non_refundable'' end') = 'non_refundable',
    'no_refund maps to non_refundable');
end $$;
rollback;
