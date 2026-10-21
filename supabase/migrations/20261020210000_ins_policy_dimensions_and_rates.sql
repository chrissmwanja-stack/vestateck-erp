-- Phase C item 1: reporting dimensions on policies, and the commission rate matrix.
--
-- Why: ins_policies has no branch, agent or transaction-type column, so production reports
-- cannot slice by who produced the business, where, or as what (new business vs renewal).
-- Retrofitting dimensions after real policies exist is expensive, so they go in before the
-- pilot. And an insurer has one default_commission_rate_pct, while real brokerage terms vary
-- by insurer and class; ins_insurer_product_rates holds the agreed rate per insurer and
-- product line, effective-dated, with the same draft, approve, withdraw shape as fx_rates.
--
-- Dimensions:
--   branch_id         references the tenant's organisations (site). Nullable.
--   agent_id          references an intermediary (the register of 20261017150000). Nullable.
--                     An active intermediary is required for NEW policies; a policy keeps a
--                     reference to an intermediary that is later suspended, and renewals copy
--                     it, so the guard checks tenant membership always and activity only when
--                     the reference changes.
--   transaction_type  'new_business' or 'renewal'. A renewal draft is stamped by
--                     platform_ins_create_renewal_legacy_impl; a created policy is new business
--                     by default. Endorsement and cancellation keep their own tables for now.
--
-- Rate matrix (mirrors fx_rates, 20261016140000):
--   A row is entered as a draft by an insurance admin or manager, approved by a different one,
--   and is immutable once approved or withdrawn. Approval refuses to overlap another approved
--   rate for the same insurer and product line, so exactly one approved rate is in force per
--   insurer, product line and date. The new-policy form reads the approved rate as the default
--   commission for the chosen insurer and product line.

-- =====================================================================
-- A. Dimensions on ins_policies
-- =====================================================================
alter table public.ins_policies
  add column if not exists branch_id uuid references public.organizations(id),
  add column if not exists agent_id uuid references public.ins_intermediaries(id) on delete restrict;

alter table public.ins_policies
  add column if not exists transaction_type text not null default 'new_business';

do $$ begin
  alter table public.ins_policies
    add constraint ins_policies_transaction_type_check check (transaction_type in ('new_business', 'renewal'));
exception when duplicate_object then null; end $$;

create index if not exists ins_policies_tenant_agent_idx on public.ins_policies (tenant_id, agent_id);
create index if not exists ins_policies_tenant_branch_idx on public.ins_policies (tenant_id, branch_id);
create index if not exists ins_policies_tenant_txn_idx on public.ins_policies (tenant_id, transaction_type);

-- =====================================================================
-- B. The policy guard learns the two new references
-- =====================================================================
create or replace function public.ins_policies_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if not public.ins_via_rpc() then
      raise exception 'INS_RPC_ONLY: create policies with ins_create_policy()' using errcode = '42501';
    end if;
  else
    if new.status is distinct from old.status and not public.ins_via_rpc() then
      raise exception 'INS_STATUS_RPC_ONLY: policy status changes go through ins_bind_policy()' using errcode = '42501';
    end if;
    if old.status <> 'draft' and (
      to_jsonb(old) - array['status', 'notes', 'updated_at']
    ) is distinct from (
      to_jsonb(new) - array['status', 'notes', 'updated_at']
    ) then
      raise exception 'INS_POLICY_LOCKED: a % policy cannot be edited', old.status;
    end if;
    if old.status <> 'draft' and new.status = 'draft' then
      raise exception 'INS_STATUS_INVALID: a bound policy cannot return to draft';
    end if;

    -- Draft-only rules (a non-draft policy was handled by the lock above).
    if not public.ins_via_rpc() then
      if new.renewal_of_id is distinct from old.renewal_of_id then
        raise exception 'INS_RENEWAL_LINK_RPC_ONLY: the renewal link is set by ins_create_renewal_draft()' using errcode = '42501';
      end if;
      if new.commission_amount      is distinct from old.commission_amount
         or new.net_premium_to_insurer is distinct from old.net_premium_to_insurer
         or new.bound_at            is distinct from old.bound_at
         or new.bound_by            is distinct from old.bound_by
         or new.journal_entry_id    is distinct from old.journal_entry_id then
        raise exception 'INS_BIND_FIELDS_RPC_ONLY: commission, net premium and the bind stamps are set by ins_bind_policy()' using errcode = '42501';
      end if;
    end if;
  end if;

  if not exists (select 1 from ins_clients c where c.id = new.client_id and c.tenant_id = new.tenant_id) then
    raise exception 'INS_CROSS_TENANT: client belongs to another tenant';
  end if;
  if not exists (select 1 from ins_insurers i where i.id = new.insurer_id and i.tenant_id = new.tenant_id) then
    raise exception 'INS_CROSS_TENANT: insurer belongs to another tenant';
  end if;
  if not exists (select 1 from ins_product_lines p where p.id = new.product_line_id and p.tenant_id = new.tenant_id) then
    raise exception 'INS_CROSS_TENANT: product line belongs to another tenant';
  end if;
  if new.agent_id is not null and not exists (
    select 1 from ins_intermediaries a where a.id = new.agent_id and a.tenant_id = new.tenant_id
  ) then
    raise exception 'INS_CROSS_TENANT: agent belongs to another tenant';
  end if;
  if new.branch_id is not null and not exists (
    select 1 from organizations o where o.id = new.branch_id and o.tenant_id = new.tenant_id
  ) then
    raise exception 'INS_CROSS_TENANT: branch belongs to another tenant';
  end if;
  -- Activity only matters when the reference is being moved: a draft keeps an agent or branch
  -- that was suspended after it was chosen, the same rule as the insurer and product line.
  if tg_op = 'UPDATE' then
    if new.agent_id is distinct from old.agent_id and new.agent_id is not null and not exists (
      select 1 from ins_intermediaries a
      where a.id = new.agent_id and a.tenant_id = new.tenant_id and a.status = 'active'
    ) then
      raise exception 'INS_NOT_ACTIVE: agent must be an active intermediary';
    end if;
    if new.branch_id is distinct from old.branch_id and new.branch_id is not null and not exists (
      select 1 from organizations o
      where o.id = new.branch_id and o.tenant_id = new.tenant_id and o.is_active
    ) then
      raise exception 'INS_NOT_ACTIVE: branch must be an active organisation';
    end if;
  end if;
  return new;
