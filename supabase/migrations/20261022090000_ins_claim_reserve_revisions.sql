-- Claims depth, slice 1: reserve revisions with a history.
--
-- A claim's reserve is the brokerage's running estimate of what the claim will cost. It was set
-- once, when the claim was registered, and nothing recorded it changing. Worse, the claims guard
-- protected status and the paid and approved amounts but not reserve_amount, so a member could
-- change it with a plain table update and leave no trace.
--
-- This slice:
--   * adds ins_claim_reserve_history, one row per reserve the claim has had: an 'initial' row
--     when the claim is registered (and backfilled for existing claims), then one 'revision' row
--     per change with the previous amount, the new amount and a reason;
--   * adds ins_revise_claim_reserve(claim, new_amount, reason), the only way to change a reserve;
--   * makes reserve_amount RPC-only in ins_claims_guard (same rule as status and amounts);
--   * writes the initial history row from an AFTER INSERT trigger, so every way a claim can be
--     created is covered without wrapping ins_create_claim again.
--
-- The reserve is informational: it posts nothing to the ledger and feeds the dashboard's open
-- reserves figure, so revising it needs no accounting treatment.

-- =====================================================================
-- A. History table
-- =====================================================================
create table if not exists public.ins_claim_reserve_history (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  claim_id        uuid not null,
  kind            text not null,
  previous_amount numeric(18,2),
  new_amount      numeric(18,2) not null,
  reason          text not null,
  revised_by      uuid default auth.uid(),
  revised_at      timestamptz not null default now(),
  constraint ins_claim_reserve_history_claim_fk foreign key (tenant_id, claim_id)
    references public.ins_claims (tenant_id, id) on delete restrict,
  constraint ins_claim_reserve_history_kind_check check (kind in ('initial', 'revision')),
  constraint ins_claim_reserve_history_amount_check check (new_amount >= 0 and (previous_amount is null or previous_amount >= 0)),
  constraint ins_claim_reserve_history_shape_check check (
    (kind = 'initial' and previous_amount is null) or (kind = 'revision' and previous_amount is not null and previous_amount <> new_amount)
  ),
  constraint ins_claim_reserve_history_reason_check check (char_length(btrim(reason)) >= 5)
);

create index if not exists ins_claim_reserve_history_claim_idx
  on public.ins_claim_reserve_history (tenant_id, claim_id, revised_at);

comment on table public.ins_claim_reserve_history is
  'Every reserve a claim has had, oldest first. Written only by ins_revise_claim_reserve and the claim insert trigger; never edited or deleted.';

create or replace function public.ins_claim_reserve_history_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: revise a claim reserve with ins_revise_claim_reserve()' using errcode = '42501';
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception 'INS_RESERVE_HISTORY_IMMUTABLE: reserve history is never edited or deleted';
  end if;
  return new;
end $$;

drop trigger if exists ins_claim_reserve_history_guard_trg on public.ins_claim_reserve_history;
create trigger ins_claim_reserve_history_guard_trg
  before insert or update or delete on public.ins_claim_reserve_history
  for each row execute function public.ins_claim_reserve_history_guard();

alter table public.ins_claim_reserve_history enable row level security;

drop policy if exists ins_claim_reserve_history_select on public.ins_claim_reserve_history;
create policy ins_claim_reserve_history_select on public.ins_claim_reserve_history
  for select using (tenant_id = get_my_tenant_id() and can_access_insurance());

revoke all on public.ins_claim_reserve_history from public, anon, authenticated;
grant select on public.ins_claim_reserve_history to authenticated;

-- =====================================================================
-- B. The initial row: written whenever a claim is inserted
-- =====================================================================
create or replace function public.ins_claims_initial_reserve()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_claim_reserve_history (tenant_id, claim_id, kind, previous_amount, new_amount, reason, revised_by)
  values (new.tenant_id, new.id, 'initial', null, new.reserve_amount, 'Initial reserve when the claim was registered', new.created_by);
  return new;
