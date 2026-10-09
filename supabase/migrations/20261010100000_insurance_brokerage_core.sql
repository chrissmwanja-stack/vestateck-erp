-- Insurance Brokerage core (DRAFT, phase 2 of the insurance vertical).
--
-- Adds the brokerage's operational register on top of the Phase 1 scaffolding
-- (module registry, insurance template, client-master access, D4 open items):
--
--   ins_product_lines   lookup: classes of insurance the agency places
--   ins_insurers        insurer master (a party account per insurer, for payables)
--   ins_clients         insurance profile on top of bd_clients (a party account
--                       per client, for premium receivables)
--   ins_policies        policy header: draft -> active (bind) -> renewed
--   ins_claims          claim register with a server-enforced state machine
--   ins_claim_events    claim audit trail (written by RPC only)
--
-- Money rules (agreed scope, see docs/insurance-brokerage/ANALYSIS.md):
--   * Binding a policy accrues the premium with one journal and two open items:
--       Dr AR control (client)        gross premium
--       Cr Insurer payable (insurer)  gross premium less commission
--       Cr Commission income          commission
--     Commission = gross * rate / 100, rounded to 2dp. The broker nets its
--     commission and remits the rest to the insurer.
--   * Settlement of those open items (client receipts, insurer remittances)
--     reuses fin_record_settlement from the D4 subledger, not new code here.
--   * NOT in this draft: claim payment cash movements and their GL posting,
--     endorsements (mid-term premium changes), cancellations of bound policies
--     (they need a reversing journal), and the approval workflow for policies.
--
-- Write discipline:
--   * Every table is tenant-scoped with a real FK (MIGRATION_POLICY rule 5).
--   * RLS is split per verb; no FOR ALL (rule 4).
--   * Status changes and party-account links are RPC-only, enforced by guard
--     triggers that check the transaction flag `ins.via_rpc`.
--   * Nothing is dropped. The only change to an existing object is widening the
--     journal_entries.source_type CHECK, which is additive.
--
-- Requires: 20261008085228 (insurance module), 20261008094326 (can_access_client_master),
--           20261008100625 (template GL accounts and posting rules),
--           20261008202213 (fin_create_open_item), 20261001150000 (next_doc_number).

-- =====================================================================
-- A. Access helpers (same tier convention as the other modules)
-- =====================================================================
create or replace function public.can_access_insurance()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.has_module_role('insurance', array['admin','manager','member']);
$$;

create or replace function public.can_manage_insurance()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.has_module_role('insurance', array['admin','manager']);
$$;

revoke all on function public.can_access_insurance() from public, anon;
revoke all on function public.can_manage_insurance() from public, anon;
grant execute on function public.can_access_insurance() to authenticated;
grant execute on function public.can_manage_insurance() to authenticated;

-- Internal helper: the guard triggers use this to see whether the current
-- statement was issued from one of the RPCs below.
create or replace function public.ins_via_rpc()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('ins.via_rpc', true), '') = 'on';
$$;

revoke all on function public.ins_via_rpc() from public, anon;
grant execute on function public.ins_via_rpc() to authenticated;

-- =====================================================================
-- B. Lookup: product lines
-- =====================================================================
create table if not exists public.ins_product_lines (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  code        text not null,
  name        text not null,
  class       text not null default 'general',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint ins_product_lines_tenant_id_id_key unique (tenant_id, id),
  constraint ins_product_lines_tenant_code_key unique (tenant_id, code),
  constraint ins_product_lines_code_check check (code ~ '^[A-Z0-9_-]{2,12}$'),
  constraint ins_product_lines_class_check check (class in ('general', 'life', 'health'))
);

-- =====================================================================
-- C. Insurers
-- =====================================================================
create table if not exists public.ins_insurers (
  id                          uuid primary key default gen_random_uuid(),
  tenant_id                   uuid not null references public.tenants(id) on delete cascade,
  code                        text not null,
  name                        text not null,
  contact_name                text,
  contact_email               text,
  contact_phone               text,
  default_commission_rate_pct numeric(5,2) not null default 0,
  is_active                   boolean not null default true,
  party_account_id            uuid references public.accounts(id),   -- set by ins_bind_policy only
  created_by                  uuid default auth.uid(),
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint ins_insurers_tenant_id_id_key unique (tenant_id, id),
  constraint ins_insurers_tenant_code_key unique (tenant_id, code),
  constraint ins_insurers_code_check check (code ~ '^[A-Z0-9_-]{2,12}$'),
  constraint ins_insurers_commission_check check (default_commission_rate_pct >= 0 and default_commission_rate_pct < 100)
);

