-- =====================================================================
-- Company accounting settings, stage 1 (framework only).
--
-- Why: where legitimate accounting alternatives exist, each company should
-- choose its own treatment, with the choice dated, approved by a second
-- person, attributed and auditable. The platform provides the mechanism;
-- the company (and its own accountant) owns the policy choice. This is NOT
-- a statement that any option is legally or professionally acceptable.
--
-- What this adds:
--   accounting_setting_definitions   global registry: which settings exist,
--                                    which values are IMPLEMENTED (allowed)
--                                    and the conservative default. Only a
--                                    migration can add a setting or a value,
--                                    so a company can never select a
--                                    treatment the code cannot post.
--   company_accounting_settings      a company's choice for one setting,
--                                    effective-dated, maker-checker, and
--                                    immutable once approved.
--   company_accounting_setting_events append-only audit log (who, what, when).
--
-- Relationship to accounting_policies (20261016130000): that table versions
-- the company's accounting policy as a whole and stamps a version on every
-- posting. This table records individual treatment choices. Neither changes
-- the other. A setting is not yet wired into any posting: when one is,
-- that migration adds its own per-transaction snapshot. Until then the
-- value in force on any date is reproducible from the approved rows.
--
-- Review status: 'unreviewed' (default) or 'reviewed'. Reviewed means a
-- company admin recorded the name and reference of the accountant or adviser
-- who reviewed the choice. It is the company's attestation, not Vestateck's.
--
-- Writes are RPC-only (no DML grants, select policy only). Additive: no
-- existing function or table is changed.
-- =====================================================================

-- =====================================================================
-- A. Definitions (global reference data, written by migrations only)
-- =====================================================================
create table if not exists public.accounting_setting_definitions (
  key            text primary key,
  label          text not null,
  description    text not null,
  allowed_values text[] not null,
  default_value  text not null,
  created_at     timestamptz not null default now(),
  constraint accounting_setting_definitions_key_check check (btrim(key) <> ''),
  constraint accounting_setting_definitions_text_check check (btrim(label) <> '' and btrim(description) <> ''),
  constraint accounting_setting_definitions_allowed_check check (cardinality(allowed_values) >= 1),
  constraint accounting_setting_definitions_default_check check (default_value = any (allowed_values))
);

comment on table public.accounting_setting_definitions is
  'Registry of company accounting settings. allowed_values lists only treatments the code actually implements; a new value is added by a migration together with the posting code that supports it.';

alter table public.accounting_setting_definitions enable row level security;

drop policy if exists accounting_setting_definitions_select on public.accounting_setting_definitions;
create policy accounting_setting_definitions_select on public.accounting_setting_definitions
  for select to authenticated using (true);

revoke all on public.accounting_setting_definitions from public, anon, authenticated;
grant select on public.accounting_setting_definitions to authenticated;

-- The only treatment implemented today (docs/insurance-brokerage/ROADMAP.md,
-- Option A in IN_FORCE_IMPORT.md). Time-apportioned recognition is Phase B and
-- is added as a second value by the migration that builds it.
insert into public.accounting_setting_definitions (key, label, description, allowed_values, default_value)
values (
  'ins.commission_recognition',
  'Commission recognition (insurance brokerage)',
  'When brokerage commission is recognised as income. on_insurer_settlement: credited to unearned commission at bind and recognised when a posted settlement fully pays the insurer''s net item for the policy.',
  array['on_insurer_settlement'],
  'on_insurer_settlement'
)
on conflict (key) do nothing;

-- =====================================================================
-- B. A company's choices
-- =====================================================================
create table if not exists public.company_accounting_settings (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  setting_key      text not null references public.accounting_setting_definitions(key),
  value            text not null,
  effective_from   date not null,
  rationale        text not null,
  status           text not null default 'draft',
  review_status    text not null default 'unreviewed',
  reviewer_name    text,
  review_reference text,
  reviewed_by      uuid,
  reviewed_at      timestamptz,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  approved_by      uuid,
  approved_at      timestamptz,
  withdrawn_reason text,
  updated_at       timestamptz not null default now(),
  constraint company_accounting_settings_id_tenant_key unique (tenant_id, id),
  constraint company_accounting_settings_status_check check (status in ('draft', 'approved', 'withdrawn')),
  constraint company_accounting_settings_review_check check (review_status in ('unreviewed', 'reviewed')),
  constraint company_accounting_settings_rationale_check check (length(btrim(rationale)) >= 10),
  constraint company_accounting_settings_approved_check
    check (status <> 'approved' or (approved_by is not null and approved_at is not null)),
  constraint company_accounting_settings_reviewed_check
    check (review_status <> 'reviewed' or (
      length(btrim(coalesce(reviewer_name, ''))) >= 2
      and length(btrim(coalesce(review_reference, ''))) >= 2
      and reviewed_by is not null and reviewed_at is not null))
);

