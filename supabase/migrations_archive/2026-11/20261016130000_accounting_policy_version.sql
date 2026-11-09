-- Phase A, step A2 (see docs/insurance-brokerage/ROADMAP.md): accounting-policy
-- version on every posted transaction.
--
-- Why: Phase B changes how insurance income is recognised (commission at
-- placement instead of on settlement). Whether that is a change of accounting
-- policy, and how it is restated, is for the accountant. Whatever the answer, a
-- later reader must be able to tell which treatment a posting was made under.
-- This migration records that; it does not change any posting.
--
-- Model:
--   * Version 1 is the baseline: every posting made before this migration, and
--     every posting in a company that has never approved a policy change. It is
--     implicit and needs no row.
--   * accounting_policies holds a company's later versions (2, 3, ...). A version
--     is proposed as a draft, then approved by a different company admin
--     (maker-checker, as for regulatory_parameters). Approved rows never change.
--   * The version in force for a posting is the highest approved version whose
--     effective_from is on or before the posting's accounting date.
--   * The version is stamped by a BEFORE INSERT trigger from that date. A caller
--     cannot choose it, and it cannot be changed afterwards.
--   * A version cannot be approved with an effective date on or before the date
--     of an entry already posted. That would make history say something
--     different from what was stamped. A change takes effect from a date no
--     posted entry has reached yet.
--
-- Stamped tables and the date each is stamped from:
--   journal_entries (entry_date), fin_open_items (document_date),
--   fin_settlements (settlement_date), fin_credit_notes (credit_date),
--   ins_claim_payments (payment_date), ins_commission_transfers (transfer_date),
--   ins_policy_financial_snapshots (bound_at), ins_policy_reversals (reversal_date).
-- Existing rows keep version 1 through the column default; no row is rewritten.
--
-- Additive. No existing function is changed and no posting logic is touched.

-- =====================================================================
-- A. Tenant policy versions
-- =====================================================================
create table if not exists public.accounting_policies (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  version         integer not null,
  name            text not null,
  description     text not null,
  effective_from  date not null,
  status          text not null default 'draft',
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  approved_by     uuid,
  approved_at     timestamptz,
  withdrawn_reason text,
  updated_at      timestamptz not null default now(),
  constraint accounting_policies_version_check check (version >= 2),
  constraint accounting_policies_status_check check (status in ('draft', 'approved', 'withdrawn')),
  constraint accounting_policies_text_check check (btrim(name) <> '' and btrim(description) <> ''),
  constraint accounting_policies_approved_check
    check (status <> 'approved' or (approved_by is not null and approved_at is not null))
);

-- One live row per version. A withdrawn draft does not hold its number, so the
-- version can be proposed again (approval requires consecutive numbers).
create unique index if not exists accounting_policies_tenant_version_idx
  on public.accounting_policies (tenant_id, version)
  where status <> 'withdrawn';

comment on table public.accounting_policies is
  'A company''s accounting-policy versions after the baseline (version 1 is implicit). Approved by a second company admin; approved rows never change. The version in force on a date is stamped on every posted transaction.';
comment on column public.accounting_policies.description is
  'What treatment changed and the accountant''s reference for it (for example the IAS 8 classification and who confirmed it).';
comment on column public.accounting_policies.effective_from is
  'First accounting date the version applies to. Must be later than every entry already posted when the version is approved.';

create index if not exists accounting_policies_tenant_idx
  on public.accounting_policies (tenant_id, status, effective_from);

