-- =====================================================================
-- Insurance brokerage: let the bind step write its own columns.
--
-- 20261106180000 / 20261106230000 made bind require status = 'approved'.
-- ins_policies_guard locks every non-draft policy (only status, notes and
-- updated_at may change). Binding an approved policy also writes
-- commission_amount, net_premium_to_insurer, bound_at, bound_by and
-- journal_entry_id, so the guard rejected it with INS_POLICY_LOCKED
-- ("a approved policy cannot be edited"). That broke supabase/seed.sql
-- and every flow that binds.
--
-- Fix: for the single transition approved -> active, inside the RPC
-- channel (ins.via_rpc), those five bind columns are allowed to change.
-- Every other edit of a non-draft policy is still locked.
-- Body otherwise identical to 20261106180000.
-- =====================================================================
create or replace function public.ins_policies_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
