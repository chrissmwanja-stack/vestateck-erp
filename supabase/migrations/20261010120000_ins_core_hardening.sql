-- Insurance core hardening. Follow-up to 20261010100000 / 20261010110000, from
-- the known-gap probes in supabase/tests/test_ins_core.sql.
--
-- 1. ins_policies_guard: a draft's RPC-owned fields can no longer be edited
--    directly. Members may edit a draft (premium, dates, notes ...), but
--    renewal_of_id is set only by ins_create_renewal_draft(), and the bind
--    stamps (commission_amount, net_premium_to_insurer, bound_at, bound_by,
--    journal_entry_id) only by ins_bind_policy(). Before this, a member could
--    repoint renewal_of_id at an unrelated active policy and a manager's bind
--    would then mark that policy renewed.
-- 2. ins_claims_guard: changing a claim's loss_date after creation now re-checks
--    the policy period, the same rule ins_create_claim applies.
-- 3. Claims are an audit trail and cannot be deleted by clients. The manager
--    DELETE policy for notified claims could never succeed anyway (every claim has
--    a creation event, ON DELETE RESTRICT), so it is dropped along with the
--    grant. Claim events lose their INSERT/UPDATE/DELETE grants: the baseline's
--    default privileges give authenticated full DML on every new public table,
--    so until now RLS alone kept the events read-only. Both are written by the
--    SECURITY DEFINER RPCs, which are unaffected.
--
-- Re-runnable: create or replace, drop policy if exists, revoke.

-- =====================================================================
-- 1. Policies guard
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
  return new;
end;
$$;

-- =====================================================================
-- 2. Claims guard
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
  ) then
    raise exception 'INS_CLAIM_RPC_ONLY: status and amounts change through ins_transition_claim()' using errcode = '42501';
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
-- 3. Claims are not deletable by clients; claim events are read-only
-- =====================================================================
drop policy if exists ins_claims_delete on public.ins_claims;
revoke delete on public.ins_claims from authenticated;
revoke insert, update, delete on public.ins_claim_events from authenticated;