-- =====================================================================
-- B. Guard trigger
-- =====================================================================
create or replace function public.accounting_policies_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_via        boolean := coalesce(current_setting('acct.via_rpc', true), '') = 'on';
  v_max_ver    integer;
  v_max_from   date;
  v_latest_je  date;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'ACCT_POLICY_STATUS: a new policy version starts as a draft; approval is a separate step by a different person';
    end if;
    if new.approved_by is not null or new.approved_at is not null or new.withdrawn_reason is not null then
      raise exception 'ACCT_POLICY_STATUS: approval and withdrawal fields cannot be set on a new draft';
    end if;
  else
    if new.tenant_id is distinct from old.tenant_id then
      raise exception 'ACCT_POLICY_TENANT_IMMUTABLE: a policy version cannot move to another company';
    end if;
    if new.version is distinct from old.version then
      raise exception 'ACCT_POLICY_VERSION_IMMUTABLE: the version number cannot change';
    end if;
    if old.status in ('approved', 'withdrawn') then
      raise exception 'ACCT_POLICY_IMMUTABLE: an % policy version cannot be changed; propose a new version instead', old.status;
    end if;
    if new.status is distinct from old.status and not v_via then
      raise exception 'ACCT_POLICY_STATUS_VIA_RPC: change status with acct_policy_approve or acct_policy_withdraw';
    end if;
  end if;

  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    perform pg_advisory_xact_lock(hashtextextended('acct_policy:' || new.tenant_id::text, 0));

    select max(version), max(effective_from) into v_max_ver, v_max_from
    from accounting_policies
    where tenant_id = new.tenant_id and status = 'approved' and id <> new.id;

    if new.version <> coalesce(v_max_ver, 1) + 1 then
      raise exception 'ACCT_POLICY_VERSION_ORDER: the next version to approve is %, not %',
        coalesce(v_max_ver, 1) + 1, new.version;
    end if;
    if v_max_from is not null and new.effective_from <= v_max_from then
      raise exception 'ACCT_POLICY_DATE_ORDER: effective date must be later than the previous version''s (%)', v_max_from;
    end if;

    select max(entry_date) into v_latest_je from journal_entries where tenant_id = new.tenant_id;
    if v_latest_je is not null and new.effective_from <= v_latest_je then
      raise exception 'ACCT_POLICY_BACKDATED: an entry dated % is already posted; choose an effective date after it (a restatement is a separate, accountant-led exercise)', v_latest_je;
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.accounting_policies_guard() from public, anon, authenticated;

drop trigger if exists trg_accounting_policies_guard on public.accounting_policies;
create trigger trg_accounting_policies_guard
  before insert or update on public.accounting_policies
  for each row execute function public.accounting_policies_guard();

-- =====================================================================
-- C. RLS and grants (separate policy per verb)
-- =====================================================================
alter table public.accounting_policies enable row level security;

drop policy if exists accounting_policies_select on public.accounting_policies;
create policy accounting_policies_select on public.accounting_policies
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member(null::text) or can_access_insurance())
  );

drop policy if exists accounting_policies_insert on public.accounting_policies;
create policy accounting_policies_insert on public.accounting_policies
  for insert with check (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text))
  );

drop policy if exists accounting_policies_update on public.accounting_policies;
create policy accounting_policies_update on public.accounting_policies
  for update using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text))
  )
  with check (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text))
  );

revoke all on public.accounting_policies from public, anon, authenticated;
grant select, insert, update on public.accounting_policies to authenticated;

-- =====================================================================
-- D. Resolution
-- =====================================================================
-- Highest approved version in force on the date; 1 when none applies. Version 1
-- is the baseline, not a regulatory figure, so this is the one place a default
-- is correct.
create or replace function public.platform_accounting_policy_version(p_tenant_id uuid, p_on date)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select max(version)
       from accounting_policies
      where tenant_id = p_tenant_id
        and status = 'approved'
        and effective_from <= p_on),
    1);
$$;

revoke all on function public.platform_accounting_policy_version(uuid, date) from public, anon, authenticated;

create or replace function public.acct_get_policy_version(p_on date default current_date)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if get_my_tenant_id() is null then
    raise exception 'ACCT_POLICY_FORBIDDEN: no company in context' using errcode = '42501';
  end if;
  return platform_accounting_policy_version(get_my_tenant_id(), p_on);
end;
$$;

revoke all on function public.acct_get_policy_version(date) from public, anon;
grant execute on function public.acct_get_policy_version(date) to authenticated;

-- =====================================================================
-- E. Approval and withdrawal
-- =====================================================================
create or replace function public.acct_policy_approve(p_id uuid)
returns public.accounting_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row accounting_policies%rowtype;
  v_uid uuid := auth.uid();
begin
  select * into v_row from accounting_policies
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'ACCT_POLICY_NOT_FOUND: policy version not found';
  end if;
  if not is_tenant_admin() then
    raise exception 'ACCT_POLICY_FORBIDDEN: only a company admin can approve an accounting policy version' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'ACCT_POLICY_NOT_DRAFT: only a draft can be approved (this one is %)', v_row.status;
  end if;
  if v_row.created_by is not distinct from v_uid then
    raise exception 'ACCT_POLICY_SELF_APPROVAL: the person who proposed a version cannot approve it';
  end if;

  perform set_config('acct.via_rpc', 'on', true);
  update accounting_policies
     set status = 'approved', approved_by = v_uid, approved_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('acct.via_rpc', 'off', true);
  return v_row;
