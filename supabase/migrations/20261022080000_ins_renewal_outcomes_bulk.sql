-- Renewals, part 2: renewal outcomes and bulk renewal drafts.
--
-- Until now the renewal screen could only open one draft at a time, and a policy the client
-- would not renew sat in the pipeline until it expired. This adds:
--
--   ins_renewal_outcomes   one row per active policy the brokerage has stopped chasing, with why:
--                            lost      placed with another broker or insurer
--                            declined  the client chose not to renew
--                            lapsed    no response, allowed to expire
--                          (A policy that is renewed needs no row: its status becomes 'renewed'.)
--                          Written only by the RPCs below. A row is never edited; changing a
--                          decision records a new one, and clearing is a manager action.
--   ins_record_renewal_outcome(policy, outcome, reason)   any insurance user
--   ins_clear_renewal_outcome(policy)                     insurance manager or admin
--   ins_create_renewal_drafts(policy_ids[])               bulk: one result per policy, a failure on
--                                                         one policy never blocks the others
--
-- ins_create_renewal_draft() is wrapped once more (same pattern as the co-insurance wrapper) so a
-- policy with a recorded outcome cannot be renewed until the outcome is cleared. The bulk RPC calls
-- the wrapper, so it inherits every existing rule.
--
-- ins_renewal_pipeline gains renewal_outcome and renewal_outcome_reason at the END of its column
-- list, so create or replace view keeps its existing columns, grants and callers.

-- =====================================================================
-- A. Outcomes table
-- =====================================================================
create table if not exists public.ins_renewal_outcomes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  policy_id   uuid not null,
  outcome     text not null,
  reason      text not null,
  recorded_by uuid default auth.uid(),
  recorded_at timestamptz not null default now(),
  constraint ins_renewal_outcomes_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete restrict,
  constraint ins_renewal_outcomes_policy_key unique (tenant_id, policy_id),
  constraint ins_renewal_outcomes_outcome_check check (outcome in ('lost', 'declined', 'lapsed')),
  constraint ins_renewal_outcomes_reason_check check (char_length(btrim(reason)) >= 5)
);

comment on table public.ins_renewal_outcomes is
  'Why an active policy is not being renewed. One row per policy; written only by ins_record_renewal_outcome / ins_clear_renewal_outcome.';

create or replace function public.ins_renewal_outcomes_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: record renewal outcomes with ins_record_renewal_outcome()' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    raise exception 'INS_OUTCOME_IMMUTABLE: a renewal outcome is not edited; record a new one or clear it';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end $$;

drop trigger if exists ins_renewal_outcomes_guard_trg on public.ins_renewal_outcomes;
create trigger ins_renewal_outcomes_guard_trg
  before insert or update or delete on public.ins_renewal_outcomes
  for each row execute function public.ins_renewal_outcomes_guard();

alter table public.ins_renewal_outcomes enable row level security;

drop policy if exists ins_renewal_outcomes_select on public.ins_renewal_outcomes;
create policy ins_renewal_outcomes_select on public.ins_renewal_outcomes
  for select using (tenant_id = get_my_tenant_id() and can_access_insurance());

revoke all on public.ins_renewal_outcomes from public, anon, authenticated;
grant select on public.ins_renewal_outcomes to authenticated;