end $$;

drop trigger if exists ins_claims_initial_reserve_trg on public.ins_claims;
create trigger ins_claims_initial_reserve_trg
  after insert on public.ins_claims
  for each row execute function public.ins_claims_initial_reserve();

-- Existing claims get an initial row at their current reserve, dated when they were created.
-- It records what the reserve is today; earlier changes were never captured.
select set_config('ins.via_rpc', 'on', true);
insert into public.ins_claim_reserve_history (tenant_id, claim_id, kind, previous_amount, new_amount, reason, revised_by, revised_at)
select c.tenant_id, c.id, 'initial', null, c.reserve_amount, 'Reserve at the time history was introduced', c.created_by, c.created_at
  from public.ins_claims c
 where not exists (select 1 from public.ins_claim_reserve_history h where h.claim_id = c.id and h.tenant_id = c.tenant_id);
select set_config('ins.via_rpc', '', true);

-- =====================================================================
-- C. Reserve changes are RPC-only
--    (the body is the latest guard, from 20261013090000, plus reserve_amount)
-- =====================================================================
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
    or new.payment_mode is distinct from old.payment_mode
    or new.reserve_amount is distinct from old.reserve_amount
  ) then
    raise exception 'INS_CLAIM_RPC_ONLY: status, amounts, reserve and payment mode change through the claim functions' using errcode = '42501';
  end if;

  if new.loss_date is distinct from old.loss_date and not exists (
    select 1 from ins_policies p
     where p.id = new.policy_id and p.tenant_id = new.tenant_id
       and new.loss_date between p.inception_date and p.expiry_date
  ) then
    raise exception 'INS_LOSS_OUTSIDE_POLICY: loss date % is outside the policy period', new.loss_date;
  end if;
  return new;
end;
$$;

-- =====================================================================
-- D. Revise a reserve
-- =====================================================================
create or replace function public.ins_revise_claim_reserve(p_claim_id uuid, p_new_amount numeric, p_reason text)
returns public.ins_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_sum    numeric;
  v_new    numeric(18,2);
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if p_new_amount is null or p_new_amount < 0 then
    raise exception 'INS_AMOUNT: the reserve cannot be negative';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then
    raise exception 'INS_RESERVE_REASON: give a reason of at least 5 characters';
  end if;
  v_new := round(p_new_amount, 2);

  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if v_claim.status not in ('notified', 'assessing', 'approved') then
    raise exception 'INS_CLAIM_STATE: the reserve of a % claim cannot be revised', v_claim.status;
  end if;
  if v_new = v_claim.reserve_amount then
    raise exception 'INS_RESERVE_UNCHANGED: the reserve is already %', v_claim.reserve_amount;
  end if;
  select sum_insured into v_sum from ins_policies where id = v_claim.policy_id and tenant_id = v_tenant;
  if coalesce(v_sum, 0) > 0 and v_new > v_sum then
    raise exception 'INS_AMOUNT: the reserve cannot exceed the policy sum insured';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_claim_reserve_history (tenant_id, claim_id, kind, previous_amount, new_amount, reason)
  values (v_tenant, v_claim.id, 'revision', v_claim.reserve_amount, v_new, btrim(p_reason));
  update ins_claims set reserve_amount = v_new where id = v_claim.id returning * into v_claim;
  return v_claim;
end $$;

-- =====================================================================
-- E. Grants
-- =====================================================================
revoke all on function public.ins_claim_reserve_history_guard() from public, anon, authenticated, service_role;
revoke all on function public.ins_claims_initial_reserve() from public, anon, authenticated, service_role;
revoke all on function public.ins_revise_claim_reserve(uuid, numeric, text) from public, anon;
grant execute on function public.ins_revise_claim_reserve(uuid, numeric, text) to authenticated;

-- The new table carries a tenant_id, so it gets the platform read-only guard.
select public.apply_tenant_read_only_guard();