end;
$$;

create or replace function public.acct_policy_withdraw(p_id uuid, p_reason text)
returns public.accounting_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row    accounting_policies%rowtype;
  v_uid    uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into v_row from accounting_policies
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'ACCT_POLICY_NOT_FOUND: policy version not found';
  end if;
  if length(v_reason) < 5 then
    raise exception 'ACCT_POLICY_REASON: give a reason of at least five characters';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'ACCT_POLICY_NOT_DRAFT: only a draft can be withdrawn (this one is %)', v_row.status;
  end if;
  if not (is_tenant_admin() or v_row.created_by is not distinct from v_uid) then
    raise exception 'ACCT_POLICY_FORBIDDEN: only the proposer or a company admin can withdraw a draft' using errcode = '42501';
  end if;

  perform set_config('acct.via_rpc', 'on', true);
  update accounting_policies
     set status = 'withdrawn', withdrawn_reason = v_reason
   where id = p_id
   returning * into v_row;
  perform set_config('acct.via_rpc', 'off', true);
  return v_row;
end;
$$;

revoke all on function public.acct_policy_approve(uuid) from public, anon;
revoke all on function public.acct_policy_withdraw(uuid, text) from public, anon;
grant execute on function public.acct_policy_approve(uuid) to authenticated;
grant execute on function public.acct_policy_withdraw(uuid, text) to authenticated;

-- =====================================================================
-- F. Stamping
-- =====================================================================
-- TG_ARGV[0] names the date column the version is resolved from. A timestamp
-- column is read as its date. A missing date falls back to today.
create or replace function public.platform_stamp_policy_version()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_raw  text := to_jsonb(new) ->> tg_argv[0];
  v_date date := coalesce(left(v_raw, 10)::date, current_date);
begin
  new.accounting_policy_version := platform_accounting_policy_version(new.tenant_id, v_date);
  return new;
end;
$$;

create or replace function public.platform_policy_version_immutable()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.accounting_policy_version is distinct from old.accounting_policy_version then
    raise exception 'ACCT_POLICY_VERSION_IMMUTABLE: the accounting-policy version of a posted record cannot change (on %)', tg_table_name;
  end if;
  return new;
end;
$$;

revoke all on function public.platform_stamp_policy_version() from public, anon, authenticated;
revoke all on function public.platform_policy_version_immutable() from public, anon, authenticated;

do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('journal_entries',               'entry_date'),
      ('fin_open_items',                'document_date'),
      ('fin_settlements',               'settlement_date'),
      ('fin_credit_notes',              'credit_date'),
      ('ins_claim_payments',            'payment_date'),
      ('ins_commission_transfers',      'transfer_date'),
      ('ins_policy_financial_snapshots','bound_at'),
      ('ins_policy_reversals',          'reversal_date')
    ) as t(tbl, date_col)
  loop
    execute format(
      'alter table public.%I add column if not exists accounting_policy_version integer not null default 1 '
      'constraint %I check (accounting_policy_version >= 1)',
      r.tbl, r.tbl || '_policy_version_check');
    execute format(
      'comment on column public.%I.accounting_policy_version is %L',
      r.tbl, 'Accounting-policy version in force on the record''s accounting date, stamped on insert and never changed. 1 is the baseline.');
    execute format('drop trigger if exists trg_stamp_policy_version on public.%I', r.tbl);
    execute format(
      'create trigger trg_stamp_policy_version before insert on public.%I '
      'for each row execute function public.platform_stamp_policy_version(%L)',
      r.tbl, r.date_col);
    execute format('drop trigger if exists trg_policy_version_immutable on public.%I', r.tbl);
    execute format(
      'create trigger trg_policy_version_immutable before update of accounting_policy_version on public.%I '
      'for each row execute function public.platform_policy_version_immutable()',
      r.tbl);
  end loop;
end $$;

-- =====================================================================
-- G. Suspended and read-only tenants
-- =====================================================================
select public.apply_tenant_read_only_guard();