end $$;

-- =====================================================================
-- C. ins_create_policy carries the dimensions
-- =====================================================================
-- The drop is for databases that ran an earlier draft of this migration, which
-- appended the new parameters after the defaulted p_notes; defaults ahead of
-- plain parameters are illegal, and defaulted new parameters at the end would
-- make an 11-argument call ambiguous between the two overloads. They therefore
-- sit here, before the two defaulted text parameters, so both overloads resolve
-- exactly. Callers passing arguments by name are unaffected.
drop function if exists public.ins_create_policy(uuid, uuid, uuid, date, date, numeric, text, numeric, numeric, text, text, uuid, uuid);

create or replace function public.ins_create_policy(
  p_client_id            uuid,
  p_insurer_id           uuid,
  p_product_line_id      uuid,
  p_inception_date       date,
  p_expiry_date          date,
  p_sum_insured          numeric,
  p_currency             text,
  p_gross_premium        numeric,
  p_commission_rate_pct  numeric,
  p_branch_id            uuid,
  p_agent_id             uuid,
  p_risk_description     text default null,
  p_notes                text default null
)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_row    ins_policies%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if p_expiry_date is null or p_inception_date is null or p_expiry_date <= p_inception_date then
    raise exception 'INS_DATES: expiry must be after inception';
  end if;
  if coalesce(p_sum_insured, -1) < 0 or coalesce(p_gross_premium, -1) < 0 then
    raise exception 'INS_AMOUNT: sum insured and premium cannot be negative';
  end if;
  if p_commission_rate_pct is null or p_commission_rate_pct < 0 or p_commission_rate_pct >= 100 then
    raise exception 'INS_COMMISSION: commission rate must be at least 0 and below 100';
  end if;
  if not exists (select 1 from ins_clients where id = p_client_id and tenant_id = v_tenant) then
    raise exception 'INS_NOT_FOUND: client';
  end if;
  if not exists (select 1 from ins_insurers where id = p_insurer_id and tenant_id = v_tenant and is_active) then
    raise exception 'INS_NOT_FOUND: active insurer';
  end if;
  if not exists (select 1 from ins_product_lines where id = p_product_line_id and tenant_id = v_tenant and is_active) then
    raise exception 'INS_NOT_FOUND: active product line';
  end if;
  -- A new policy is produced by an agent who is active today. A policy keeps an agent who is
  -- suspended later; the guard only requires activity when the reference changes.
  if p_agent_id is not null and not exists (
    select 1 from ins_intermediaries a
    where a.id = p_agent_id and a.tenant_id = v_tenant and a.status = 'active'
  ) then
    raise exception 'INS_NOT_FOUND: active intermediary (agent)';
  end if;
  if p_branch_id is not null and not exists (
    select 1 from organizations o
    where o.id = p_branch_id and o.tenant_id = v_tenant and o.is_active
  ) then
    raise exception 'INS_NOT_FOUND: active organisation (branch)';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_policies (
    tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
    inception_date, expiry_date, sum_insured, currency, gross_premium,
    commission_rate_pct, risk_description, notes, branch_id, agent_id, transaction_type
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_POLICY', 'POL', 5), p_client_id, p_insurer_id, p_product_line_id, 'draft',
    p_inception_date, p_expiry_date, coalesce(p_sum_insured, 0), coalesce(nullif(p_currency, ''), 'UGX'), coalesce(p_gross_premium, 0),
    p_commission_rate_pct, nullif(btrim(p_risk_description), ''), nullif(btrim(p_notes), ''),
    p_branch_id, p_agent_id, 'new_business'
  )
  returning * into v_row;
  return v_row;
