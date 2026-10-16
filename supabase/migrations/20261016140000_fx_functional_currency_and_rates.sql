-- Phase A, A3 slice 1 (see docs/insurance-brokerage/ROADMAP.md): functional
-- currency per company and an approved exchange-rate table.
--
-- This slice only ADDS. No currency guard is removed, no posting changes, and no
-- company behaves differently: a company with no setting still has UGX as its
-- ledger currency, exactly as before.
--
-- What this adds:
--   * tenant_ledger_settings: one optional row per company holding its functional
--     (ledger) currency. No row means UGX. The setting cannot be written by
--     clients at all in this slice. It is not yet safe to switch a company, because
--     column defaults elsewhere still say 'UGX' and the guards still compare with
--     the ledger currency; a later slice enables the setter once those follow it.
--     Even for the owner, the value is locked once the company has posted a
--     journal entry (FX_FUNCTIONAL_LOCKED).
--   * fin_ledger_currency(tenant) now reads that setting instead of returning a
--     constant. It is still callable by the same roles and returns 'UGX' for every
--     existing company. Volatility changes from immutable to stable.
--   * fx_rates: dated rates, stated as functional-currency units per 1 unit of the
--     foreign currency. Entered as a draft, approved by a different person (the
--     enterer cannot approve), never edited once approved, and never deleted. A
--     wrong approved rate is corrected by a correcting entry, not by an edit.
--     Source is required. Future-dated rates are refused.
--   * platform_fx_rate / fx_get_rate: the most recent approved rate on or before a
--     date. The functional currency itself is rate 1 with no lookup. A missing
--     rate raises FX_RATE_MISSING. A rate older than the company's approved
--     fx.rate_max_age_days raises FX_RATE_STALE. If that parameter has not been
--     approved the lookup raises REG_PARAM_MISSING: there is deliberately no
--     default age.
--
-- Not in this slice: base amounts on journal lines, open items and settlements,
-- realised and unrealised gains and losses, revaluation, foreign bank accounts,
-- and removal of the currency guards.

-- =====================================================================
-- A. Functional currency setting
-- =====================================================================
create table if not exists public.tenant_ledger_settings (
  tenant_id            uuid primary key references public.tenants(id) on delete cascade,
  functional_currency  text not null,
  set_at               timestamptz not null default now(),
  constraint tenant_ledger_settings_currency_check check (functional_currency ~ '^[A-Z]{3}$')
);

comment on table public.tenant_ledger_settings is
  'Optional per-company ledger settings. No row means the functional currency is UGX. Not client-writable; locked once the company has posted a journal entry.';

create or replace function public.tenant_ledger_settings_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.tenant_id is distinct from old.tenant_id then
    raise exception 'FX_TENANT_IMMUTABLE: a ledger setting cannot move to another company';
  end if;
  if (tg_op = 'INSERT' or new.functional_currency is distinct from old.functional_currency)
     and exists (select 1 from journal_entries where tenant_id = new.tenant_id) then
    raise exception 'FX_FUNCTIONAL_LOCKED: this company has already posted journal entries; its functional currency can no longer change';
  end if;
  return new;
end;
$$;

revoke all on function public.tenant_ledger_settings_guard() from public, anon, authenticated;

drop trigger if exists trg_tenant_ledger_settings_guard on public.tenant_ledger_settings;
create trigger trg_tenant_ledger_settings_guard
  before insert or update on public.tenant_ledger_settings
  for each row execute function public.tenant_ledger_settings_guard();

alter table public.tenant_ledger_settings enable row level security;

drop policy if exists tenant_ledger_settings_select on public.tenant_ledger_settings;
create policy tenant_ledger_settings_select on public.tenant_ledger_settings
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member(null::text) or can_access_insurance())
  );

revoke all on public.tenant_ledger_settings from public, anon, authenticated;
grant select on public.tenant_ledger_settings to authenticated;