-- =====================================================================
-- D. Client profiles (extension of the BD client master)
-- =====================================================================
create table if not exists public.ins_clients (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenants(id) on delete cascade,
  -- restrict, not cascade: deleting a client must never silently delete policies.
  client_id               uuid not null references public.bd_clients(id) on delete restrict,
  client_type             text not null default 'corporate',
  tax_id                  text,
  risk_rating             text not null default 'medium',
  kyc_status              text not null default 'pending',
  relationship_owner_id   uuid references public.app_users(id) on delete set null,
  party_account_id        uuid references public.accounts(id),   -- set by ins_bind_policy only
  created_by              uuid default auth.uid(),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint ins_clients_tenant_id_id_key unique (tenant_id, id),
  constraint ins_clients_tenant_client_key unique (tenant_id, client_id),
  constraint ins_clients_type_check check (client_type in ('individual', 'corporate')),
  constraint ins_clients_risk_check check (risk_rating in ('low', 'medium', 'high')),
  constraint ins_clients_kyc_check check (kyc_status in ('pending', 'verified', 'expired'))
);

-- =====================================================================
-- E. Policies
-- =====================================================================
create table if not exists public.ins_policies (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenants(id) on delete cascade,
  policy_no               text not null,
  client_id               uuid not null references public.ins_clients(id) on delete restrict,
  insurer_id              uuid not null references public.ins_insurers(id) on delete restrict,
  product_line_id         uuid not null references public.ins_product_lines(id) on delete restrict,
  status                  text not null default 'draft',
  inception_date          date not null,
  expiry_date             date not null,
  sum_insured             numeric(18,2) not null default 0,
  currency                text not null default 'UGX',
  gross_premium           numeric(18,2) not null default 0,
  commission_rate_pct     numeric(5,2) not null default 0,
  -- Set at bind; null while draft.
  commission_amount       numeric(18,2),
  net_premium_to_insurer  numeric(18,2),
  bound_at                timestamptz,
  bound_by                uuid,
  journal_entry_id        uuid references public.journal_entries(id),
  renewal_of_id           uuid,
  risk_description        text,
  notes                   text,
  created_by              uuid default auth.uid(),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint ins_policies_tenant_id_id_key unique (tenant_id, id),
  constraint ins_policies_tenant_policy_no_key unique (tenant_id, policy_no),
  constraint ins_policies_renewal_fk foreign key (tenant_id, renewal_of_id)
    references public.ins_policies (tenant_id, id) on delete restrict,
  constraint ins_policies_status_check check (status in ('draft', 'active', 'renewed')),
  constraint ins_policies_dates_check check (expiry_date > inception_date),
  constraint ins_policies_sum_check check (sum_insured >= 0),
  constraint ins_policies_premium_check check (gross_premium >= 0),
  constraint ins_policies_commission_check check (commission_rate_pct >= 0 and commission_rate_pct < 100),
  constraint ins_policies_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint ins_policies_bound_check check (
    status = 'draft'
    or (
      gross_premium > 0
      and commission_amount is not null
      and net_premium_to_insurer is not null
      and commission_amount + net_premium_to_insurer = gross_premium
      and bound_at is not null
    )
  ),
  constraint ins_policies_no_self_renewal check (renewal_of_id is null or renewal_of_id <> id)
);

-- One open renewal draft per expiring policy.
create unique index if not exists ins_policies_one_draft_renewal
  on public.ins_policies (tenant_id, renewal_of_id)
  where renewal_of_id is not null and status = 'draft';

create index if not exists ins_policies_tenant_status_expiry_idx
  on public.ins_policies (tenant_id, status, expiry_date);
create index if not exists ins_policies_client_idx on public.ins_policies (client_id);
create index if not exists ins_policies_insurer_idx on public.ins_policies (insurer_id);