end;
$$;

-- =====================================================================
-- C2. The old 11-argument ins_create_policy stays, delegating (seed and
-- existing tests call it positionally). One source of truth: the 13-argument
-- version above.
-- =====================================================================
create or replace function public.ins_create_policy(
  p_client_id            uuid,
  p_insurer_id           uuid,
  p_product_line_id      uuid,
  p_inception_date       date,
  p_expiry_date          date,
  p_sum_insured          numeric,
  p_currency             text,
  p_gross_premium        numeric,
  p_commission_rate_pct  numeric,
  p_risk_description     text default null,
  p_notes                text default null
)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return public.ins_create_policy(
    p_client_id, p_insurer_id, p_product_line_id, p_inception_date, p_expiry_date,
    p_sum_insured, p_currency, p_gross_premium, p_commission_rate_pct,
    null::uuid, null::uuid, p_risk_description, p_notes);
end;
$$;

-- =====================================================================
-- D. A renewal draft is transaction_type 'renewal' and carries the dimensions over
-- =====================================================================
create or replace function public.platform_ins_create_renewal_legacy_impl(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_old    ins_policies%rowtype;
  v_row    ins_policies%rowtype;
  v_term   integer;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_old from ins_policies where id = p_policy_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if v_old.status <> 'active' then
    raise exception 'INS_RENEWAL_STATE: only an active policy can be renewed (this one is %)', v_old.status;
  end if;
  if exists (select 1 from ins_policies where renewal_of_id = v_old.id and status = 'draft') then
    raise exception 'INS_RENEWAL_EXISTS: a renewal draft already exists for %', v_old.policy_no;
  end if;

  v_term := v_old.expiry_date - v_old.inception_date;
  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_policies (
    tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
    inception_date, expiry_date, sum_insured, currency, gross_premium,
    commission_rate_pct, risk_description, renewal_of_id, branch_id, agent_id, transaction_type
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_POLICY', 'POL', 5), v_old.client_id, v_old.insurer_id, v_old.product_line_id, 'draft',
    v_old.expiry_date, v_old.expiry_date + v_term, v_old.sum_insured, v_old.currency, v_old.gross_premium,
    v_old.commission_rate_pct, v_old.risk_description, v_old.id, v_old.branch_id, v_old.agent_id, 'renewal'
  )
  returning * into v_row;
  return v_row;
end;
$$;

-- =====================================================================
-- E. The commission rate matrix
-- =====================================================================
create table if not exists public.ins_insurer_product_rates (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  insurer_id       uuid not null references public.ins_insurers(id) on delete cascade,
  product_line_id  uuid not null references public.ins_product_lines(id) on delete cascade,
  rate             numeric(5,2) not null,
  effective_from   date not null,
  effective_to     date,
  source_ref       text not null,
  status           text not null default 'draft',
  entered_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  approved_by      uuid,
  approved_at      timestamptz,
  withdrawn_reason text,
  updated_at       timestamptz not null default now(),
  constraint ins_insurer_product_rates_rate_check check (rate >= 0 and rate < 100),
  constraint ins_insurer_product_rates_window_check check (effective_to is null or effective_to >= effective_from),
  constraint ins_insurer_product_rates_source_check check (btrim(source_ref) <> ''),
  constraint ins_insurer_product_rates_status_check check (status in ('draft', 'approved', 'withdrawn')),
  constraint ins_insurer_product_rates_approved_check
    check (status <> 'approved' or (approved_by is not null and approved_at is not null))
);

comment on table public.ins_insurer_product_rates is
  'Agreed commission rate per insurer and product line, effective-dated. Entered as a draft,
   approved by a different insurance admin or manager, immutable once approved or withdrawn.
   Approval refuses to overlap another approved rate for the same insurer and product line,
   so exactly one approved rate is in force per insurer, product line and date.';

create index if not exists ins_insurer_product_rates_lookup_idx
  on public.ins_insurer_product_rates (tenant_id, insurer_id, product_line_id, effective_from);

create or replace function public.ins_insurer_product_rates_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: manage commission rates with ins_set_insurer_product_rate()' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'INS_RATE_STATUS: a new rate starts as a draft; approval is a separate step by a different person';
    end if;
    if new.approved_by is not null or new.approved_at is not null or new.withdrawn_reason is not null then
      raise exception 'INS_RATE_STATUS: approval and withdrawal fields cannot be set on a new draft';
    end if;
  else
    if new.tenant_id is distinct from old.tenant_id
       or new.insurer_id is distinct from old.insurer_id
       or new.product_line_id is distinct from old.product_line_id then
      raise exception 'INS_RATE_KEY_IMMUTABLE: a rate cannot move to another company, insurer or product line';
    end if;
    -- Immutable: company, insurer, product line, rate, window start, source and
    -- entrant. What RPCs may change on top: status and its stamps (approve,
    -- withdraw) and, for an approved rate, the window end (end-date).
    if (to_jsonb(new) - array['status', 'approved_by', 'approved_at', 'withdrawn_reason', 'effective_to', 'updated_at'])
       is distinct from (to_jsonb(old) - array['status', 'approved_by', 'approved_at', 'withdrawn_reason', 'effective_to', 'updated_at']) then
      raise exception 'INS_RATE_IMMUTABLE: a rate''s insurer, product line, rate, start date, source and entrant cannot be changed; enter a correcting rate';
    end if;
    if new.status is distinct from old.status and not public.ins_via_rpc() then
      raise exception 'INS_RATE_STATUS_VIA_RPC: change status with ins_approve_insurer_product_rate or ins_withdraw_insurer_product_rate';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists ins_insurer_product_rates_guard_trg on public.ins_insurer_product_rates;
create trigger ins_insurer_product_rates_guard_trg
  before insert or update on public.ins_insurer_product_rates
  for each row execute function public.ins_insurer_product_rates_guard();

alter table public.ins_insurer_product_rates enable row level security;

drop policy if exists ins_insurer_product_rates_select on public.ins_insurer_product_rates;
create policy ins_insurer_product_rates_select on public.ins_insurer_product_rates
  for select using (
    tenant_id = get_my_tenant_id() and can_access_insurance()
  );

revoke all on public.ins_insurer_product_rates from public, anon, authenticated;
grant select on public.ins_insurer_product_rates to authenticated;

create or replace function public.ins_set_insurer_product_rate(
  p_insurer_id      uuid,
  p_product_line_id uuid,
  p_rate            numeric,
  p_effective_from  date,
  p_effective_to    date default null,
  p_source_ref      text default null
)
returns public.ins_insurer_product_rates
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_row    ins_insurer_product_rates%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers maintain commission rates' using errcode = '42501';
  end if;
  if not exists (select 1 from ins_insurers where id = p_insurer_id and tenant_id = v_tenant and is_active) then
    raise exception 'INS_NOT_FOUND: active insurer';
  end if;
  if not exists (select 1 from ins_product_lines where id = p_product_line_id and tenant_id = v_tenant and is_active) then
    raise exception 'INS_NOT_FOUND: active product line';
  end if;
  if p_rate is null or p_rate < 0 or p_rate >= 100 then
    raise exception 'INS_RATE_VALUE: commission rate must be at least 0 and below 100';
  end if;
  if p_effective_from is null then
    raise exception 'INS_RATE_WINDOW: give the date the rate takes effect';
  end if;
  if p_effective_to is not null and p_effective_to < p_effective_from then
    raise exception 'INS_RATE_WINDOW: the end date cannot be before the start date';
  end if;
  if p_source_ref is null or btrim(p_source_ref) = '' then
    raise exception 'INS_RATE_SOURCE: record the agreement the rate comes from';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_insurer_product_rates (
    tenant_id, insurer_id, product_line_id, rate, effective_from, effective_to, source_ref
  ) values (
    v_tenant, p_insurer_id, p_product_line_id, p_rate, p_effective_from, p_effective_to, btrim(p_source_ref)
  )
  returning * into v_row;
  perform set_config('ins.via_rpc', 'off', true);
  return v_row;
end;
$$;

create or replace function public.ins_approve_insurer_product_rate(p_id uuid)
returns public.ins_insurer_product_rates
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row ins_insurer_product_rates%rowtype;
  v_uid uuid := auth.uid();
begin
  select * into v_row from ins_insurer_product_rates
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'INS_RATE_NOT_FOUND: rate not found';
  end if;
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers approve commission rates' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'INS_RATE_NOT_DRAFT: only a draft can be approved (this one is %)', v_row.status;
  end if;
  if v_row.entered_by is not distinct from v_uid then
    raise exception 'INS_RATE_SELF_APPROVAL: the person who entered a rate cannot approve it';
  end if;
  -- Exactly one approved rate in force per insurer, product line and date.
  if exists (
    select 1 from ins_insurer_product_rates r2
    where r2.tenant_id = v_row.tenant_id
      and r2.insurer_id = v_row.insurer_id
      and r2.product_line_id = v_row.product_line_id
      and r2.id <> v_row.id
      and r2.status = 'approved'
      and r2.effective_from <= coalesce(v_row.effective_to, 'infinity'::date)
      and coalesce(r2.effective_to, 'infinity'::date) >= v_row.effective_from
  ) then
    raise exception 'INS_RATE_OVERLAP: another approved rate for this insurer and product line already covers part of this window';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_insurer_product_rates
     set status = 'approved', approved_by = v_uid, approved_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('ins.via_rpc', 'off', true);
  return v_row;
end;
$$;

create or replace function public.ins_withdraw_insurer_product_rate(p_id uuid, p_reason text)
returns public.ins_insurer_product_rates
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row    ins_insurer_product_rates%rowtype;
  v_uid    uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into v_row from ins_insurer_product_rates
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'INS_RATE_NOT_FOUND: rate not found';
  end if;
  if length(v_reason) < 5 then
    raise exception 'INS_RATE_REASON: give a reason of at least five characters';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'INS_RATE_NOT_DRAFT: only a draft can be withdrawn (this one is %)', v_row.status;
  end if;
  if not (can_manage_insurance() or v_row.entered_by is not distinct from v_uid) then
    raise exception 'INS_FORBIDDEN: only the person who entered a draft or an insurance admin or manager can withdraw it' using errcode = '42501';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_insurer_product_rates
     set status = 'withdrawn', withdrawn_reason = v_reason
   where id = p_id
   returning * into v_row;
  perform set_config('ins.via_rpc', 'off', true);
  return v_row;
end;
$$;

create or replace function public.ins_end_insurer_product_rate(p_id uuid, p_effective_to date)
returns public.ins_insurer_product_rates
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row ins_insurer_product_rates%rowtype;
begin
  select * into v_row from ins_insurer_product_rates
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'INS_RATE_NOT_FOUND: rate not found';
  end if;
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers end a commission rate' using errcode = '42501';
  end if;
  if v_row.status <> 'approved' then
    raise exception 'INS_RATE_NOT_APPROVED: only an approved rate can be end-dated (this one is %)', v_row.status;
  end if;
  if p_effective_to is null or p_effective_to < v_row.effective_from then
    raise exception 'INS_RATE_WINDOW: the new end date cannot be empty or before the rate starts (%)', v_row.effective_from;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_insurer_product_rates
     set effective_to = p_effective_to
   where id = p_id
   returning * into v_row;
  perform set_config('ins.via_rpc', 'off', true);
  return v_row;
end;
$$;

revoke all on function public.ins_create_policy(uuid, uuid, uuid, date, date, numeric, text, numeric, numeric, uuid, uuid, text, text) from public, anon;
revoke all on function public.ins_insurer_product_rates_guard() from public, anon, authenticated;
revoke all on function public.ins_set_insurer_product_rate(uuid, uuid, numeric, date, date, text) from public, anon;
revoke all on function public.ins_approve_insurer_product_rate(uuid) from public, anon;
revoke all on function public.ins_withdraw_insurer_product_rate(uuid, text) from public, anon;
grant execute on function public.ins_create_policy(uuid, uuid, uuid, date, date, numeric, text, numeric, numeric, uuid, uuid, text, text) to authenticated;
grant execute on function public.ins_set_insurer_product_rate(uuid, uuid, numeric, date, date, text) to authenticated;
grant execute on function public.ins_approve_insurer_product_rate(uuid) to authenticated;
grant execute on function public.ins_withdraw_insurer_product_rate(uuid, text) to authenticated;
revoke all on function public.ins_end_insurer_product_rate(uuid, date) from public, anon;
grant execute on function public.ins_end_insurer_product_rate(uuid, date) to authenticated;

-- The new rate table carries a tenant_id, so it gets the platform read-only
-- guard like every other tenant table.
select public.apply_tenant_read_only_guard();