-- The ledger currency now comes from the setting. Same name, same signature and
-- same grants as before; 'UGX' when the company has no setting.
create or replace function public.fin_ledger_currency(p_tenant_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select coalesce(
    (select functional_currency from tenant_ledger_settings where tenant_id = p_tenant_id),
    'UGX'::text);
$$;

-- =====================================================================
-- B. Exchange rates
-- =====================================================================
create table if not exists public.fx_rates (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  currency         text not null,
  rate_date        date not null,
  rate             numeric(24,10) not null,
  source           text not null,
  status           text not null default 'draft',
  entered_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  approved_by      uuid,
  approved_at      timestamptz,
  withdrawn_reason text,
  updated_at       timestamptz not null default now(),
  constraint fx_rates_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint fx_rates_rate_check check (rate > 0),
  constraint fx_rates_source_check check (btrim(source) <> ''),
  constraint fx_rates_status_check check (status in ('draft', 'approved', 'withdrawn')),
  constraint fx_rates_approved_check
    check (status <> 'approved' or (approved_by is not null and approved_at is not null))
);

comment on table public.fx_rates is
  'Dated exchange rates per company: functional-currency units per 1 unit of the foreign currency. Entered as a draft, approved by a different person, never edited after approval.';
comment on column public.fx_rates.rate is
  'Functional-currency units per 1 unit of the foreign currency (for a UGX company and USD, the UGX price of one dollar).';
comment on column public.fx_rates.source is
  'Where the rate comes from (bank, central bank publication, agreed contract rate) with a reference. Required.';

-- One live row per company, currency and date. A withdrawn draft frees the slot.
create unique index if not exists fx_rates_live_idx
  on public.fx_rates (tenant_id, currency, rate_date)
  where status <> 'withdrawn';

create index if not exists fx_rates_lookup_idx
  on public.fx_rates (tenant_id, currency, status, rate_date desc);

create or replace function public.fx_rates_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_via boolean := coalesce(current_setting('fx.via_rpc', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'FX_RATE_STATUS: a new rate starts as a draft; approval is a separate step by a different person';
    end if;
    if new.approved_by is not null or new.approved_at is not null or new.withdrawn_reason is not null then
      raise exception 'FX_RATE_STATUS: approval and withdrawal fields cannot be set on a new draft';
    end if;
  else
    if new.tenant_id is distinct from old.tenant_id then
      raise exception 'FX_RATE_TENANT_IMMUTABLE: a rate cannot move to another company';
    end if;
    if old.status in ('approved', 'withdrawn') then
      raise exception 'FX_RATE_IMMUTABLE: an % rate cannot be changed; correct it with a correcting entry', old.status;
    end if;
    if new.status is distinct from old.status and not v_via then
      raise exception 'FX_RATE_STATUS_VIA_RPC: change status with fx_rate_approve or fx_rate_withdraw';
    end if;
  end if;

  if new.currency = fin_ledger_currency(new.tenant_id) then
    raise exception 'FX_RATE_CURRENCY: % is this company''s own functional currency; its rate is always 1', new.currency;
  end if;
  if new.rate_date > current_date then
    raise exception 'FX_RATE_FUTURE: a rate cannot be dated in the future (%)', new.rate_date;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.fx_rates_guard() from public, anon, authenticated;

drop trigger if exists trg_fx_rates_guard on public.fx_rates;
create trigger trg_fx_rates_guard
  before insert or update on public.fx_rates
  for each row execute function public.fx_rates_guard();

alter table public.fx_rates enable row level security;

drop policy if exists fx_rates_select on public.fx_rates;
create policy fx_rates_select on public.fx_rates
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member(null::text) or can_access_insurance())
  );

drop policy if exists fx_rates_insert on public.fx_rates;
create policy fx_rates_insert on public.fx_rates
  for insert with check (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text))
  );

drop policy if exists fx_rates_update on public.fx_rates;
create policy fx_rates_update on public.fx_rates
  for update using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text))
  )
  with check (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text))
  );

revoke all on public.fx_rates from public, anon, authenticated;
grant select, insert, update on public.fx_rates to authenticated;

-- =====================================================================
-- C. Approval and withdrawal
-- =====================================================================
create or replace function public.fx_rate_approve(p_id uuid)
returns public.fx_rates
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row fx_rates%rowtype;
  v_uid uuid := auth.uid();