-- =====================================================================
-- F. Claims and claim events
-- =====================================================================
create table if not exists public.ins_claims (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete cascade,
  claim_no          text not null,
  policy_id         uuid not null,
  status            text not null default 'notified',
  loss_date         date not null,
  notified_date     date not null default current_date,
  loss_description  text not null,
  insurer_claim_ref text,
  reserve_amount    numeric(18,2) not null default 0,
  approved_amount   numeric(18,2),
  paid_amount       numeric(18,2) not null default 0,
  settled_at        timestamptz,
  assigned_to       uuid references public.app_users(id) on delete set null,
  created_by        uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ins_claims_tenant_id_id_key unique (tenant_id, id),
  constraint ins_claims_tenant_claim_no_key unique (tenant_id, claim_no),
  constraint ins_claims_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete restrict,
  constraint ins_claims_status_check check (status in ('notified', 'assessing', 'approved', 'settled', 'repudiated', 'closed')),
  constraint ins_claims_notified_check check (notified_date >= loss_date),
  constraint ins_claims_reserve_check check (reserve_amount >= 0),
  constraint ins_claims_approved_check check (approved_amount is null or approved_amount >= 0),
  constraint ins_claims_paid_check check (paid_amount >= 0 and (approved_amount is null or paid_amount <= approved_amount))
);

create index if not exists ins_claims_policy_idx on public.ins_claims (policy_id);
create index if not exists ins_claims_tenant_status_idx on public.ins_claims (tenant_id, status);

create table if not exists public.ins_claim_events (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  claim_id    uuid not null references public.ins_claims(id) on delete restrict,
  from_status text,
  to_status   text not null,
  note        text,
  actor_id    uuid default auth.uid(),
  created_at  timestamptz not null default now()
);

create index if not exists ins_claim_events_claim_idx on public.ins_claim_events (claim_id, created_at);

-- =====================================================================
-- G. updated_at maintenance
-- =====================================================================
create or replace function public.ins_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists ins_insurers_touch on public.ins_insurers;
create trigger ins_insurers_touch before update on public.ins_insurers
  for each row execute function public.ins_touch_updated_at();
drop trigger if exists ins_clients_touch on public.ins_clients;
create trigger ins_clients_touch before update on public.ins_clients
  for each row execute function public.ins_touch_updated_at();
drop trigger if exists ins_policies_touch on public.ins_policies;
create trigger ins_policies_touch before update on public.ins_policies
  for each row execute function public.ins_touch_updated_at();
drop trigger if exists ins_claims_touch on public.ins_claims;
create trigger ins_claims_touch before update on public.ins_claims
  for each row execute function public.ins_touch_updated_at();

-- =====================================================================
-- H. Guard triggers
-- =====================================================================

-- H1. Party accounts are linked by ins_bind_policy only, and must belong to
--     the same tenant. Insurers.
create or replace function public.ins_insurers_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.party_account_id is distinct from old.party_account_id and not public.ins_via_rpc() then
    raise exception 'INS_PARTY_ACCOUNT_RPC_ONLY: the party account is managed by binding a policy' using errcode = '42501';
  end if;
  if new.party_account_id is not null and not exists (
    select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id
  ) then
    raise exception 'INS_CROSS_TENANT: party account belongs to another tenant';
  end if;
  return new;
end;
$$;

drop trigger if exists ins_insurers_guard_trg on public.ins_insurers;
create trigger ins_insurers_guard_trg before insert or update on public.ins_insurers
  for each row execute function public.ins_insurers_guard();

-- H2. Client profiles: the BD client must be in the same tenant; the party
--     account is RPC-only; client_id is immutable.
create or replace function public.ins_clients_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.client_id is distinct from old.client_id then
    raise exception 'INS_IMMUTABLE: the BD client link cannot be changed';
  end if;
  if tg_op = 'UPDATE' and new.party_account_id is distinct from old.party_account_id and not public.ins_via_rpc() then
    raise exception 'INS_PARTY_ACCOUNT_RPC_ONLY: the party account is managed by binding a policy' using errcode = '42501';
  end if;
  if not exists (select 1 from bd_clients c where c.id = new.client_id and c.tenant_id = new.tenant_id) then
    raise exception 'INS_CROSS_TENANT: the BD client belongs to another tenant';
  end if;
  if new.party_account_id is not null and not exists (
    select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id
  ) then
    raise exception 'INS_CROSS_TENANT: party account belongs to another tenant';
  end if;
  return new;
end;
$$;

drop trigger if exists ins_clients_guard_trg on public.ins_clients;
create trigger ins_clients_guard_trg before insert or update on public.ins_clients
  for each row execute function public.ins_clients_guard();

