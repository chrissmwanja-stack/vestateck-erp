-- =====================================================================
-- Insurance brokerage, slice Q3: policy approval workflow
--
-- draft -> pending_approval -> approved | rejected (-> draft)
-- Binding (ins_bind_policy) now requires status = 'approved'.
--
-- Audit trail in ins_policy_approvals; writes only via RPCs; tenant RLS
-- on reads. NOTE: this tightens bind — SQL tests and flows that bind a
-- draft directly must submit + approve first.
-- =====================================================================

-- Extend the status enum (constraint swap, not a DROP COLUMN/TABLE).
alter table public.ins_policies drop constraint if exists ins_policies_status_check;
alter table public.ins_policies add constraint ins_policies_status_check
  check (status in ('draft', 'pending_approval', 'approved', 'rejected', 'active', 'renewed'));

-- The bound-check must allow the new pre-bind statuses without bind fields.
alter table public.ins_policies drop constraint if exists ins_policies_bound_check;
alter table public.ins_policies add constraint ins_policies_bound_check
  check (
    status in ('draft', 'pending_approval', 'approved', 'rejected')
    or (
      gross_premium > 0
      and commission_amount is not null
      and net_premium_to_insurer is not null
      and commission_amount + net_premium_to_insurer = gross_premium
      and bound_at is not null
    )
  );

-- =====================================================================
-- Approval audit trail
-- =====================================================================
create table if not exists public.ins_policy_approvals (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  policy_id  uuid not null,
  action     text not null check (action in ('submitted', 'approved', 'rejected')),
  actor_id   uuid not null default auth.uid(),
  note       text,
  created_at timestamptz not null default now(),
  constraint ins_policy_approvals_tenant_id_id_key unique (tenant_id, id),
  constraint ins_policy_approvals_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete cascade
);

create index if not exists ins_policy_approvals_policy_idx
  on public.ins_policy_approvals (tenant_id, policy_id, created_at);

alter table public.ins_policy_approvals enable row level security;

create policy "ins_policy_approvals_select" on public.ins_policy_approvals
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

-- Writes only via the RPCs below.
revoke all on public.ins_policy_approvals from public, anon;

-- =====================================================================
-- Bind guard: a policy may become active/renewed only from 'approved'.
-- (ins_bind_policy sets status directly, so a BEFORE UPDATE trigger is
-- the enforcement point; RPC-only DML is not in place for ins_policies,
-- drafts are member-editable.)
-- =====================================================================
create or replace function public.ins_policy_bind_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- ins_bind_policy flips approved -> active; anything else trying to
  -- activate a policy is refused.
  if new.status in ('active', 'renewed') and old.status <> 'approved' then
    raise exception 'INS_NOT_APPROVED: policy % must be approved before binding (status is %)', old.policy_no, old.status;
  end if;
  return new;
end;
$$;

revoke all on function public.ins_policy_bind_guard() from public, anon, authenticated, service_role;
drop trigger if exists trg_ins_policy_bind_guard on public.ins_policies;
create trigger trg_ins_policy_bind_guard
  before update on public.ins_policies
  for each row execute function public.ins_policy_bind_guard();

-- =====================================================================
-- RPCs
-- =====================================================================

-- draft -> pending_approval (any insurance member)
create or replace function public.ins_submit_policy_for_approval(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_pol public.ins_policies;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_pol from public.ins_policies
  where tenant_id = v_tenant and id = p_policy_id for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if v_pol.status <> 'draft' then
    raise exception 'INS_NOT_DRAFT: policy % is %', v_pol.policy_no, v_pol.status;
  end if;
  if v_pol.gross_premium <= 0 then
    raise exception 'INS_PREMIUM_REQUIRED: enter the gross premium before submitting';
  end if;

  set local ins.via_rpc = 'on';
  update public.ins_policies
  set status = 'pending_approval', updated_at = now()
  where tenant_id = v_tenant and id = p_policy_id
  returning * into v_pol;
  insert into public.ins_policy_approvals (tenant_id, policy_id, action, actor_id, note)
  values (v_tenant, p_policy_id, 'submitted', auth.uid(), null);
  reset ins.via_rpc;

  return v_pol;
end;
$$;

revoke all on function public.ins_submit_policy_for_approval(uuid) from public, anon;
grant execute on function public.ins_submit_policy_for_approval(uuid) to authenticated;

-- pending_approval -> approved | rejected (manager tier; rejected returns to draft)
create or replace function public.ins_decide_policy(
  p_policy_id uuid,
  p_decision text,
  p_note text default null
)
returns public.ins_policies
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_pol public.ins_policies;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'INS_BAD_DECISION';
  end if;

  select * into v_pol from public.ins_policies
  where tenant_id = v_tenant and id = p_policy_id for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if v_pol.status <> 'pending_approval' then
    raise exception 'INS_NOT_PENDING: policy % is %', v_pol.policy_no, v_pol.status;
  end if;
  -- segregation of duties: the submitter cannot approve their own policy
  if exists (
    select 1 from public.ins_policy_approvals a
    where a.tenant_id = v_tenant and a.policy_id = p_policy_id
      and a.action = 'submitted' and a.actor_id = auth.uid()
  ) then
    raise exception 'INS_SELF_APPROVAL: the submitter cannot decide their own policy';
  end if;

  set local ins.via_rpc = 'on';
  update public.ins_policies
  set status = case when p_decision = 'approved' then 'approved' else 'draft' end,
      updated_at = now()
  where tenant_id = v_tenant and id = p_policy_id
  returning * into v_pol;
  insert into public.ins_policy_approvals (tenant_id, policy_id, action, actor_id, note)
  values (v_tenant, p_policy_id, p_decision, auth.uid(), p_note);
  reset ins.via_rpc;

  return v_pol;
end;
$$;

revoke all on function public.ins_decide_policy(uuid, text, text) from public, anon;
grant execute on function public.ins_decide_policy(uuid, text, text) to authenticated;

-- =====================================================================
-- Recreate the core guard trigger with one exception: a pending_approval
-- policy may return to draft on rejection. Everything else is unchanged
-- from 20261010100000 (status changes still require the RPC flag; locked
-- policies still only allow status/notes/updated_at; cross-tenant FKs
-- still checked).
-- =====================================================================
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
      raise exception 'INS_STATUS_RPC_ONLY: policy status changes go through RPCs' using errcode = '42501';
    end if;
    if old.status <> 'draft' and (
      to_jsonb(old) - array['status', 'notes', 'updated_at']
    ) is distinct from (
      to_jsonb(new) - array['status', 'notes', 'updated_at']
    ) then
      raise exception 'INS_POLICY_LOCKED: a % policy cannot be edited', old.status;
    end if;
    if old.status not in ('draft', 'pending_approval') and new.status = 'draft' then
      raise exception 'INS_STATUS_INVALID: a % policy cannot return to draft', old.status;
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

revoke all on function public.ins_policies_guard() from public, anon, authenticated, service_role;
drop trigger if exists ins_policies_guard_trg on public.ins_policies;
create trigger ins_policies_guard_trg before insert or update on public.ins_policies
  for each row execute function public.ins_policies_guard();
