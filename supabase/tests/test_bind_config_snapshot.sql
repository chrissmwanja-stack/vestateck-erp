-- Stage 3: bind snapshots the commission-recognition setting
-- (20261107235903_bind_config_snapshot.sql, value fixed in 20261108000400).
-- One tx, ROLLBACK; fresh local stack with seed.sql applied.
--
-- A policy cannot be bound from a minimal fixture (client, insurer, product
-- line, certificate, approval and the bind columns are all required), and
-- seed.sql already binds three policies through the real RPCs. So this test
-- checks (1) the trigger is attached, (2) the bound seed policies carry the
-- snapshot with the bare setting value, and (3) the value the trigger
-- stores comes from acct_assert_reviewed, which resolves an approved setting.
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
from (select mgr as id from pg_temp.b_ids union all select adm from pg_temp.b_ids) u;
-- Two company admins (is_tenant_admin()): one proposes, the other approves.
insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Mgr','b-'||i.mgr||'@t.local', true from pg_temp.b_ids i
union all select i.adm, i.ta, 'Adm','b-'||i.adm||'@t.local', true from pg_temp.b_ids i;

-- (1) the trigger is attached to ins_policies
select pg_temp.assert(
  exists (select 1 from pg_trigger t
           where t.tgrelid = 'public.ins_policies'::regclass
             and t.tgname = 'ins_bind_config_snapshot' and not t.tgisinternal),
  'ins_bind_config_snapshot trigger is attached to ins_policies');

-- (2) policies bound by seed.sql carry the snapshot with the bare value
select pg_temp.assert(
  exists (select 1 from public.ins_policies
           where status = 'active'
             and accounting_config_snapshot->>'ins.commission_recognition' = 'on_insurer_settlement'
             and accounting_config_snapshot ? 'resolved_at'),
  'a bound policy carries the recognition snapshot as a bare value');
select pg_temp.assert(
  not exists (select 1 from public.ins_policies
               where accounting_config_snapshot->>'ins.commission_recognition' like '{%'),
  'no snapshot stores the whole setting object instead of its value');

-- (3) an approved setting is what acct_assert_reviewed hands the trigger
do $$
declare i pg_temp.b_ids; cid uuid;
begin
  select * into i from pg_temp.b_ids;
  perform pg_temp.jwt(i.adm);
  select id into cid from public.acct_setting_propose('ins.commission_recognition', 'on_insurer_settlement', current_date, 'default recognition treatment');
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_approve(cid);
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_assert_reviewed(''ins.commission_recognition'')') = 'on_insurer_settlement',
    'acct_assert_reviewed returns the approved recognition value');
end $$;
rollback;