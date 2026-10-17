-- Phase C, agents and sub-agents, slice 1: the intermediary register. No money.
--
-- An intermediary is a person or business that distributes insurance. The category says what
-- the relationship is; it does not, by itself, give legal permission to do regulated work.
--
--   insurer_appointed_agent  appointed by an insurer; needs a licence AND an appointment reference
--   independent_broker       an intermediary arranging insurance for clients; needs a licence
--   sub_agent                placed under a parent that is active and authorised; needs a licence
--                            and recorded evidence that the parent may appoint it
--   referral_partner         introduces clients only; no licence needed, and it may not be a parent
--
-- Design defaults (for the compliance adviser to confirm):
--   * A licence is recorded separately from an insurer's appointment. Both are required for an
--     insurer-appointed agent, because the roadmap treats them as different things.
--   * No maximum depth is set. A sub-agent's parent must be active and must not be a referral partner.
--     The parent chain must not loop.
--   * Any change to a credential, category or parent sends the record back to
--     pending_verification. The person who last changed a record cannot verify it.
--   * Nothing here posts to the ledger. Commission and withholding come in slice 3.
--
-- Writes go through RPCs only. Clients have select on their own company's rows.

-- =====================================================================
-- Tables
-- =====================================================================

create table if not exists public.ins_intermediaries (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenants(id) on delete cascade,
  code                    text not null,
  kind                    text not null default 'business',
  name                    text not null,
  category                text not null,
  contact_email           text,
  contact_phone           text,
  parent_id               uuid,
  licence_ref             text,
  licence_authority       text,
  licence_valid_from      date,
  licence_valid_to        date,
  appointment_ref         text,
  authorisation_basis     text,
  authorisation_reference text,
  status                  text not null default 'pending_verification',
  created_by              uuid default auth.uid(),
  last_changed_by         uuid default auth.uid(),
  last_changed_at         timestamptz not null default now(),
  verified_by             uuid,
  verified_at             timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint ins_intermediaries_tenant_id_id_key unique (tenant_id, id),
  constraint ins_intermediaries_code_key unique (tenant_id, code),
  constraint ins_intermediaries_parent_fk foreign key (tenant_id, parent_id)
    references public.ins_intermediaries (tenant_id, id) on delete restrict,
  constraint ins_intermediaries_kind_check check (kind in ('individual', 'business')),
  constraint ins_intermediaries_category_check check (
    category in ('insurer_appointed_agent', 'independent_broker', 'sub_agent', 'referral_partner')),
  constraint ins_intermediaries_status_check check (
    status in ('pending_verification', 'active', 'suspended', 'expired', 'terminated')),
  constraint ins_intermediaries_sub_parent_check check (category <> 'sub_agent' or parent_id is not null),
  constraint ins_intermediaries_not_self_check check (parent_id is null or parent_id <> id),
  constraint ins_intermediaries_licence_dates_check check (
    licence_valid_to is null or licence_valid_from is null or licence_valid_to >= licence_valid_from)
);

create index if not exists ins_intermediaries_tenant_status_idx on public.ins_intermediaries (tenant_id, status);
create index if not exists ins_intermediaries_parent_idx on public.ins_intermediaries (tenant_id, parent_id);

create table if not exists public.ins_intermediary_events (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  intermediary_id uuid not null,
  action          text not null,
  from_status     text,
  to_status       text,
  note            text,
  actor_id        uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  constraint ins_intermediary_events_fk foreign key (tenant_id, intermediary_id)
    references public.ins_intermediaries (tenant_id, id) on delete restrict
);

create index if not exists ins_intermediary_events_idx on public.ins_intermediary_events (tenant_id, intermediary_id);

alter table public.ins_intermediaries enable row level security;
alter table public.ins_intermediary_events enable row level security;

drop policy if exists ins_intermediaries_select on public.ins_intermediaries;
create policy ins_intermediaries_select on public.ins_intermediaries
  for select to authenticated
  using (tenant_id = get_my_tenant_id() and can_access_insurance());

drop policy if exists ins_intermediary_events_select on public.ins_intermediary_events;
create policy ins_intermediary_events_select on public.ins_intermediary_events
  for select to authenticated
  using (tenant_id = get_my_tenant_id() and can_access_insurance());