-- One live row per setting and effective date (a withdrawn draft frees it).
create unique index if not exists company_accounting_settings_live_idx
  on public.company_accounting_settings (tenant_id, setting_key, effective_from)
  where status <> 'withdrawn';

create index if not exists company_accounting_settings_lookup_idx
  on public.company_accounting_settings (tenant_id, setting_key, status, effective_from);

comment on table public.company_accounting_settings is
  'A company''s chosen treatment for one accounting setting. Proposed as a draft, approved by a different company admin, then immutable. The value in force on a date is the approved row with the latest effective_from on or before it; otherwise the definition''s default.';
comment on column public.company_accounting_settings.rationale is
  'Why the company chose this treatment (at least 10 characters). Required so the choice is explainable later.';
comment on column public.company_accounting_settings.review_status is
  'unreviewed (default) or reviewed. Reviewed is the company''s own attestation that a named accountant or adviser reviewed this choice; it is never a Vestateck approval.';

-- =====================================================================
-- C. Audit log (append-only)
-- =====================================================================
create table if not exists public.company_accounting_setting_events (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  setting_id  uuid not null,
  setting_key text not null,
  event       text not null,
  actor       uuid default auth.uid(),
  at          timestamptz not null default now(),
  detail      jsonb not null default '{}'::jsonb,
  constraint company_accounting_setting_events_setting_fk
    foreign key (tenant_id, setting_id) references public.company_accounting_settings (tenant_id, id) on delete cascade,
  constraint company_accounting_setting_events_event_check
    check (event in ('proposed', 'approved', 'withdrawn', 'reviewed'))
);

create index if not exists company_accounting_setting_events_idx
  on public.company_accounting_setting_events (tenant_id, setting_id, at);

create or replace function public.company_accounting_setting_events_no_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'ACCT_SETTING_LOG_APPEND_ONLY: the audit log cannot be changed';
end;
$$;

revoke all on function public.company_accounting_setting_events_no_update() from public, anon, authenticated;

drop trigger if exists trg_company_accounting_setting_events_no_update on public.company_accounting_setting_events;
create trigger trg_company_accounting_setting_events_no_update
  before update on public.company_accounting_setting_events
  for each row execute function public.company_accounting_setting_events_no_update();