begin
  select * into v_row from fx_rates
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'FX_RATE_NOT_FOUND: rate not found';
  end if;
  if not (is_tenant_admin() or is_finance_team_member('finance'::text)) then
    raise exception 'FX_RATE_FORBIDDEN: only a company admin or finance user can approve a rate' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'FX_RATE_NOT_DRAFT: only a draft can be approved (this one is %)', v_row.status;
  end if;
  if v_row.entered_by is not distinct from v_uid then
    raise exception 'FX_RATE_SELF_APPROVAL: the person who entered a rate cannot approve it';
  end if;

  perform set_config('fx.via_rpc', 'on', true);
  update fx_rates
     set status = 'approved', approved_by = v_uid, approved_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('fx.via_rpc', 'off', true);
  return v_row;
end;
$$;

create or replace function public.fx_rate_withdraw(p_id uuid, p_reason text)
returns public.fx_rates
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row    fx_rates%rowtype;
  v_uid    uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into v_row from fx_rates
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'FX_RATE_NOT_FOUND: rate not found';
  end if;
  if length(v_reason) < 5 then
    raise exception 'FX_RATE_REASON: give a reason of at least five characters';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'FX_RATE_NOT_DRAFT: only a draft can be withdrawn (this one is %)', v_row.status;
  end if;
  if not (is_tenant_admin() or v_row.entered_by is not distinct from v_uid) then
    raise exception 'FX_RATE_FORBIDDEN: only the person who entered a draft or a company admin can withdraw it' using errcode = '42501';
  end if;

  perform set_config('fx.via_rpc', 'on', true);
  update fx_rates
     set status = 'withdrawn', withdrawn_reason = v_reason
   where id = p_id
   returning * into v_row;
  perform set_config('fx.via_rpc', 'off', true);
  return v_row;
end;
$$;

revoke all on function public.fx_rate_approve(uuid) from public, anon;
revoke all on function public.fx_rate_withdraw(uuid, text) from public, anon;
grant execute on function public.fx_rate_approve(uuid) to authenticated;
grant execute on function public.fx_rate_withdraw(uuid, text) to authenticated;

-- =====================================================================
-- D. Resolution
-- =====================================================================
-- The most recent approved rate on or before p_on. The company's own functional
-- currency is rate 1 and needs no row (a synthetic row with a null id is returned).
create or replace function public.platform_fx_rate(p_tenant_id uuid, p_currency text, p_on date)
returns public.fx_rates
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v       fx_rates%rowtype;
  v_max   numeric;
begin
  if p_tenant_id is null or p_currency is null or p_on is null then
    raise exception 'FX_ARGUMENT: company, currency and date are required';
  end if;

  if p_currency = fin_ledger_currency(p_tenant_id) then
    v.tenant_id := p_tenant_id;
    v.currency  := p_currency;
    v.rate_date := p_on;
    v.rate      := 1;
    v.source    := 'functional currency';
    v.status    := 'approved';
    return v;
  end if;

  select * into v
  from fx_rates
  where tenant_id = p_tenant_id
    and currency = p_currency
    and status = 'approved'
    and rate_date <= p_on
  order by rate_date desc
  limit 1;

  if not found then
    raise exception 'FX_RATE_MISSING: no approved % rate on or before %', p_currency, p_on;
  end if;

  v_max := platform_reg_number(p_tenant_id, 'fx.rate_max_age_days', p_on);
  if (p_on - v.rate_date) > v_max then
    raise exception 'FX_RATE_STALE: the latest approved % rate is dated %, more than % days before %', p_currency, v.rate_date, v_max, p_on;
  end if;
  return v;
end;
$$;

revoke all on function public.platform_fx_rate(uuid, text, date) from public, anon, authenticated;

create or replace function public.fx_get_rate(p_currency text, p_on date default current_date)
returns public.fx_rates
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not (is_tenant_admin() or is_finance_team_member(null::text) or can_access_insurance()) then
    raise exception 'FX_RATE_FORBIDDEN: exchange rates are visible to company admins, finance and insurance users' using errcode = '42501';
  end if;
  return platform_fx_rate(get_my_tenant_id(), p_currency, p_on);
end;
$$;

revoke all on function public.fx_get_rate(text, date) from public, anon;
grant execute on function public.fx_get_rate(text, date) to authenticated;

-- =====================================================================
-- E. Suspended and read-only tenants
-- =====================================================================
select public.apply_tenant_read_only_guard();