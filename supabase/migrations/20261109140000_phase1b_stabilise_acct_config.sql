-- =====================================================================
-- Phase 1b: finish stabilising the accounting configuration framework.
--
-- 1. implemented_values becomes explicit and enforced. Only two keys are
--    read by posting code today (ins.commission_recognition and
--    ins.cancellation_treatment). Every other key is catalogued but not
--    yet consumed, so only its default is marked implemented; selecting
--    anything else would record a choice nothing acts on. Widen a key's
--    implemented_values in the same migration that adds the code reading it.
-- 2. acct_assert_reviewed resolves through acct_get_setting (one resolver,
--    one return shape: the value as text) and pins pg_temp last.
-- 3. acct_setting_min_effective_date: the earliest date the guard will
--    accept for a new choice, so the UI can enforce it up front.
-- 4. Every public SECURITY DEFINER function gets pg_temp as the LAST
--    search_path entry. Without an explicit entry pg_temp is searched first.
-- =====================================================================

-- 1 -------------------------------------------------------------------
update public.accounting_setting_definitions
set implemented_values = array[default_value]
where cardinality(implemented_values) = 0;

alter table public.accounting_setting_definitions
  alter column implemented_values drop default;

alter table public.accounting_setting_definitions
  drop constraint if exists accounting_setting_definitions_implemented_check;
alter table public.accounting_setting_definitions
  add constraint accounting_setting_definitions_implemented_check
  check (cardinality(implemented_values) >= 1
         and implemented_values <@ allowed_values
         and default_value = any (implemented_values));

comment on column public.accounting_setting_definitions.implemented_values is
  'Subset of allowed_values that posting code actually acts on. Only these can be proposed. allowed_values may also list planned options, shown greyed out in the UI.';

-- 2 -------------------------------------------------------------------
create or replace function public.acct_assert_reviewed(p_key text, p_on date default current_date)
returns text
language plpgsql stable security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_legal boolean;
  v_res   jsonb;
begin
  if p_on is null then
    raise exception 'ACCT_SETTING_DATE_REQUIRED: a date is required';
  end if;
  select d.requires_legal_review into v_legal
    from public.accounting_setting_definitions d where d.key = p_key;
  if not found then
    raise exception 'ACCT_UNKNOWN_KEY: %', p_key;
  end if;

  -- single resolver: acct_get_setting returns an object; its 'value' is what callers want
  v_res := public.acct_get_setting(p_key, p_on);

  if coalesce(v_legal, false) then
    if v_res ->> 'source' <> 'configured' then
      raise exception 'ACCT_LEGAL_UNREVIEWED: % has no approved value in force; configure and review it first', p_key;
    end if;
    if v_res ->> 'review_status' <> 'reviewed' then
      raise exception 'ACCT_LEGAL_UNREVIEWED: % is approved but not compliance-reviewed', p_key;
    end if;
  end if;
  return v_res ->> 'value';
end $$;

comment on function public.acct_assert_reviewed(text, date) is
  'Returns the value (text) in force for p_key on p_on. Keys with requires_legal_review must have an approved AND reviewed value, else ACCT_LEGAL_UNREVIEWED. Other keys need no review and fall back to the default. Do not re-create from an older copy: test_acct_config_stabilisation pins its shape.';

revoke all on function public.acct_assert_reviewed(text, date) from public, anon;
grant execute on function public.acct_assert_reviewed(text, date) to authenticated;

-- 3 -------------------------------------------------------------------
-- Mirrors company_accounting_settings_guard: a new choice must be later than
-- the previous approved choice and than the latest posted journal entry.
create or replace function public.acct_setting_min_effective_date(p_key text)
returns date
language plpgsql stable security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_min    date := current_date;
  v_d      date;
begin
  if v_tenant is null then
    raise exception 'ACCT_SETTING_FORBIDDEN: no company in context' using errcode = '42501';
  end if;
  if not exists (select 1 from public.accounting_setting_definitions where key = p_key) then
    raise exception 'ACCT_SETTING_UNKNOWN: no accounting setting named %', p_key;
  end if;
  select max(effective_from) into v_d from public.company_accounting_settings
   where tenant_id = v_tenant and setting_key = p_key and status = 'approved';
  if v_d is not null then v_min := greatest(v_min, v_d + 1); end if;
  select max(entry_date) into v_d from public.journal_entries where tenant_id = v_tenant;
  if v_d is not null then v_min := greatest(v_min, v_d + 1); end if;
  return v_min;
end $$;

revoke all on function public.acct_setting_min_effective_date(text) from public, anon;
grant execute on function public.acct_setting_min_effective_date(text) to authenticated;

-- 4 -------------------------------------------------------------------
do $$
declare
  r record;
  v_path text;
  n integer := 0;
  skipped integer := 0;
begin
  for r in
    select p.oid::regprocedure::text as fn,
           (select substr(c, length('search_path=') + 1)
              from unnest(p.proconfig) c where c like 'search_path=%') as sp
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c
                      where c like 'search_path=%' and c like '%pg_temp')
  loop
    v_path := case when r.sp is null then 'pg_catalog, public, pg_temp' else r.sp || ', pg_temp' end;
    begin
      execute format('alter function %s set search_path = %s', r.fn, v_path);
      n := n + 1;
    exception when others then
      skipped := skipped + 1;
      raise notice 'could not pin %: %', r.fn, sqlerrm;
    end;
  end loop;
  raise notice 'pg_temp appended to search_path on % definer functions (% skipped)', n, skipped;
end $$;