-- =====================================================================
-- D. Guard and audit triggers
-- =====================================================================
create or replace function public.company_accounting_settings_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_via        boolean := coalesce(current_setting('acct.via_rpc', true), '') = 'on';
  v_allowed    text[];
  v_prev_from  date;
  v_latest_je  date;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.review_status <> 'unreviewed' then
      raise exception 'ACCT_SETTING_STATUS: a new setting choice starts as an unreviewed draft';
    end if;
    if new.approved_by is not null or new.approved_at is not null or new.withdrawn_reason is not null
       or new.reviewer_name is not null or new.review_reference is not null
       or new.reviewed_by is not null or new.reviewed_at is not null then
      raise exception 'ACCT_SETTING_STATUS: approval, withdrawal and review fields cannot be set on a new draft';
    end if;

    select allowed_values into v_allowed
      from accounting_setting_definitions where key = new.setting_key;
    if not found then
      raise exception 'ACCT_SETTING_UNKNOWN: no accounting setting named %', new.setting_key;
    end if;
    if not (new.value = any (v_allowed)) then
      raise exception 'ACCT_SETTING_VALUE_NOT_ALLOWED: % is not an implemented option for % (allowed: %)',
        new.value, new.setting_key, array_to_string(v_allowed, ', ');
    end if;
  else
    if not v_via then
      raise exception 'ACCT_SETTING_VIA_RPC: change a setting through the acct_setting_* functions';
    end if;
    if new.tenant_id is distinct from old.tenant_id
       or new.setting_key is distinct from old.setting_key
       or new.value is distinct from old.value
       or new.effective_from is distinct from old.effective_from
       or new.rationale is distinct from old.rationale
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'ACCT_SETTING_IMMUTABLE: what was chosen, when it takes effect and why cannot change; propose a new choice instead';
    end if;
    if old.status = 'withdrawn' then
      raise exception 'ACCT_SETTING_IMMUTABLE: a withdrawn choice cannot be changed';
    end if;
    if old.status = 'approved' and new.status is distinct from old.status then
      raise exception 'ACCT_SETTING_IMMUTABLE: an approved choice cannot be withdrawn or changed; propose a new choice instead';
    end if;
    if old.review_status = 'reviewed' and (
         new.review_status is distinct from old.review_status
         or new.reviewer_name is distinct from old.reviewer_name
         or new.review_reference is distinct from old.review_reference
         or new.reviewed_by is distinct from old.reviewed_by
         or new.reviewed_at is distinct from old.reviewed_at) then
      raise exception 'ACCT_SETTING_IMMUTABLE: a recorded review cannot be changed';
    end if;

    if new.status = 'approved' and old.status = 'draft' then
      perform pg_advisory_xact_lock(hashtextextended('acct_setting:' || new.tenant_id::text || ':' || new.setting_key, 0));

      select max(effective_from) into v_prev_from
        from company_accounting_settings
       where tenant_id = new.tenant_id and setting_key = new.setting_key
         and status = 'approved' and id <> new.id;
      if v_prev_from is not null and new.effective_from <= v_prev_from then
        raise exception 'ACCT_SETTING_DATE_ORDER: effective date must be later than the previous approved choice''s (%)', v_prev_from;
      end if;

      select max(entry_date) into v_latest_je from journal_entries where tenant_id = new.tenant_id;
      if v_latest_je is not null and new.effective_from <= v_latest_je then
        raise exception 'ACCT_SETTING_BACKDATED: an entry dated % is already posted; choose an effective date after it (a restatement is a separate, accountant-led exercise)', v_latest_je;
      end if;
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.company_accounting_settings_guard() from public, anon, authenticated;

drop trigger if exists trg_company_accounting_settings_guard on public.company_accounting_settings;
create trigger trg_company_accounting_settings_guard
  before insert or update on public.company_accounting_settings
  for each row execute function public.company_accounting_settings_guard();

create or replace function public.company_accounting_settings_audit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event  text;
  v_detail jsonb;
begin
  if tg_op = 'INSERT' then
    v_event := 'proposed';
    v_detail := jsonb_build_object('value', new.value, 'effective_from', new.effective_from, 'rationale', new.rationale);
  elsif new.status is distinct from old.status then
    v_event := new.status;
    v_detail := case new.status
      when 'withdrawn' then jsonb_build_object('reason', new.withdrawn_reason)
      else jsonb_build_object('value', new.value, 'effective_from', new.effective_from)
    end;
  elsif new.review_status is distinct from old.review_status then
    v_event := 'reviewed';
    v_detail := jsonb_build_object('reviewer_name', new.reviewer_name, 'review_reference', new.review_reference);
  else
    return new;
  end if;

  insert into company_accounting_setting_events (tenant_id, setting_id, setting_key, event, actor, detail)
  values (new.tenant_id, new.id, new.setting_key, v_event, auth.uid(), v_detail);
  return new;
end;
$$;

revoke all on function public.company_accounting_settings_audit() from public, anon, authenticated;

drop trigger if exists trg_company_accounting_settings_audit on public.company_accounting_settings;
create trigger trg_company_accounting_settings_audit
  after insert or update on public.company_accounting_settings
  for each row execute function public.company_accounting_settings_audit();

-- =====================================================================
-- E. RLS and grants (read only; writes go through the RPCs below)
-- =====================================================================
alter table public.company_accounting_settings enable row level security;
alter table public.company_accounting_setting_events enable row level security;

drop policy if exists company_accounting_settings_select on public.company_accounting_settings;
create policy company_accounting_settings_select on public.company_accounting_settings
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member(null::text) or can_access_insurance())
  );

drop policy if exists company_accounting_setting_events_select on public.company_accounting_setting_events;
create policy company_accounting_setting_events_select on public.company_accounting_setting_events
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member(null::text) or can_access_insurance())
  );

