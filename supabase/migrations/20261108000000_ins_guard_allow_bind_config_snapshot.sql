-- =====================================================================
-- Bind allowance for the accounting config snapshot.
--
-- 20261107235903 added ins_policies.accounting_config_snapshot, filled by the
-- ins_bind_config_snapshot BEFORE UPDATE trigger on the approved -> active
-- transition. ins_policies_guard (20261107090000) only allowed the five bind
-- columns to change on that transition, so the snapshot write tripped
-- INS_POLICY_LOCKED and ins_bind_policy failed on every policy (seen as the
-- seed.sql failure in CI). The trigger name sorts before ins_policies_guard_trg,
-- so the guard sees the snapshot; add it to the bind allowance. Same guard as
-- 20261107090000 otherwise; nothing else about a non-draft policy unlocks.
-- =====================================================================

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
        'bound_at', 'bound_by', 'journal_entry_id',
        'accounting_config_snapshot'
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