-- H3. Policies: inserts go through ins_create_policy (it allocates the policy
--     number). Status moves only through the RPCs. A bound policy is locked
--     except for notes. Every reference must be in the same tenant.
create or replace function public.ins_policies_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  return new;
end;
$$;

drop trigger if exists ins_policies_guard_trg on public.ins_policies;
create trigger ins_policies_guard_trg before insert or update on public.ins_policies
  for each row execute function public.ins_policies_guard();

-- H4. Claims: inserts and status moves go through the RPCs. Money fields are
--     RPC-only. Identity fields are immutable.
create or replace function public.ins_claims_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if not public.ins_via_rpc() then
      raise exception 'INS_RPC_ONLY: create claims with ins_create_claim()' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.claim_no is distinct from old.claim_no or new.policy_id is distinct from old.policy_id then
    raise exception 'INS_IMMUTABLE: a claim number and its policy cannot be changed';
  end if;
  if not public.ins_via_rpc() and (
    new.status is distinct from old.status
    or new.approved_amount is distinct from old.approved_amount
    or new.paid_amount is distinct from old.paid_amount
    or new.settled_at is distinct from old.settled_at
  ) then
    raise exception 'INS_CLAIM_RPC_ONLY: status and amounts change through ins_transition_claim()' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists ins_claims_guard_trg on public.ins_claims;
create trigger ins_claims_guard_trg before insert or update on public.ins_claims
  for each row execute function public.ins_claims_guard();

-- =====================================================================
-- I. Journal source types (the only change to an existing object)
-- =====================================================================
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type = any (array[
    'supplier_invoice', 'receivable_invoice', 'cash_bank_transaction', 'opening_balance', 'manual',
    'payroll_run', 'machine_fuel_log', 'machine_maintenance_request',
    'fin_settlement', 'fin_settlement_void',
    'fin_credit_note', 'fin_credit_note_void',
    'ins_policy_bind'
  ]));

-- =====================================================================
-- J. Internal helpers (not client-callable)
-- =====================================================================

