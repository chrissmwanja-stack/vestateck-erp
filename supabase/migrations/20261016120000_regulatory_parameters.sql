-- Phase A, step A1 (see docs/insurance-brokerage/ROADMAP.md): regulatory
-- parameters held as data, never as constants in code.
--
-- Decision of 16 October 2026: no regulatory threshold, rate or deadline is
-- hard-coded. Stamp duty, levies, withholding rates, remittance deadlines,
-- premium credit periods, retention periods and approval limits live in this
-- table, with an effective date, a source reference and an approver, so a rule
-- can change on a date without a code release and every past posting can be
-- traced to the value in force when it was made.
--
-- What this adds (additive; no existing table or function is changed):
--   * regulatory_parameter_definitions: a platform catalogue of the KEYS that
--     may carry a value (name, category, value type, whether it can vary by
--     class). It carries no values at all. Written by migrations only.
--   * regulatory_parameters: tenant-scoped, effective-dated values.
--       - status: draft -> approved -> retired. Only approved rows are ever
--         used. A draft is a proposal and is invisible to resolution.
--       - Maker-checker: approval is a separate step done by a company admin
--         who is NOT the person who created the draft (REG_SELF_APPROVAL).
--       - An approved row is immutable. It can only be end-dated (shortened)
--         or retired, each with an audit event. A value change is a new row
--         from a new date, never an edit.
--       - Approved rows for the same tenant, key and class cannot overlap in
--         time (REG_OVERLAP), enforced under an advisory lock.
--       - Values are validated against the key's type: amounts need a
--         currency, percentages are 0 to 100, days and years are whole
--         numbers, and a class can only be set on keys that allow it.
--   * regulatory_parameter_events: append-only record of approvals, end-dating
--     and retirements. Written by the RPCs only.
--   * platform_reg_resolve / platform_reg_number: internal resolvers for other
--     RPCs. The most specific approved row wins (class beats no class). A
--     missing value fails loudly (REG_PARAM_MISSING); there is deliberately no
--     fallback value, because a silent default is a hard-coded rule.
--   * reg_get_parameter: client-callable lookup for the caller's own tenant.
--
-- Seed data: none. This migration inserts key definitions only. Values are
-- entered per tenant and approved by a company admin after the accountant or
-- compliance adviser confirms them. Nothing here has been verified as law.
--
-- No row is ever deleted (no DELETE grant or policy), so there is no delete
-- trigger either: tenant deletion cascades through the foreign keys.