-- =====================================================================
-- B. Record and clear an outcome
-- =====================================================================
create or replace function public.ins_record_renewal_outcome(p_policy_id uuid, p_outcome text, p_reason text)
returns public.ins_renewal_outcomes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_pol    ins_policies%rowtype;
  v_row    ins_renewal_outcomes%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if p_outcome is null or p_outcome not in ('lost', 'declined', 'lapsed') then
    raise exception 'INS_OUTCOME_INVALID: choose lost, declined or lapsed';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then
    raise exception 'INS_OUTCOME_REASON: give a reason of at least 5 characters';
  end if;

  select * into v_pol from ins_policies where id = p_policy_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if v_pol.status <> 'active' then
    raise exception 'INS_RENEWAL_STATE: only an active policy can have a renewal outcome (this one is %)', v_pol.status;
  end if;
  if exists (select 1 from ins_policies where renewal_of_id = v_pol.id and status = 'draft') then
    raise exception 'INS_RENEWAL_EXISTS: a renewal draft is already open for %; finish or discard it first', v_pol.policy_no;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  delete from ins_renewal_outcomes where tenant_id = v_tenant and policy_id = v_pol.id;
  insert into ins_renewal_outcomes (tenant_id, policy_id, outcome, reason)
  values (v_tenant, v_pol.id, p_outcome, btrim(p_reason))
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.ins_clear_renewal_outcome(p_policy_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can clear a renewal outcome' using errcode = '42501';
  end if;
  perform set_config('ins.via_rpc', 'on', true);
  delete from ins_renewal_outcomes where tenant_id = v_tenant and policy_id = p_policy_id;
  if not found then
    raise exception 'INS_NOT_FOUND: no renewal outcome is recorded for this policy';
  end if;
end $$;

-- =====================================================================
-- C. A policy with an outcome cannot be renewed until the outcome is cleared
-- =====================================================================
alter function public.ins_create_renewal_draft(uuid) rename to platform_ins_create_renewal_pre_outcome_impl;
revoke all on function public.platform_ins_create_renewal_pre_outcome_impl(uuid) from public, anon, authenticated;

create function public.ins_create_renewal_draft(p_policy_id uuid)
returns public.ins_policies
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if exists (select 1 from ins_renewal_outcomes where tenant_id = get_my_tenant_id() and policy_id = p_policy_id) then
    raise exception 'INS_RENEWAL_CLOSED: a renewal outcome is recorded for this policy; clear it before starting a renewal';
  end if;
  return platform_ins_create_renewal_pre_outcome_impl(p_policy_id);
end $$;

-- =====================================================================
-- D. Bulk renewal drafts
-- =====================================================================
-- Returns a JSON array with one element per policy:
--   { policy_id, policy_no, ok, draft_id }          when the draft was opened
--   { policy_id, policy_no, ok: false, error }      when it was refused, with the reason
-- Each policy runs in its own sub-transaction, so one refusal rolls back only that policy.
create or replace function public.ins_create_renewal_drafts(p_policy_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_ids    uuid[];
  v_id     uuid;
  v_no     text;
  v_draft  ins_policies%rowtype;
  v_out    jsonb := '[]'::jsonb;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_ids from unnest(p_policy_ids) as x where x is not null;
  if cardinality(v_ids) = 0 then
    raise exception 'INS_BULK_EMPTY: choose at least one policy';
  end if;
  if cardinality(v_ids) > 100 then
    raise exception 'INS_BULK_LIMIT: renew at most 100 policies at a time';
  end if;

  foreach v_id in array v_ids loop
    select policy_no into v_no from ins_policies where id = v_id and tenant_id = v_tenant;
    begin
      v_draft := public.ins_create_renewal_draft(v_id);
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'policy_id', v_id, 'policy_no', v_no, 'ok', true, 'draft_id', v_draft.id));
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'policy_id', v_id, 'policy_no', v_no, 'ok', false, 'error', sqlerrm));
    end;
  end loop;
  return v_out;
end $$;

-- =====================================================================
-- E. Pipeline view: outcome columns added at the end
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
    limit 1)                        as renewal_draft_id,
  (select o.outcome from ins_renewal_outcomes o
    where o.policy_id = p.id and o.tenant_id = p.tenant_id)        as renewal_outcome,
  (select o.reason from ins_renewal_outcomes o
    where o.policy_id = p.id and o.tenant_id = p.tenant_id)        as renewal_outcome_reason
from ins_policies p
join ins_clients c      on c.id = p.client_id
join bd_clients bc      on bc.id = c.client_id
join ins_insurers i     on i.id = p.insurer_id
join ins_product_lines pl on pl.id = p.product_line_id
where p.status = 'active'
  and p.expiry_date <= current_date + 120;

-- =====================================================================
-- F. Grants
-- =====================================================================
revoke all on function public.ins_renewal_outcomes_guard() from public, anon, authenticated;
revoke all on function public.ins_record_renewal_outcome(uuid, text, text) from public, anon;
revoke all on function public.ins_clear_renewal_outcome(uuid) from public, anon;
revoke all on function public.ins_create_renewal_draft(uuid) from public, anon;
revoke all on function public.ins_create_renewal_drafts(uuid[]) from public, anon;
grant execute on function public.ins_record_renewal_outcome(uuid, text, text) to authenticated;
grant execute on function public.ins_clear_renewal_outcome(uuid) to authenticated;
grant execute on function public.ins_create_renewal_draft(uuid) to authenticated;
grant execute on function public.ins_create_renewal_drafts(uuid[]) to authenticated;

-- The new table carries a tenant_id, so it gets the platform read-only guard.
select public.apply_tenant_read_only_guard();
