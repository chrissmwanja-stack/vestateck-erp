-- Phase 1b: acct config stabilisation (20261109140000). One tx, ROLLBACK.
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
insert into tenants (id, name) select ta, 'Stab A' from pg_temp.g_ids;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated','authenticated','g-'||u.id||'@t.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}','{}',now(),now(),'',''
from (select mgr as id from pg_temp.g_ids union all select adm from pg_temp.g_ids) u;
-- Two company admins (is_tenant_admin()): one proposes, the other approves and reviews.
insert into app_users (id, tenant_id, name, email, is_company_admin) select i.mgr, i.ta, 'Mgr','g-'||i.mgr||'@t.local', true from pg_temp.g_ids i union all select i.adm, i.ta, 'Adm','g-'||i.adm||'@t.local', true from pg_temp.g_ids i;

do $$
declare i pg_temp.g_ids; cid uuid; v text; bad text;
begin
  select * into i from pg_temp.g_ids;

  -- (1) definitions: implemented is non-empty, within allowed, and holds the default
  perform pg_temp.assert(not exists (
    select 1 from public.accounting_setting_definitions d
    where cardinality(d.implemented_values) = 0
       or not (d.implemented_values <@ d.allowed_values)
       or not (d.default_value = any (d.implemented_values))), 'definitions: implemented_values consistent');
  perform pg_temp.assert(exists (select 1 from public.accounting_setting_definitions
    where key = 'ins.commission_recognition' and 'at_placement' = any (allowed_values)
      and not ('at_placement' = any (implemented_values))), 'planned recognition options listed but not implemented');

  -- (2) a planned value cannot be proposed
  perform pg_temp.jwt(i.adm);
  perform pg_temp.expect_error(
    $q$select public.acct_setting_propose('ins.commission_recognition', 'at_placement', current_date, 'planned option attempt')$q$,
    'ACCT_SETTING_VALUE_NOT_ALLOWED', 'planned value rejected');

  -- (3) minimum effective date: today for a fresh company, then the day after an approved choice
  perform pg_temp.assert(pg_temp.scalar($q$select public.acct_setting_min_effective_date('ins.commission_earning')$q$)::date = current_date,
    'min effective date is today with no history');
  perform pg_temp.expect_error($q$select public.acct_setting_min_effective_date('no.such.key')$q$, 'ACCT_SETTING_UNKNOWN', 'min date unknown key');
  perform public.acct_setting_propose('ins.commission_earning', 'deferred_over_time', current_date, 'stabilisation test choice');
  select id into cid from public.company_accounting_settings where setting_key = 'ins.commission_earning' and status = 'draft' limit 1;
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_approve(cid);
  perform pg_temp.assert(pg_temp.scalar($q$select public.acct_setting_min_effective_date('ins.commission_earning')$q$)::date = current_date + 1,
    'min effective date moves past the approved choice');

  -- (4) acct_assert_reviewed contract
  v := pg_temp.scalar($q$select public.acct_assert_reviewed('ins.commission_earning')$q$);
  perform pg_temp.assert(v = 'deferred_over_time' and v not like '{%', 'assert_reviewed returns the bare value, not the resolver object');
  perform pg_temp.expect_error($q$select public.acct_assert_reviewed('no.such.key')$q$, 'ACCT_UNKNOWN_KEY', 'assert_reviewed unknown key');
  perform pg_temp.expect_error($q$select public.acct_assert_reviewed('ins.insurer_remittance_basis')$q$, 'ACCT_LEGAL_UNREVIEWED', 'legal key with nothing configured');
  perform pg_temp.jwt(i.adm);
  perform public.acct_setting_propose('ins.agent_commission_taxable', 'taxable', current_date, 'stabilisation legal key');
  select id into cid from public.company_accounting_settings where setting_key = 'ins.agent_commission_taxable' and status = 'draft' limit 1;
  perform pg_temp.jwt(i.mgr);
  perform public.acct_setting_approve(cid);
  perform pg_temp.expect_error($q$select public.acct_assert_reviewed('ins.agent_commission_taxable')$q$, 'ACCT_LEGAL_UNREVIEWED', 'legal key approved but unreviewed');
  perform public.acct_setting_record_review(cid, 'Accountant', 'Memo stabilisation');
  perform pg_temp.assert(pg_temp.scalar($q$select public.acct_assert_reviewed('ins.agent_commission_taxable')$q$) = 'taxable', 'legal key reviewed passes');

  -- (5) function shape is pinned so a later migration cannot silently re-create an old copy
  perform pg_temp.assert(
    (select prosrc like '%acct_get_setting%' and prosrc like '%->> ''value''%' and prosrc not like '%from public.company_accounting_settings%'
       from pg_proc where oid = 'public.acct_assert_reviewed(text,date)'::regprocedure),
    'acct_assert_reviewed resolves through acct_get_setting and returns ->> value');
  perform pg_temp.assert(
    (select coalesce(bool_or(c like 'search_path=%pg_temp'), false) from pg_proc p, unnest(p.proconfig) c
      where p.oid = 'public.acct_assert_reviewed(text,date)'::regprocedure),
    'acct_assert_reviewed pins pg_temp last');

  -- (6) no public SECURITY DEFINER function without a pinned search_path ending in pg_temp
  select string_agg(p.oid::regprocedure::text, ', ') into bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prosecdef
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c
                     where c like 'search_path=%' and c like '%pg_temp');
  perform pg_temp.assert(bad is null, 'SECURITY DEFINER functions without search_path ... pg_temp: ' || coalesce(left(bad, 600), ''));
end $$;
rollback;