-- =====================================================================
-- A. Key catalogue (platform level, no values, no tenant_id)
-- =====================================================================
create table if not exists public.regulatory_parameter_definitions (
  key            text primary key,
  category       text not null,
  description    text not null,
  value_type     text not null,
  class_scoped   boolean not null default false,
  created_at     timestamptz not null default now(),
  constraint regulatory_parameter_definitions_key_check
    check (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'),
  constraint regulatory_parameter_definitions_type_check
    check (value_type in ('amount', 'percent', 'days', 'years', 'number', 'text')),
  constraint regulatory_parameter_definitions_text_check
    check (btrim(category) <> '' and btrim(description) <> '')
);

comment on table public.regulatory_parameter_definitions is
  'Catalogue of regulatory and control parameter KEYS. Carries no values: values are tenant data in regulatory_parameters, entered and approved per company. Maintained by migrations.';

insert into public.regulatory_parameter_definitions (key, category, description, value_type, class_scoped) values
  ('remittance.deadline_working_days', 'remittance',
   'Working days allowed between receiving premium and remitting it to the insurer.', 'days', false),
  ('premium_credit.customer_days', 'credit',
   'Days a customer may take to pay a premium under the customer agreement.', 'days', true),
  ('premium_credit.insurer_days', 'credit',
   'Days of premium credit an insurer allows the brokerage before cover is affected.', 'days', true),
  ('stamp_duty.policy', 'stamp_duty',
   'Stamp duty charged on one policy, in the stated currency. Class may vary the amount.', 'amount', true),
  ('levy.training_percent', 'levy',
   'Insurance training levy as a percentage of gross premium.', 'percent', true),
  ('levy.authority_percent', 'levy',
   'Regulator levy as a percentage of gross premium, if one applies.', 'percent', true),
  ('tax.vat_standard_percent', 'tax',
   'Standard VAT rate, as a percentage.', 'percent', false),
  ('tax.wht_agent_commission_percent', 'tax',
   'Withholding tax rate on commission paid to an agent, as a percentage.', 'percent', false),
  ('tax.wht_broker_commission_percent', 'tax',
   'Withholding tax rate on commission an insurer pays the brokerage, as a percentage. Leave unset until the accountant confirms it applies.', 'percent', false),
  ('retention.accounting_years', 'retention',
   'Years accounting and audit records must be kept after the end of the financial year.', 'years', false),
  ('retention.policy_years', 'retention',
   'Years policy documents must be kept.', 'years', false),
  ('retention.claims_years', 'retention',
   'Years claim records must be kept.', 'years', false),
  ('retention.complaints_years', 'retention',
   'Years complaint records must be kept.', 'years', false),
  ('approval.limit.refund', 'controls',
   'Customer refund amount above which a second approver is required.', 'amount', false),
  ('approval.limit.cancellation', 'controls',
   'Cancellation value above which a second approver is required.', 'amount', false),
  ('approval.limit.endorsement', 'controls',
   'Endorsement premium change above which a second approver is required.', 'amount', false),
  ('approval.limit.remittance', 'controls',
   'Insurer remittance amount above which a second approver is required.', 'amount', false),
  ('approval.limit.policy_bind', 'controls',
   'Policy gross premium above which binding needs a second approver.', 'amount', false),
  ('approval.cumulative_window_days', 'controls',
   'Days over which smaller transactions are added together against an approval limit.', 'days', false),
  ('fx.rate_max_age_days', 'fx',
   'Maximum age in days of an exchange rate that may be used for a transaction.', 'days', false)
on conflict (key) do update
  set category     = excluded.category,
      description  = excluded.description,
      value_type   = excluded.value_type,
      class_scoped = excluded.class_scoped;

alter table public.regulatory_parameter_definitions enable row level security;

drop policy if exists regulatory_parameter_definitions_select on public.regulatory_parameter_definitions;
create policy regulatory_parameter_definitions_select on public.regulatory_parameter_definitions
  for select to authenticated using (true);

revoke all on public.regulatory_parameter_definitions from public, anon, authenticated;
grant select on public.regulatory_parameter_definitions to authenticated;

-- =====================================================================
-- B. Tenant parameters
-- =====================================================================
create table if not exists public.regulatory_parameters (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  parameter_key   text not null references public.regulatory_parameter_definitions(key),
  applies_to      text,
  value_num       numeric,
  value_text      text,
  currency        text,
  effective_from  date not null,
  effective_to    date,
  source_ref      text not null,
  status          text not null default 'draft',
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  approved_by     uuid,
  approved_at     timestamptz,
  retired_reason  text,
  updated_at      timestamptz not null default now(),
  constraint regulatory_parameters_status_check check (status in ('draft', 'approved', 'retired')),
  constraint regulatory_parameters_dates_check check (effective_to is null or effective_to > effective_from),
  constraint regulatory_parameters_currency_check check (currency is null or currency ~ '^[A-Z]{3}$'),
  constraint regulatory_parameters_source_check check (btrim(source_ref) <> ''),
  constraint regulatory_parameters_class_check check (applies_to is null or btrim(applies_to) <> ''),
  constraint regulatory_parameters_approved_check check (status <> 'approved' or (approved_by is not null and approved_at is not null)),
  constraint regulatory_parameters_value_present_check check (value_num is not null or value_text is not null)
);

comment on table public.regulatory_parameters is
  'Tenant values for the keys in regulatory_parameter_definitions. Effective-dated, source-referenced, approved by a second person. Approved rows are immutable; change a value by adding a new row from a new date.';
comment on column public.regulatory_parameters.source_ref is
  'Where the value comes from: statute section, circular, tax ruling, accountant or adviser name and date. Required. Prefix with UNVERIFIED if not yet confirmed.';
comment on column public.regulatory_parameters.effective_to is
  'Exclusive end date. NULL means open-ended.';

create index if not exists regulatory_parameters_lookup_idx
  on public.regulatory_parameters (tenant_id, parameter_key, status, effective_from);

create table if not exists public.regulatory_parameter_events (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  parameter_id  uuid not null references public.regulatory_parameters(id) on delete cascade,
  event         text not null,
  actor         uuid,
  detail        text,
  created_at    timestamptz not null default now(),
  constraint regulatory_parameter_events_event_check check (event in ('approved', 'ended', 'retired'))
);

create index if not exists regulatory_parameter_events_param_idx
  on public.regulatory_parameter_events (parameter_id, created_at);

-- =====================================================================
-- C. Guard trigger
-- =====================================================================
create or replace function public.regulatory_parameters_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_def regulatory_parameter_definitions%rowtype;
  v_via boolean := coalesce(current_setting('reg.via_rpc', true), '') = 'on';
begin
  select * into v_def from regulatory_parameter_definitions where key = new.parameter_key;
  if not found then
    raise exception 'REG_UNKNOWN_KEY: % is not a known parameter key', new.parameter_key;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'REG_STATUS: a new parameter starts as a draft; approval is a separate step by a different person';
    end if;
    if new.approved_by is not null or new.approved_at is not null or new.retired_reason is not null then
      raise exception 'REG_STATUS: approval and retirement fields cannot be set on a new draft';
    end if;
  else
    if new.tenant_id is distinct from old.tenant_id then
      raise exception 'REG_TENANT_IMMUTABLE: a parameter cannot move to another company';
    end if;
    if new.parameter_key is distinct from old.parameter_key then
      raise exception 'REG_KEY_IMMUTABLE: the key cannot change; retire this row and add a new one';
    end if;
    if old.status = 'retired' then
      raise exception 'REG_RETIRED_IMMUTABLE: a retired parameter cannot be changed';
    end if;
    if new.status is distinct from old.status and not v_via then
      raise exception 'REG_STATUS_VIA_RPC: change status with reg_approve_parameter or reg_retire_parameter';
    end if;

    if old.status = 'approved' then
      if not v_via then
        raise exception 'REG_APPROVED_IMMUTABLE: an approved value cannot be edited; end-date it with reg_end_parameter and add a new row';
      end if;
      -- Through the RPCs only status, effective_to and retired_reason may move.
      if new.value_num is distinct from old.value_num
         or new.value_text is distinct from old.value_text
         or new.currency is distinct from old.currency
         or new.applies_to is distinct from old.applies_to
         or new.effective_from is distinct from old.effective_from
         or new.source_ref is distinct from old.source_ref
         or new.created_by is distinct from old.created_by
         or new.approved_by is distinct from old.approved_by
         or new.approved_at is distinct from old.approved_at then
        raise exception 'REG_APPROVED_IMMUTABLE: only the end date and status of an approved value can change';
      end if;
      if new.effective_to is distinct from old.effective_to
         and (new.effective_to is null
              or (old.effective_to is not null and new.effective_to >= old.effective_to)) then
        raise exception 'REG_END_DATE: an approved value can only be shortened, never extended';
      end if;
      return new;
    end if;
  end if;

  -- Value rules, for every new draft and every edit of a draft.
  if new.applies_to is not null and not v_def.class_scoped then
    raise exception 'REG_CLASS_NOT_ALLOWED: % does not vary by class', new.parameter_key;
  end if;

  if v_def.value_type = 'text' then
    if new.value_text is null or btrim(new.value_text) = '' or new.value_num is not null or new.currency is not null then
      raise exception 'REG_VALUE_INVALID: % takes a text value only', new.parameter_key;
    end if;
  else
    if new.value_num is null or new.value_text is not null then
      raise exception 'REG_VALUE_INVALID: % takes a number only', new.parameter_key;
    end if;
    if new.value_num < 0 then
      raise exception 'REG_VALUE_INVALID: % cannot be negative', new.parameter_key;
    end if;
    if v_def.value_type = 'amount' then
      if new.currency is null then
        raise exception 'REG_VALUE_INVALID: % is an amount and needs a currency', new.parameter_key;
      end if;
    else
      if new.currency is not null then
        raise exception 'REG_VALUE_INVALID: % is not an amount and cannot carry a currency', new.parameter_key;
      end if;
      if v_def.value_type = 'percent' and new.value_num > 100 then
        raise exception 'REG_VALUE_INVALID: % is a percentage and cannot exceed 100', new.parameter_key;
      end if;
      if v_def.value_type in ('days', 'years') and new.value_num <> trunc(new.value_num) then
        raise exception 'REG_VALUE_INVALID: % must be a whole number of %', new.parameter_key, v_def.value_type;
      end if;
    end if;
  end if;

  -- Approval: no overlap with another approved row for the same key and class.
  if new.status = 'approved' and tg_op = 'UPDATE' and old.status <> 'approved' then
    perform pg_advisory_xact_lock(hashtextextended(new.tenant_id::text || ':' || new.parameter_key, 0));
    if exists (
      select 1
      from regulatory_parameters o
      where o.tenant_id = new.tenant_id
        and o.parameter_key = new.parameter_key
        and o.status = 'approved'
        and coalesce(o.applies_to, '') = coalesce(new.applies_to, '')
        and o.id <> new.id
        and new.effective_from < coalesce(o.effective_to, 'infinity'::date)
        and o.effective_from < coalesce(new.effective_to, 'infinity'::date)
    ) then
      raise exception 'REG_OVERLAP: another approved value for % already covers part of this period; end-date it first', new.parameter_key;
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.regulatory_parameters_guard() from public, anon, authenticated;

drop trigger if exists trg_regulatory_parameters_guard on public.regulatory_parameters;
create trigger trg_regulatory_parameters_guard
  before insert or update on public.regulatory_parameters
  for each row execute function public.regulatory_parameters_guard();

-- =====================================================================
-- D. RLS and grants
-- =====================================================================
alter table public.regulatory_parameters enable row level security;
alter table public.regulatory_parameter_events enable row level security;

drop policy if exists regulatory_parameters_select on public.regulatory_parameters;
create policy regulatory_parameters_select on public.regulatory_parameters
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_company_admin() or is_finance_team_member(null::text) or can_access_insurance())
  );