revoke all on public.ins_intermediaries from public, anon, authenticated;
revoke all on public.ins_intermediary_events from public, anon, authenticated;
grant select on public.ins_intermediaries to authenticated;
grant select on public.ins_intermediary_events to authenticated;

-- =====================================================================
-- Internal helpers
-- =====================================================================

-- True if `candidate` is `start` or lies above it in the parent chain.
create or replace function public.ins_intermediary_chain_has(p_tenant uuid, p_start uuid, p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with recursive chain(id, parent_id, depth) as (
    select i.id, i.parent_id, 0 from ins_intermediaries i where i.tenant_id = p_tenant and i.id = p_start
    union all
    select p.id, p.parent_id, c.depth + 1
      from chain c join ins_intermediaries p on p.tenant_id = p_tenant and p.id = c.parent_id
     where c.depth < 100
  )
  select exists (select 1 from chain where id = p_target);
$$;

revoke all on function public.ins_intermediary_chain_has(uuid, uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- RPCs
-- =====================================================================

create or replace function public.ins_save_intermediary(
  p_id                      uuid default null,
  p_code                    text default null,
  p_kind                    text default 'business',
  p_name                    text default null,
  p_category                text default null,
  p_contact_email           text default null,
  p_contact_phone           text default null,
  p_parent_id               uuid default null,
  p_licence_ref             text default null,
  p_licence_authority       text default null,
  p_licence_valid_from      date default null,
  p_licence_valid_to        date default null,
  p_appointment_ref         text default null,
  p_authorisation_basis     text default null,
  p_authorisation_reference text default null
)
returns public.ins_intermediaries
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_row     ins_intermediaries%rowtype;
  v_old     ins_intermediaries%rowtype;
  v_parent  ins_intermediaries%rowtype;
  v_code    text := nullif(btrim(p_code), '');
  v_name    text := nullif(btrim(p_name), '');
  v_ref     text := nullif(btrim(p_licence_ref), '');
  v_auth    text := nullif(btrim(p_licence_authority), '');
  v_appt    text := nullif(btrim(p_appointment_ref), '');
  v_basis   text := nullif(btrim(p_authorisation_basis), '');
  v_aref    text := nullif(btrim(p_authorisation_reference), '');
  v_email   text := nullif(btrim(p_contact_email), '');
  v_phone   text := nullif(btrim(p_contact_phone), '');
  v_changed boolean := false;
  v_status_before text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers maintain intermediaries' using errcode = '42501';
  end if;

  if p_id is not null then
    select * into v_old from ins_intermediaries where id = p_id and tenant_id = v_tenant for update;
    if not found then
      raise exception 'INS_NOT_FOUND: intermediary';
    end if;
    if v_old.status = 'terminated' then
      raise exception 'INS_TERMINATED: a terminated intermediary cannot be changed';
    end if;
  end if;

  if v_code is null then raise exception 'INS_REQUIRED: give the intermediary a reference code'; end if;
  if v_name is null then raise exception 'INS_REQUIRED: give the intermediary a name'; end if;
  if p_kind not in ('individual', 'business') then raise exception 'INS_INVALID: kind must be individual or business'; end if;
  if p_category not in ('insurer_appointed_agent', 'independent_broker', 'sub_agent', 'referral_partner') then
    raise exception 'INS_INVALID: unknown category %', p_category;
  end if;

  -- Credentials. A referral partner needs none. Every other category needs a licence.
  if p_category <> 'referral_partner' then
    if v_ref is null or v_auth is null or p_licence_valid_to is null then
      raise exception 'INS_REQUIRED: a licence needs its reference, issuing authority and expiry date';
    end if;
    if p_licence_valid_to < current_date then
      raise exception 'INS_LICENCE_EXPIRED: the licence has already expired';
    end if;
    if p_licence_valid_from is not null and p_licence_valid_to < p_licence_valid_from then
      raise exception 'INS_INVALID: the licence expiry is before its start date';
    end if;
  end if;

  if p_category = 'insurer_appointed_agent' and v_appt is null then
    raise exception 'INS_REQUIRED: an insurer-appointed agent needs the insurer''s appointment reference';
  end if;

  -- Parent link.
  if p_category = 'sub_agent' then
    if p_parent_id is null then
      raise exception 'INS_PARENT_REQUIRED: a sub-agent must be placed under a parent intermediary';
    end if;
    if v_basis is null or v_aref is null then
      raise exception 'INS_AUTHORISATION_REQUIRED: record the basis on which the parent may appoint this sub-agent, and its reference';
    end if;
  end if;

  if p_parent_id is not null then
    select * into v_parent from ins_intermediaries where id = p_parent_id and tenant_id = v_tenant;
    if not found then
      raise exception 'INS_NOT_FOUND: parent intermediary';
    end if;
    if v_parent.status <> 'active' then
      raise exception 'INS_PARENT_NOT_ACTIVE: the parent must be verified and active before it can be linked (it is %)', v_parent.status;
    end if;
    if v_parent.category = 'referral_partner' then
      raise exception 'INS_PARENT_CATEGORY: a referral partner cannot appoint or be a parent';
    end if;
    if p_id is not null and ins_intermediary_chain_has(v_tenant, p_parent_id, p_id) then
      raise exception 'INS_CYCLE: that parent sits below this intermediary in the chain';
    end if;
  end if;

  if p_id is null then
    insert into ins_intermediaries (
      tenant_id, code, kind, name, category, contact_email, contact_phone, parent_id,
      licence_ref, licence_authority, licence_valid_from, licence_valid_to, appointment_ref,
      authorisation_basis, authorisation_reference, status, last_changed_by, last_changed_at)
    values (
      v_tenant, v_code, p_kind, v_name, p_category, v_email, v_phone, p_parent_id,
      v_ref, v_auth, p_licence_valid_from, p_licence_valid_to, v_appt,
      v_basis, v_aref, 'pending_verification', auth.uid(), now())
    returning * into v_row;

    insert into ins_intermediary_events (tenant_id, intermediary_id, action, to_status, note)
    values (v_tenant, v_row.id, 'created', 'pending_verification', null);
    return v_row;
  end if;

  -- Update. Any change to a credential, category or parent means it must be verified again.
  v_changed := (v_old.category, v_old.parent_id, v_old.licence_ref, v_old.licence_authority,
                v_old.licence_valid_from, v_old.licence_valid_to, v_old.appointment_ref,
                v_old.authorisation_basis, v_old.authorisation_reference)
               is distinct from
               (p_category, p_parent_id, v_ref, v_auth, p_licence_valid_from, p_licence_valid_to, v_appt,
                v_basis, v_aref);
  v_status_before := v_old.status;

  update ins_intermediaries set
    code = v_code, kind = p_kind, name = v_name, category = p_category,
    contact_email = v_email, contact_phone = v_phone, parent_id = p_parent_id,
    licence_ref = v_ref, licence_authority = v_auth,
    licence_valid_from = p_licence_valid_from, licence_valid_to = p_licence_valid_to,
    appointment_ref = v_appt, authorisation_basis = v_basis, authorisation_reference = v_aref,
    status = case when v_changed then 'pending_verification' else status end,
    verified_by = case when v_changed then null else verified_by end,
    verified_at = case when v_changed then null else verified_at end,
    last_changed_by = auth.uid(), last_changed_at = now(), updated_at = now()
  where id = p_id and tenant_id = v_tenant
  returning * into v_row;

  if v_changed then
    insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
    values (v_tenant, v_row.id, 'changed', v_status_before, 'pending_verification',
            'Credentials, category or parent changed: verification required again');
  else
    insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
    values (v_tenant, v_row.id, 'edited', v_status_before, v_status_before, 'Details edited');
  end if;
  return v_row;
end;
$$;

create or replace function public.ins_verify_intermediary(p_id uuid, p_note text default null)
returns public.ins_intermediaries
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_row    ins_intermediaries%rowtype;
  v_parent_status text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers verify intermediaries' using errcode = '42501';
  end if;
  select * into v_row from ins_intermediaries where id = p_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: intermediary';
  end if;
  if v_row.status <> 'pending_verification' then
    raise exception 'INS_STATE: only a pending intermediary can be verified (this one is %)', v_row.status;
  end if;
  if v_row.last_changed_by is not null and v_row.last_changed_by = auth.uid() then
    raise exception 'INS_SEGREGATION: the person who last changed this record cannot verify it; another manager must';
  end if;
  if v_row.licence_valid_to is not null and v_row.licence_valid_to < current_date then
    raise exception 'INS_LICENCE_EXPIRED: the licence has expired, so the intermediary cannot be verified';
  end if;
  if v_row.parent_id is not null then
    select status into v_parent_status from ins_intermediaries where id = v_row.parent_id and tenant_id = v_tenant;
    if v_parent_status is distinct from 'active' then
      raise exception 'INS_PARENT_NOT_ACTIVE: the parent must be active before this sub-agent can be verified';
    end if;
  end if;

  update ins_intermediaries set status = 'active', verified_by = auth.uid(), verified_at = now(), updated_at = now()
   where id = v_row.id returning * into v_row;
  insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
  values (v_tenant, v_row.id, 'verified', 'pending_verification', 'active', nullif(btrim(p_note), ''));
  return v_row;
end;
$$;

create or replace function public.ins_set_intermediary_status(p_id uuid, p_to text, p_note text default null)
returns public.ins_intermediaries
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_row    ins_intermediaries%rowtype;
  v_from   text;
  v_note   text := nullif(btrim(p_note), '');
  v_active_children integer;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers change intermediary status' using errcode = '42501';
  end if;
  select * into v_row from ins_intermediaries where id = p_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: intermediary';
  end if;
  v_from := v_row.status;

  -- Moves allowed here. Pending to active is verification; expired to active needs re-verification.
  if not (
       (v_from = 'active' and p_to in ('suspended', 'expired', 'terminated'))
    or (v_from = 'suspended' and p_to in ('active', 'terminated'))
    or (v_from = 'expired' and p_to = 'terminated')
    or (v_from = 'pending_verification' and p_to = 'terminated')
  ) then
    raise exception 'INS_STATE: an intermediary cannot move from % to %', v_from, p_to;
  end if;

  if p_to in ('suspended', 'terminated') and v_note is null then
    raise exception 'INS_NOTE_REQUIRED: give the reason for suspending or terminating';
  end if;
  if p_to = 'suspended' and v_from = 'suspended' then
    raise exception 'INS_STATE: already suspended';
  end if;

  if p_to = 'expired' and (v_row.licence_valid_to is null or v_row.licence_valid_to >= current_date) then
    raise exception 'INS_NOT_EXPIRED: the licence has not passed its expiry date';
  end if;

  if p_to = 'active' and v_from = 'suspended' and v_row.licence_valid_to is not null and v_row.licence_valid_to < current_date then
    raise exception 'INS_LICENCE_EXPIRED: the licence has expired; renew it before reinstating';
  end if;

  if p_to = 'terminated' then
    select count(*) into v_active_children from ins_intermediaries
     where tenant_id = v_tenant and parent_id = v_row.id and status in ('active', 'suspended', 'pending_verification');
    if v_active_children > 0 then
      raise exception 'INS_HAS_SUBAGENTS: % sub-agent(s) still sit under this intermediary; end or move them first', v_active_children;
    end if;
  end if;

  update ins_intermediaries set status = p_to, updated_at = now() where id = v_row.id returning * into v_row;
  insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
  values (v_tenant, v_row.id, 'status', v_from, p_to, v_note);
  return v_row;
end;
$$;

revoke all on function public.ins_save_intermediary(uuid, text, text, text, text, text, text, uuid, text, text, date, date, text, text, text) from public, anon;
revoke all on function public.ins_verify_intermediary(uuid, text) from public, anon;
revoke all on function public.ins_set_intermediary_status(uuid, text, text) from public, anon;
grant execute on function public.ins_save_intermediary(uuid, text, text, text, text, text, text, uuid, text, text, date, date, text, text, text) to authenticated;
grant execute on function public.ins_verify_intermediary(uuid, text) to authenticated;
grant execute on function public.ins_set_intermediary_status(uuid, text, text) to authenticated;

-- Tenant read-only guard, like the other insurance tables.
select public.apply_tenant_read_only_guard();
