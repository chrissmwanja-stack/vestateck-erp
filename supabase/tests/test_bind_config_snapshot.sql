-- Stage 3: bind snapshots the commission-recognition setting
-- (20261107235903_bind_config_snapshot.sql). One tx, ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as $$
begin if not coalesce(p_ok,false) then raise exception 'FAIL: %', p_msg; end if; end $$;
create function pg_temp.jwt(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role','authenticated')::text, true); $$;
create function pg_temp.scalar(p_sql text) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare v text; begin execute p_sql into v; return v; end $$;

create temp table pg_temp.b_ids as select gen_random_uuid() as ta, gen_random_uuid() as mgr, gen_random_uuid() as adm;
insert into tenants (id, name) select ta, 'Snap A' from pg_temp.b_ids;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated','authenticated','b-'||u.id||'@t.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}','{}',now(),now(),'',''
from (select mgr as id from pg_temp.b_ids union all select adm) u;
insert into app_users (id, tenant_id, name, email) select i.mgr, i.ta, 'Mgr','b-'||i.mgr||'@t.local' from pg_temp.b_ids i union all select i.adm, i.ta, 'Adm','b-'||i.adm||'@t.local' from pg_temp.b_ids i;
insert into staff_roles (tenant_id, user_id, module, role) select ta, mgr, 'insurance','manager' from pg_temp.b_ids union all select ta, adm, 'finance','admin' from pg_temp.b_ids;

do $$
declare i pg_temp.b_ids; pol uuid;
begin
  select * into i from pg_temp.b_ids;
  perform pg_temp.jwt(i.mgr);
  -- create + submit + approve + bind a minimal policy via RPCs where possible;
  -- fall back to direct insert with via_rpc for the snapshot check.
  perform pg_temp.assert(
    pg_temp.scalar(format('set local ins.via_rpc=''on''; insert into public.ins_policies (tenant_id, policy_no, status, inception_date, expiry_date, gross_premium, currency) values (%L, ''SNAP-1'', ''draft'', current_date, current_date+365, 1000, ''UGX'') returning id', i.ta)) is not null,
    'policy created');
  select id into pol from public.ins_policies where tenant_id = i.ta and policy_no = 'SNAP-1';
  perform pg_temp.jwt(i.adm);
  perform public.acct_setting_propose('ins.commission_recognition', 'on_insurer_settlement', current_date, 'default recognition treatment');
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_approve((select id from public.company_accounting_settings where setting_key='ins.commission_recognition' and status='draft' limit 1));
  set local ins.via_rpc = 'on';
  update public.ins_policies set status = 'active' where id = pol;
  perform pg_temp.assert(
    pg_temp.scalar(format('select accounting_config_snapshot->>''ins.commission_recognition'' from public.ins_policies where id = %L', pol)) = 'on_insurer_settlement',
    'bind snapshots the recognition setting');
end $$;
rollback;