drop policy if exists regulatory_parameters_insert on public.regulatory_parameters;
create policy regulatory_parameters_insert on public.regulatory_parameters
  for insert with check (
    tenant_id = get_my_tenant_id()
    and (is_company_admin() or is_finance_team_member('finance'::text))
  );

drop policy if exists regulatory_parameters_update on public.regulatory_parameters;
create policy regulatory_parameters_update on public.regulatory_parameters
  for update using (
    tenant_id = get_my_tenant_id()
    and (is_company_admin() or is_finance_team_member('finance'::text))
  )
  with check (
    tenant_id = get_my_tenant_id()
    and (is_company_admin() or is_finance_team_member('finance'::text))
  );

drop policy if exists regulatory_parameter_events_select on public.regulatory_parameter_events;
create policy regulatory_parameter_events_select on public.regulatory_parameter_events
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_company_admin() or is_finance_team_member(null::text) or can_access_insurance())
  );

revoke all on public.regulatory_parameters, public.regulatory_parameter_events from public, anon, authenticated;
grant select, insert, update on public.regulatory_parameters to authenticated;
grant select on public.regulatory_parameter_events to authenticated;

-- =====================================================================
-- E. Resolution (internal) and lookup (client)
-- =====================================================================
-- Most specific approved value wins. A missing value raises: there is no
-- default, because a default is a hard-coded rule by another name.
create or replace function public.platform_reg_resolve(
  p_tenant_id uuid,
  p_key       text,
  p_on        date,
  p_class     text default null
)
returns public.regulatory_parameters
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v regulatory_parameters%rowtype;
begin
  if p_tenant_id is null or p_on is null then
    raise exception 'REG_ARGUMENT: tenant and date are required';
  end if;
  if not exists (select 1 from regulatory_parameter_definitions where key = p_key) then
    raise exception 'REG_UNKNOWN_KEY: % is not a known parameter key', p_key;
  end if;

  select * into v
  from regulatory_parameters
  where tenant_id = p_tenant_id
    and parameter_key = p_key
    and status = 'approved'
    and effective_from <= p_on
    and (effective_to is null or p_on < effective_to)
    and (applies_to is null or applies_to = p_class)
  order by (applies_to is not null) desc
  limit 1;

  if not found then
    raise exception 'REG_PARAM_MISSING: no approved value for % on % (class %) for this company; add one under regulatory parameters and have a company admin approve it',
      p_key, p_on, coalesce(p_class, 'none');
  end if;
  return v;
