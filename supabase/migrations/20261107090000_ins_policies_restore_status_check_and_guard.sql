-- =====================================================================
-- Insurance brokerage: repair what 20261106180000 (approval workflow)
-- overwrote, and let the bind step write its own columns.
--
-- 20261106180000 re-created two objects from an OLDER definition:
--
-- 1. ins_policies_status_check was re-created as
--      (draft, pending_approval, approved, rejected, active, renewed)
--    which dropped 'reversed' (20261014170000) and 'cancelled'
--    (20261015180000). ins_reverse_policy and
--    ins_decide_policy_cancellation then failed with a check violation.
--
-- 2. ins_policies_guard was re-created from the 20261010100000 shape, which
--    dropped everything 20261020210000 added: the draft-only
--    INS_RENEWAL_LINK_RPC_ONLY / INS_BIND_FIELDS_RPC_ONLY rules and the
--    agent / branch cross-tenant and active checks.
--
-- This migration restores the full status list and merges the guard:
-- 20261020210000 (dimensions) + 20261106180000 (approval transitions)
-- + the bind allowance below.
--
-- Bind allowance: ins_bind_policy flips approved -> active and, in the same
-- UPDATE, fills commission_amount, net_premium_to_insurer, bound_at, bound_by
-- and journal_entry_id. Those five columns may change for that one
-- transition, through the RPC channel only. Every other edit of a non-draft
-- policy stays locked.
-- =====================================================================

alter table public.ins_policies drop constraint if exists ins_policies_status_check;
alter table public.ins_policies add constraint ins_policies_status_check
  check (status in ('draft', 'pending_approval', 'approved', 'rejected',
                    'active', 'renewed', 'reversed', 'cancelled'));

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

create or replace function public.ins_policies_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_ignore text[] := array['status', 'notes', 'updated_at'];
begin
  if tg_op = 'INSERT' then
    if not public.ins_via_rpc() then
      raise exception 'INS_RPC_ONLY: create policies with ins_create_policy()' using errcode = '42501';
    end if;
  else
    if new.status is distinct from old.status and not public.ins_via_rpc() then
      raise exception 'INS_STATUS_RPC_ONLY: policy status changes go through RPCs' using errcode = '42501';
    end if;

    -- The bind transition fills in the bind columns; nothing else.
    if old.status = 'approved' and new.status = 'active' and public.ins_via_rpc() then
      v_ignore := v_ignore || array[
        'commission_amount', 'net_premium_to_insurer',
        'bound_at', 'bound_by', 'journal_entry_id'
      ];
    end if;

    if old.status <> 'draft' and (
      to_jsonb(old) - v_ignore
    ) is distinct from (
      to_jsonb(new) - v_ignore
    ) then
      raise exception 'INS_POLICY_LOCKED: a % policy cannot be edited', old.status;
    end if;
    -- A pending policy returns to draft when rejected; nothing else may.
    if old.status not in ('draft', 'pending_approval') and new.status = 'draft' then
      raise exception 'INS_STATUS_INVALID: a % policy cannot return to draft', old.status;
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

revoke all on function public.ins_policies_guard() from public, anon, authenticated, service_role;
drop trigger if exists ins_policies_guard_trg on public.ins_policies;
create trigger ins_policies_guard_trg before insert or update on public.ins_policies
  for each row execute function public.ins_policies_guard();

-- =====================================================================
-- Bind guard: only a status CHANGE into 'active' needs 'approved'.
--
-- 20261106180000 raised whenever new.status was 'active' or 'renewed' and
-- old.status was not 'approved' -- on EVERY update, so even editing the
-- notes of an already-active policy, or ins_bind_policy marking the
-- predecessor 'renewed' (active -> renewed), failed with INS_NOT_APPROVED.
-- =====================================================================
create or replace function public.ins_policy_bind_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.status is distinct from old.status
     and new.status = 'active'
     and old.status <> 'approved' then
    raise exception 'INS_NOT_APPROVED: policy % must be approved before binding (status is %)', old.policy_no, old.status;
  end if;
  return new;
end;
$$;

revoke all on function public.ins_policy_bind_guard() from public, anon, authenticated, service_role;