-- Creates the client's party account on first bind and links it.
create or replace function public.ins_ensure_client_account(p_ins_client_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_client ins_clients%rowtype;
  v_name   text;
  v_acc    uuid;
begin
  select * into v_client from ins_clients where id = p_ins_client_id for update;
  if v_client.party_account_id is not null then
    return v_client.party_account_id;
  end if;
  select name into v_name from bd_clients where id = v_client.client_id;
  insert into accounts (tenant_id, account_code, name, account_type, is_active)
  values (
    v_client.tenant_id,
    next_doc_number(v_client.tenant_id, 'INS_CLIENT_ACCOUNT', 'CLI', 5),
    v_name, 'client', true
  )
  returning id into v_acc;
  perform set_config('ins.via_rpc', 'on', true);
  update ins_clients set party_account_id = v_acc where id = v_client.id;
  return v_acc;
end;
$$;

create or replace function public.ins_ensure_insurer_account(p_insurer_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ins ins_insurers%rowtype;
  v_acc uuid;
begin
  select * into v_ins from ins_insurers where id = p_insurer_id for update;
  if v_ins.party_account_id is not null then
    return v_ins.party_account_id;
  end if;
  insert into accounts (tenant_id, account_code, name, account_type, is_active)
  values (
    v_ins.tenant_id,
    next_doc_number(v_ins.tenant_id, 'INS_INSURER_ACCOUNT', 'INSA', 4),
    v_ins.name, 'vendor', true
  )
  returning id into v_acc;
  perform set_config('ins.via_rpc', 'on', true);
  update ins_insurers set party_account_id = v_acc where id = v_ins.id;
  return v_acc;
end;
$$;

revoke all on function public.ins_ensure_client_account(uuid) from public, anon, authenticated;
revoke all on function public.ins_ensure_insurer_account(uuid) from public, anon, authenticated;

-- =====================================================================
-- K. RPCs (client-callable)
-- =====================================================================

-- K1. Register a client: BD client master row plus its insurance profile.
create or replace function public.ins_register_client(
  p_name           text,
  p_client_type    text default 'corporate',
  p_tax_id         text default null,
  p_email          text default null,
  p_phone          text default null,
  p_risk_rating    text default 'medium'
)
returns public.ins_clients
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_bd_id  uuid;
  v_row    ins_clients%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if nullif(btrim(p_name), '') is null then
    raise exception 'INS_REQUIRED: client name is required';
  end if;

  insert into bd_clients (tenant_id, name, email, phone, created_by)
  values (v_tenant, btrim(p_name), nullif(btrim(p_email), ''), nullif(btrim(p_phone), ''), auth.uid())
  returning id into v_bd_id;

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_clients (tenant_id, client_id, client_type, tax_id, risk_rating, relationship_owner_id)
  values (v_tenant, v_bd_id, p_client_type, nullif(btrim(p_tax_id), ''), p_risk_rating, auth.uid())
  returning * into v_row;
  return v_row;
end;
$$;

-- K2. Create a draft policy. Allocates the policy number.
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

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_policies (
    tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
    inception_date, expiry_date, sum_insured, currency, gross_premium,
    commission_rate_pct, risk_description, notes
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_POLICY', 'POL', 5), p_client_id, p_insurer_id, p_product_line_id, 'draft',
    p_inception_date, p_expiry_date, coalesce(p_sum_insured, 0), coalesce(nullif(p_currency, ''), 'UGX'), coalesce(p_gross_premium, 0),
    p_commission_rate_pct, nullif(btrim(p_risk_description), ''), nullif(btrim(p_notes), '')
  )
  returning * into v_row;
  return v_row;
end;
$$;

-- K3. Open a renewal draft from an active policy. Same client, insurer and
--     product; the term is copied and starts on the old expiry date.
create or replace function public.ins_create_renewal_draft(p_policy_id uuid)
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
    commission_rate_pct, risk_description, renewal_of_id
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_POLICY', 'POL', 5), v_old.client_id, v_old.insurer_id, v_old.product_line_id, 'draft',
    v_old.expiry_date, v_old.expiry_date + v_term, v_old.sum_insured, v_old.currency, v_old.gross_premium,
    v_old.commission_rate_pct, v_old.risk_description, v_old.id
  )
  returning * into v_row;
  return v_row;
end;
$$;

-- K4. Bind a draft policy: accrue premium and commission, create the two open
--     items, and mark a renewal's predecessor as renewed. Atomic: any failure
--     (missing posting rule, closed period) rolls the whole bind back.
create or replace function public.ins_bind_policy(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pol        ins_policies%rowtype;
  v_client     ins_clients%rowtype;
  v_client_nm  text;
  v_comm       numeric(18,2);
  v_net        numeric(18,2);
  v_ar_acc     uuid;
  v_ins_acc    uuid;
  v_ar_gl      uuid;
  v_payable_gl uuid;
  v_comm_gl    uuid;
  v_lines      jsonb;
  v_je         journal_entries;
  v_desc       text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can bind policies' using errcode = '42501';
  end if;

  select * into v_pol from ins_policies where id = p_policy_id for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform assert_tenant_access(v_pol.tenant_id);

  if v_pol.status <> 'draft' then
    raise exception 'INS_NOT_DRAFT: policy % is already %', v_pol.policy_no, v_pol.status;
  end if;
  if v_pol.gross_premium <= 0 then
    raise exception 'INS_PREMIUM_REQUIRED: enter the gross premium before binding';
  end if;

  v_comm := round(v_pol.gross_premium * v_pol.commission_rate_pct / 100, 2);
  v_net  := v_pol.gross_premium - v_comm;
  if v_net <= 0 then
    raise exception 'INS_COMMISSION_TOO_HIGH: commission would leave nothing to remit to the insurer';
  end if;

  -- Posting roles from the tenant's chart. Missing roles stop the bind.
  v_ar_gl      := get_posting_account(v_pol.tenant_id, 'ar_control');
  v_payable_gl := get_posting_account(v_pol.tenant_id, 'insurer_payable');
  v_comm_gl    := get_posting_account(v_pol.tenant_id, 'commission_income');
  if v_ar_gl is null or v_payable_gl is null or (v_comm > 0 and v_comm_gl is null) then
    raise exception 'INS_POSTING_RULE_MISSING: the chart of accounts needs ar_control, insurer_payable and commission_income';
  end if;

  select * into v_client from ins_clients where id = v_pol.client_id;
  select name into v_client_nm from bd_clients where id = v_client.client_id;
  v_ar_acc  := ins_ensure_client_account(v_pol.client_id);
  v_ins_acc := ins_ensure_insurer_account(v_pol.insurer_id);

  v_desc := 'Bind ' || v_pol.policy_no || ' (' || coalesce(v_client_nm, 'client') || ')';
  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ar_gl, 'debit', v_pol.gross_premium, 'description', v_desc),
    jsonb_build_object('gl_account_id', v_payable_gl, 'credit', v_net, 'description', v_desc)
  );
  if v_comm > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_comm_gl, 'credit', v_comm, 'description', v_desc)
    );
  end if;

  -- Booked on the inception date, so the period-close check applies to it.
  v_je := post_journal_entry(v_pol.tenant_id, 'ins_policy_bind', v_pol.id, v_pol.inception_date, v_desc, v_lines);

  perform fin_create_open_item(
    v_pol.tenant_id, v_ar_acc, 'ar_control', 'ins_policy_premium', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_pol.gross_premium,
    'Premium due: ' || v_pol.policy_no
  );
  perform fin_create_open_item(
    v_pol.tenant_id, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_net,
    'Net premium payable to insurer: ' || v_pol.policy_no
  );

  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies
     set status = 'active',
         commission_amount = v_comm,
         net_premium_to_insurer = v_net,
         bound_at = now(),
         bound_by = auth.uid(),
         journal_entry_id = v_je.id
   where id = v_pol.id
  returning * into v_pol;

  if v_pol.renewal_of_id is not null then
    update ins_policies set status = 'renewed'
     where id = v_pol.renewal_of_id and tenant_id = v_pol.tenant_id and status = 'active';
  end if;

  return v_pol;
