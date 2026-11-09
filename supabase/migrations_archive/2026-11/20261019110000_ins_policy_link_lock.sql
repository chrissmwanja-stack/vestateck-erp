-- A draft policy's client and product line are locked while risks are linked to it.
--
-- Why: ins_link_policy_risk only checks that a risk belongs to the policy's client at the
-- moment it is linked. Nothing re-checked afterwards, and the draft edit form lets the client
-- change. A draft could therefore be moved to client B while still carrying client A's vehicle
-- risk and issued motor certificate, and bind would succeed. The product line has the same
-- problem: the certificate rule is decided by the policy's line at bind, but the linked risks
-- were registered against the old one.
--
-- The rule: while any risk is linked to a policy, its client_id and product_line_id cannot be
-- changed. To change them, unlink the risks first. ins_unlink_policy_risk also releases the
-- certificate attached for that risk, so no certificate can be left behind. A policy with no
-- linked risks is not affected, so a draft created for the wrong client can still be corrected.
--
-- Nothing in the migrations changes either column on an existing policy, so no flow depends on
-- the old behaviour. Bound policies are already locked by ins_policies_guard.
--
-- Re-runnable: create or replace, drop trigger if exists.

create or replace function public.ins_policies_link_lock()
returns trigger
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
begin
  if not exists (select 1 from ins_policy_risks r where r.tenant_id = new.tenant_id and r.policy_id = new.id) then
    return new;
  end if;
  if new.client_id is distinct from old.client_id then
    raise exception 'INS_POLICY_LINKED: risks are linked to this policy, so its client cannot change. Unlink the risks first.'
      using errcode = '23514';
  end if;
  if new.product_line_id is distinct from old.product_line_id then
    raise exception 'INS_POLICY_LINKED: risks are linked to this policy, so its product line cannot change. Unlink the risks first.'
      using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.ins_policies_link_lock() from public, anon, authenticated;

drop trigger if exists ins_policies_link_lock_trg on public.ins_policies;
create trigger ins_policies_link_lock_trg
  before update of client_id, product_line_id on public.ins_policies
  for each row
  when (old.client_id is distinct from new.client_id or old.product_line_id is distinct from new.product_line_id)
  execute function public.ins_policies_link_lock();