revoke all on public.company_accounting_settings from public, anon, authenticated;
revoke all on public.company_accounting_setting_events from public, anon, authenticated;
grant select on public.company_accounting_settings to authenticated;
grant select on public.company_accounting_setting_events to authenticated;

-- =====================================================================
-- F. Resolution
-- =====================================================================
-- The approved value in force on the date, else the definition's default.
create or replace function public.platform_acct_setting_value(p_tenant_id uuid, p_key text, p_on date)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select s.value
       from company_accounting_settings s
      where s.tenant_id = p_tenant_id and s.setting_key = p_key
        and s.status = 'approved' and s.effective_from <= p_on
      order by s.effective_from desc
      limit 1),
    (select d.default_value from accounting_setting_definitions d where d.key = p_key));
$$;

revoke all on function public.platform_acct_setting_value(uuid, text, date) from public, anon, authenticated;

-- One setting, with where the value came from and whether it was reviewed.
create or replace function public.acct_get_setting(p_key text, p_on date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_def    accounting_setting_definitions%rowtype;
  v_row    company_accounting_settings%rowtype;
begin
  if v_tenant is null then
    raise exception 'ACCT_SETTING_FORBIDDEN: no company in context' using errcode = '42501';
  end if;
  select * into v_def from accounting_setting_definitions where key = p_key;
  if not found then
    raise exception 'ACCT_SETTING_UNKNOWN: no accounting setting named %', p_key;
  end if;

  select * into v_row
    from company_accounting_settings
   where tenant_id = v_tenant and setting_key = p_key
     and status = 'approved' and effective_from <= p_on
   order by effective_from desc
   limit 1;

  if found then
    return jsonb_build_object(
      'key', p_key, 'value', v_row.value, 'source', 'configured',
      'effective_from', v_row.effective_from, 'setting_id', v_row.id,
      'review_status', v_row.review_status);
  end if;
  return jsonb_build_object(
    'key', p_key, 'value', v_def.default_value, 'source', 'default',
    'effective_from', null, 'setting_id', null, 'review_status', 'unreviewed');
end;
$$;

-- Every defined setting as it stands today, for a settings screen.
create or replace function public.acct_settings_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_out jsonb;
begin
  if get_my_tenant_id() is null then
    raise exception 'ACCT_SETTING_FORBIDDEN: no company in context' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(
           jsonb_build_object('label', d.label, 'description', d.description, 'allowed_values', to_jsonb(d.allowed_values))
           || public.acct_get_setting(d.key, current_date)
           order by d.key), '[]'::jsonb)
    into v_out
    from accounting_setting_definitions d;
  return v_out;
end;
$$;

-- =====================================================================
-- G. Propose, approve, withdraw, record a review
-- =====================================================================
create or replace function public.acct_setting_propose(
  p_key text, p_value text, p_effective_from date, p_rationale text)
returns public.company_accounting_settings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_row    company_accounting_settings%rowtype;
begin
  if v_tenant is null or not (is_tenant_admin() or is_finance_team_member('finance'::text)) then
    raise exception 'ACCT_SETTING_FORBIDDEN: only a company admin or finance team member can propose an accounting setting' using errcode = '42501';
  end if;
  if p_effective_from is null then
    raise exception 'ACCT_SETTING_DATE_REQUIRED: an effective date is required';
  end if;
  if length(btrim(coalesce(p_rationale, ''))) < 10 then
    raise exception 'ACCT_SETTING_RATIONALE: explain the choice in at least ten characters';
  end if;

  insert into company_accounting_settings (tenant_id, setting_key, value, effective_from, rationale, created_by)
  values (v_tenant, p_key, p_value, p_effective_from, btrim(p_rationale), auth.uid())
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.acct_setting_approve(p_id uuid)
returns public.company_accounting_settings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row company_accounting_settings%rowtype;
  v_uid uuid := auth.uid();