end;
$$;

create or replace function public.platform_reg_number(
  p_tenant_id uuid,
  p_key       text,
  p_on        date,
  p_class     text default null
)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v regulatory_parameters%rowtype;
begin
  v := platform_reg_resolve(p_tenant_id, p_key, p_on, p_class);
  if v.value_num is null then
    raise exception 'REG_PARAM_NOT_NUMERIC: % holds a text value', p_key;
  end if;
  return v.value_num;
end;
$$;

revoke all on function public.platform_reg_resolve(uuid, text, date, text) from public, anon, authenticated;
revoke all on function public.platform_reg_number(uuid, text, date, text) from public, anon, authenticated;

create or replace function public.reg_get_parameter(
  p_key   text,
  p_on    date default current_date,
  p_class text default null
)
returns public.regulatory_parameters
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not (is_company_admin() or is_finance_team_member(null::text) or can_access_insurance()) then
    raise exception 'REG_FORBIDDEN: regulatory parameters are visible to company admins, finance and insurance users' using errcode = '42501';
  end if;
  return platform_reg_resolve(get_my_tenant_id(), p_key, p_on, p_class);
end;
$$;

revoke all on function public.reg_get_parameter(text, date, text) from public, anon;
grant execute on function public.reg_get_parameter(text, date, text) to authenticated;