end;
$$;

-- K5. Register a claim against an active or renewed policy.
create or replace function public.ins_create_claim(
  p_policy_id         uuid,
  p_loss_date         date,
  p_notified_date     date,
  p_loss_description  text,
  p_insurer_claim_ref text default null,
  p_reserve_amount    numeric default 0
)
returns public.ins_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_pol    ins_policies%rowtype;
  v_row    ins_claims%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_pol from ins_policies where id = p_policy_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if v_pol.status = 'draft' then
    raise exception 'INS_CLAIM_STATE: a claim needs a bound policy';
  end if;
  if p_loss_date < v_pol.inception_date or p_loss_date > v_pol.expiry_date then
    raise exception 'INS_LOSS_OUTSIDE_POLICY: loss date % is outside the policy period % to %',
      p_loss_date, v_pol.inception_date, v_pol.expiry_date;
  end if;
  if nullif(btrim(p_loss_description), '') is null then
    raise exception 'INS_REQUIRED: describe the loss';
  end if;
  if coalesce(p_reserve_amount, 0) < 0 then
    raise exception 'INS_AMOUNT: reserve cannot be negative';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_claims (
    tenant_id, claim_no, policy_id, status, loss_date, notified_date,
    loss_description, insurer_claim_ref, reserve_amount
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_CLAIM', 'CLM', 5), v_pol.id, 'notified', p_loss_date,
    coalesce(p_notified_date, current_date), btrim(p_loss_description),
    nullif(btrim(p_insurer_claim_ref), ''), coalesce(p_reserve_amount, 0)
  )
  returning * into v_row;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_row.id, null, 'notified', 'Claim notified');
  return v_row;
end;
$$;