begin
  select * into v_row from company_accounting_settings
   where id = p_id and tenant_id = get_my_tenant_id()
   for update;
  if not found then
    raise exception 'ACCT_SETTING_NOT_FOUND: setting choice not found';
  end if;
  if not is_tenant_admin() then
    raise exception 'ACCT_SETTING_FORBIDDEN: only a company admin can approve an accounting setting' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'ACCT_SETTING_NOT_DRAFT: only a draft can be approved (this one is %)', v_row.status;
  end if;
  if v_row.created_by is not distinct from v_uid then
    raise exception 'ACCT_SETTING_SELF_APPROVAL: the person who proposed a choice cannot approve it';
  end if;

  perform set_config('acct.via_rpc', 'on', true);
  update company_accounting_settings
     set status = 'approved', approved_by = v_uid, approved_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('acct.via_rpc', 'off', true);
  return v_row;
end;
$$;

create or replace function public.acct_setting_withdraw(p_id uuid, p_reason text)
returns public.company_accounting_settings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row    company_accounting_settings%rowtype;
  v_uid    uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into v_row from company_accounting_settings
   where id = p_id and tenant_id = get_my_tenant_id()
   for update;
  if not found then
    raise exception 'ACCT_SETTING_NOT_FOUND: setting choice not found';
  end if;
  if length(v_reason) < 5 then
    raise exception 'ACCT_SETTING_REASON: give a reason of at least five characters';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'ACCT_SETTING_NOT_DRAFT: only a draft can be withdrawn (this one is %)', v_row.status;
  end if;
  if not (is_tenant_admin() or v_row.created_by is not distinct from v_uid) then
    raise exception 'ACCT_SETTING_FORBIDDEN: only the proposer or a company admin can withdraw a draft' using errcode = '42501';
  end if;

  perform set_config('acct.via_rpc', 'on', true);
  update company_accounting_settings
     set status = 'withdrawn', withdrawn_reason = v_reason
   where id = p_id
   returning * into v_row;
  perform set_config('acct.via_rpc', 'off', true);
  return v_row;
end;
$$;

-- Records that a named accountant or adviser reviewed this choice. Allowed on
-- a draft or an approved choice, once; a different view is a new proposal.
create or replace function public.acct_setting_record_review(
  p_id uuid, p_reviewer_name text, p_reference text)
returns public.company_accounting_settings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row company_accounting_settings%rowtype;
begin
  select * into v_row from company_accounting_settings
   where id = p_id and tenant_id = get_my_tenant_id()
   for update;
  if not found then
    raise exception 'ACCT_SETTING_NOT_FOUND: setting choice not found';
  end if;
  if not is_tenant_admin() then
    raise exception 'ACCT_SETTING_FORBIDDEN: only a company admin can record a review' using errcode = '42501';
  end if;
  if v_row.status = 'withdrawn' then
    raise exception 'ACCT_SETTING_NOT_DRAFT: a withdrawn choice cannot be reviewed';
  end if;
  if v_row.review_status = 'reviewed' then
    raise exception 'ACCT_SETTING_ALREADY_REVIEWED: a review is already recorded for this choice';
  end if;
  if length(btrim(coalesce(p_reviewer_name, ''))) < 2 or length(btrim(coalesce(p_reference, ''))) < 2 then
    raise exception 'ACCT_SETTING_REVIEW_DETAILS: the reviewer''s name and a reference are both required';
  end if;

  perform set_config('acct.via_rpc', 'on', true);
  update company_accounting_settings
     set review_status = 'reviewed', reviewer_name = btrim(p_reviewer_name),
         review_reference = btrim(p_reference), reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('acct.via_rpc', 'off', true);
  return v_row;
end;
$$;

revoke all on function public.acct_get_setting(text, date) from public, anon;
revoke all on function public.acct_settings_overview() from public, anon;
revoke all on function public.acct_setting_propose(text, text, date, text) from public, anon;
revoke all on function public.acct_setting_approve(uuid) from public, anon;
revoke all on function public.acct_setting_withdraw(uuid, text) from public, anon;
revoke all on function public.acct_setting_record_review(uuid, text, text) from public, anon;
grant execute on function public.acct_get_setting(text, date) to authenticated;
grant execute on function public.acct_settings_overview() to authenticated;
grant execute on function public.acct_setting_propose(text, text, date, text) to authenticated;
grant execute on function public.acct_setting_approve(uuid) to authenticated;
grant execute on function public.acct_setting_withdraw(uuid, text) to authenticated;
grant execute on function public.acct_setting_record_review(uuid, text, text) to authenticated;

-- =====================================================================
-- H. Suspended and read-only tenants
-- =====================================================================
select public.apply_tenant_read_only_guard();
