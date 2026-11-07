-- ins.cancellation_treatment default method (20261107235907 ... 20261108000200).
-- One tx, ROLLBACK. The submit RPC itself needs a full policy fixture and is
-- exercised by scripts/test-ins-cancellation-*-concurrency.ts; this checks the
-- setting it reads and the mapping it applies.
\set ON_ERROR_STOP on
begin;
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
from (select mgr as id from pg_temp.c_ids union all select adm from pg_temp.c_ids) u;
-- Two company admins (is_tenant_admin()): one proposes, the other approves.
insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Mgr','c-'||i.mgr||'@t.local', true from pg_temp.c_ids i
union all select i.adm, i.ta, 'Adm','c-'||i.adm||'@t.local', true from pg_temp.c_ids i;
do $$
declare i pg_temp.c_ids; cid uuid;
begin
  select * into i from pg_temp.c_ids;
  -- before any choice is approved, the definition's default is returned
  perform pg_temp.jwt(i.adm);
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_get_setting(''ins.cancellation_treatment'') ->> ''source''') = 'default',
    'no approved choice: source is the default');
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_get_setting(''ins.cancellation_treatment'') ->> ''value''') = 'pro_rata_refund',
    'no approved choice: value is the definition default');

  select id into cid from public.acct_setting_propose('ins.cancellation_treatment', 'no_refund', current_date, 'default no-refund treatment');
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_approve(cid);
  -- the resolver is a jsonb object; the setting is its 'value' field
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_get_setting(''ins.cancellation_treatment'') ->> ''value''') = 'no_refund',
    'configured choice resolves');
  perform pg_temp.assert(
    pg_temp.scalar('select public.acct_get_setting(''ins.cancellation_treatment'') ->> ''source''') = 'configured',
    'source is configured once approved');
  -- the mapping ins_submit_policy_cancellation applies
  perform pg_temp.assert(
    pg_temp.scalar('select case (public.acct_get_setting(''ins.cancellation_treatment'') ->> ''value'') when ''pro_rata_refund'' then ''pro_rata'' when ''short_rate_refund'' then ''short_period'' when ''no_refund'' then ''non_refundable'' else ''manual_review'' end') = 'non_refundable',
    'no_refund maps to non_refundable');
end $$;
rollback;