-- =====================================================================
-- F. Approval, end-dating, retirement
-- =====================================================================
create or replace function public.reg_approve_parameter(p_id uuid)
returns public.regulatory_parameters
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row regulatory_parameters%rowtype;
  v_uid uuid := auth.uid();
begin
  select * into v_row from regulatory_parameters
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'REG_NOT_FOUND: parameter not found';
  end if;
  if not is_company_admin() then
    raise exception 'REG_FORBIDDEN: only a company admin can approve a regulatory parameter' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'REG_NOT_DRAFT: only a draft can be approved (this one is %)', v_row.status;
  end if;
  if v_row.created_by is not distinct from v_uid then
    raise exception 'REG_SELF_APPROVAL: the person who proposed a value cannot approve it';
  end if;

  perform set_config('reg.via_rpc', 'on', true);
  update regulatory_parameters
     set status = 'approved', approved_by = v_uid, approved_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('reg.via_rpc', 'off', true);

  insert into regulatory_parameter_events (tenant_id, parameter_id, event, actor, detail)
  values (v_row.tenant_id, v_row.id, 'approved', v_uid, v_row.source_ref);
  return v_row;
end;
$$;

create or replace function public.reg_end_parameter(p_id uuid, p_effective_to date)
returns public.regulatory_parameters
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row regulatory_parameters%rowtype;
  v_uid uuid := auth.uid();
begin
  select * into v_row from regulatory_parameters
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'REG_NOT_FOUND: parameter not found';
  end if;
  if not is_company_admin() then
    raise exception 'REG_FORBIDDEN: only a company admin can end-date a regulatory parameter' using errcode = '42501';
  end if;
  if v_row.status <> 'approved' then
    raise exception 'REG_NOT_APPROVED: only an approved value can be end-dated (this one is %)', v_row.status;
  end if;
  if p_effective_to is null or p_effective_to <= v_row.effective_from then
    raise exception 'REG_END_DATE: the end date must be after the start date (%)', v_row.effective_from;
  end if;
  if v_row.effective_to is not null and p_effective_to >= v_row.effective_to then
    raise exception 'REG_END_DATE: the end date must be earlier than the current end date (%)', v_row.effective_to;
  end if;

  perform set_config('reg.via_rpc', 'on', true);
  update regulatory_parameters set effective_to = p_effective_to where id = p_id returning * into v_row;
  perform set_config('reg.via_rpc', 'off', true);

  insert into regulatory_parameter_events (tenant_id, parameter_id, event, actor, detail)
  values (v_row.tenant_id, v_row.id, 'ended', v_uid, 'effective to ' || p_effective_to::text);
  return v_row;
end;
$$;

create or replace function public.reg_retire_parameter(p_id uuid, p_reason text)
returns public.regulatory_parameters
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row regulatory_parameters%rowtype;
  v_uid uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into v_row from regulatory_parameters
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'REG_NOT_FOUND: parameter not found';
  end if;
  if length(v_reason) < 5 then
    raise exception 'REG_REASON: give a reason of at least five characters';
  end if;
  if v_row.status = 'retired' then
    raise exception 'REG_RETIRED_IMMUTABLE: already retired';
  end if;
  if v_row.status = 'approved' and not is_company_admin() then
    raise exception 'REG_FORBIDDEN: only a company admin can retire an approved value' using errcode = '42501';
  end if;
  if v_row.status = 'draft'
     and not (is_company_admin() or v_row.created_by is not distinct from v_uid) then
    raise exception 'REG_FORBIDDEN: only the proposer or a company admin can withdraw a draft' using errcode = '42501';
  end if;

  perform set_config('reg.via_rpc', 'on', true);
  update regulatory_parameters
     set status = 'retired', retired_reason = v_reason
   where id = p_id
   returning * into v_row;
  perform set_config('reg.via_rpc', 'off', true);

  insert into regulatory_parameter_events (tenant_id, parameter_id, event, actor, detail)
  values (v_row.tenant_id, v_row.id, 'retired', v_uid, v_reason);
  return v_row;
end;
$$;

revoke all on function public.reg_approve_parameter(uuid) from public, anon;
revoke all on function public.reg_end_parameter(uuid, date) from public, anon;
revoke all on function public.reg_retire_parameter(uuid, text) from public, anon;
grant execute on function public.reg_approve_parameter(uuid) to authenticated;
grant execute on function public.reg_end_parameter(uuid, date) to authenticated;
grant execute on function public.reg_retire_parameter(uuid, text) to authenticated;

-- =====================================================================
-- G. Suspended and read-only tenants
-- =====================================================================
select public.apply_tenant_read_only_guard();