-- K6. Move a claim through its lifecycle. The state map is the only source of
--     truth for which moves are legal; the UI mirrors it for display only.
--     notified -> assessing -> approved -> settled -> closed
--     notified | assessing -> repudiated -> closed
create or replace function public.ins_transition_claim(
  p_claim_id uuid,
  p_to       text,
  p_note     text default null,
  p_amount   numeric default null
)
returns public.ins_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_from   text;
  v_sum    numeric;
  v_legal  boolean;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  v_from := v_claim.status;

  if p_to in ('approved', 'settled', 'repudiated', 'closed') and not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers decide claims' using errcode = '42501';
  end if;

  v_legal := (v_from, p_to) in (
    ('notified', 'assessing'), ('notified', 'repudiated'),
    ('assessing', 'approved'), ('assessing', 'repudiated'),
    ('approved', 'settled'),
    ('settled', 'closed'), ('repudiated', 'closed')
  );
  if not v_legal then
    raise exception 'INS_CLAIM_TRANSITION: a claim cannot move from % to %', v_from, p_to;
  end if;

  if p_to = 'repudiated' and nullif(btrim(p_note), '') is null then
    raise exception 'INS_NOTE_REQUIRED: give the reason for repudiating the claim';
  end if;

  perform set_config('ins.via_rpc', 'on', true);

  if p_to = 'approved' then
    if p_amount is null or p_amount <= 0 then
      raise exception 'INS_AMOUNT: approved amount must be greater than zero';
    end if;
    select sum_insured into v_sum from ins_policies where id = v_claim.policy_id;
    if v_sum > 0 and p_amount > v_sum then
      raise exception 'INS_AMOUNT: approved amount exceeds the policy sum insured';
    end if;
    update ins_claims set status = 'approved', approved_amount = p_amount
     where id = v_claim.id returning * into v_claim;
  elsif p_to = 'settled' then
    update ins_claims set status = 'settled', paid_amount = approved_amount, settled_at = now()
     where id = v_claim.id returning * into v_claim;
  else
    update ins_claims set status = p_to
     where id = v_claim.id returning * into v_claim;
  end if;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, v_from, p_to, nullif(btrim(p_note), ''));
  return v_claim;
end;
$$;

-- K7. Read helpers for the UI.
revoke all on function public.ins_register_client(text, text, text, text, text, text) from public, anon;
revoke all on function public.ins_create_policy(uuid, uuid, uuid, date, date, numeric, text, numeric, numeric, text, text) from public, anon;
revoke all on function public.ins_create_renewal_draft(uuid) from public, anon;
revoke all on function public.ins_bind_policy(uuid) from public, anon;
revoke all on function public.ins_create_claim(uuid, date, date, text, text, numeric) from public, anon;
revoke all on function public.ins_transition_claim(uuid, text, text, numeric) from public, anon;
grant execute on function public.ins_register_client(text, text, text, text, text, text) to authenticated;
grant execute on function public.ins_create_policy(uuid, uuid, uuid, date, date, numeric, text, numeric, numeric, text, text) to authenticated;
grant execute on function public.ins_create_renewal_draft(uuid) to authenticated;
grant execute on function public.ins_bind_policy(uuid) to authenticated;
grant execute on function public.ins_create_claim(uuid, date, date, text, text, numeric) to authenticated;
grant execute on function public.ins_transition_claim(uuid, text, text, numeric) to authenticated;

-- =====================================================================
-- L. Renewal pipeline (security_invoker: the caller's RLS applies, not the owner's)
-- =====================================================================
create or replace view public.ins_renewal_pipeline
with (security_invoker = true) as
select
  p.tenant_id,
  p.id                              as policy_id,
  p.policy_no,
  p.client_id                       as ins_client_id,
  bc.name                           as client_name,
  p.insurer_id,
  i.name                            as insurer_name,
  p.product_line_id,
  pl.name                           as product_name,
  p.inception_date,
  p.expiry_date,
  (p.expiry_date - current_date)    as days_to_expiry,
  p.gross_premium,
  p.commission_rate_pct,
  p.currency,
  (select d.id from ins_policies d
    where d.renewal_of_id = p.id and d.status = 'draft'
    limit 1)                        as renewal_draft_id
from ins_policies p
join ins_clients c      on c.id = p.client_id
join bd_clients bc      on bc.id = c.client_id
join ins_insurers i     on i.id = p.insurer_id
join ins_product_lines pl on pl.id = p.product_line_id
where p.status = 'active'
  and p.expiry_date <= current_date + 120;

-- =====================================================================
-- M. RLS and grants (split per verb; no FOR ALL)
-- =====================================================================
alter table public.ins_product_lines enable row level security;
alter table public.ins_insurers      enable row level security;
alter table public.ins_clients       enable row level security;
alter table public.ins_policies      enable row level security;
alter table public.ins_claims        enable row level security;
alter table public.ins_claim_events  enable row level security;

-- ins_product_lines
drop policy if exists ins_product_lines_select on public.ins_product_lines;
create policy ins_product_lines_select on public.ins_product_lines
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_product_lines_insert on public.ins_product_lines;
create policy ins_product_lines_insert on public.ins_product_lines
  for insert to authenticated with check (tenant_id = get_my_tenant_id() and can_manage_insurance());
drop policy if exists ins_product_lines_update on public.ins_product_lines;
create policy ins_product_lines_update on public.ins_product_lines
  for update to authenticated using (tenant_id = get_my_tenant_id() and can_manage_insurance())
  with check (tenant_id = get_my_tenant_id() and can_manage_insurance());
drop policy if exists ins_product_lines_delete on public.ins_product_lines;
create policy ins_product_lines_delete on public.ins_product_lines
  for delete to authenticated using (tenant_id = get_my_tenant_id() and can_manage_insurance());

-- ins_insurers
drop policy if exists ins_insurers_select on public.ins_insurers;
create policy ins_insurers_select on public.ins_insurers
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_insurers_insert on public.ins_insurers;
create policy ins_insurers_insert on public.ins_insurers
  for insert to authenticated with check (tenant_id = get_my_tenant_id() and can_manage_insurance());
drop policy if exists ins_insurers_update on public.ins_insurers;
create policy ins_insurers_update on public.ins_insurers
  for update to authenticated using (tenant_id = get_my_tenant_id() and can_manage_insurance())
  with check (tenant_id = get_my_tenant_id() and can_manage_insurance());
drop policy if exists ins_insurers_delete on public.ins_insurers;
create policy ins_insurers_delete on public.ins_insurers
  for delete to authenticated using (tenant_id = get_my_tenant_id() and can_manage_insurance());

-- ins_clients (members register and maintain profiles; only managers delete)
drop policy if exists ins_clients_select on public.ins_clients;
create policy ins_clients_select on public.ins_clients
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_clients_insert on public.ins_clients;
create policy ins_clients_insert on public.ins_clients
  for insert to authenticated with check (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_clients_update on public.ins_clients;
create policy ins_clients_update on public.ins_clients
  for update to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance())
  with check (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_clients_delete on public.ins_clients;
create policy ins_clients_delete on public.ins_clients
  for delete to authenticated using (tenant_id = get_my_tenant_id() and can_manage_insurance());

-- ins_policies (drafts are editable by members; bound policies are locked by the guard)
drop policy if exists ins_policies_select on public.ins_policies;
create policy ins_policies_select on public.ins_policies
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_policies_insert on public.ins_policies;
create policy ins_policies_insert on public.ins_policies
  for insert to authenticated with check (tenant_id = get_my_tenant_id() and can_access_insurance() and status = 'draft');
drop policy if exists ins_policies_update on public.ins_policies;
create policy ins_policies_update on public.ins_policies
  for update to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance() and status = 'draft')
  with check (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_policies_delete on public.ins_policies;
create policy ins_policies_delete on public.ins_policies
  for delete to authenticated using (tenant_id = get_my_tenant_id() and can_manage_insurance() and status = 'draft');

-- ins_claims
drop policy if exists ins_claims_select on public.ins_claims;
create policy ins_claims_select on public.ins_claims
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_claims_insert on public.ins_claims;
create policy ins_claims_insert on public.ins_claims
  for insert to authenticated with check (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_claims_update on public.ins_claims;
create policy ins_claims_update on public.ins_claims
  for update to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance())
  with check (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_claims_delete on public.ins_claims;
create policy ins_claims_delete on public.ins_claims
  for delete to authenticated using (tenant_id = get_my_tenant_id() and can_manage_insurance() and status = 'notified');

-- ins_claim_events: read-only for users; written by ins_transition_claim / ins_create_claim
drop policy if exists ins_claim_events_select on public.ins_claim_events;
create policy ins_claim_events_select on public.ins_claim_events
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());

-- Grants: no anon access to anything in this module.
revoke all on public.ins_product_lines from anon, public;
revoke all on public.ins_insurers      from anon, public;
revoke all on public.ins_clients       from anon, public;
revoke all on public.ins_policies      from anon, public;
revoke all on public.ins_claims        from anon, public;
revoke all on public.ins_claim_events  from anon, public;
revoke all on public.ins_renewal_pipeline from anon, public;

grant select, insert, update, delete on public.ins_product_lines to authenticated;
grant select, insert, update, delete on public.ins_insurers      to authenticated;
grant select, insert, update, delete on public.ins_clients       to authenticated;
grant select, insert, update, delete on public.ins_policies      to authenticated;
grant select, insert, update, delete on public.ins_claims        to authenticated;
grant select                         on public.ins_claim_events  to authenticated;
grant select                         on public.ins_renewal_pipeline to authenticated;
