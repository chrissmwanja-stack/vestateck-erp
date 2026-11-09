-- Changing a draft policy's insurer or product line must point at an active one.
--
-- Why: ins_create_policy refuses an inactive insurer or product line, but the draft edit form
-- updates ins_policies directly, and ins_policies_guard only checks that the new insurer and
-- product line belong to the same tenant. A draft could therefore be moved onto a deactivated
-- insurer or product line. The plain bind path (no saved insurer shares) does not re-check
-- either, so such a draft could be bound.
--
-- The rule: when insurer_id or product_line_id changes on a policy, the new row must be active.
-- Updates that leave both unchanged are not affected, so a draft whose insurer was deactivated
-- after it was created can still have its dates, premium or notes edited. A policy that already
-- has saved insurer shares is unaffected: ins_set_policy_financial_configuration checks each
-- share's insurer is active, and sets the policy insurer to the lead.
--
-- Bound policies are already locked by ins_policies_guard.
--
-- Re-runnable: create or replace, drop trigger if exists.

create or replace function public.ins_policies_active_refs()
returns trigger
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
begin
  if new.insurer_id is distinct from old.insurer_id
     and not exists (select 1 from ins_insurers i
                     where i.id = new.insurer_id and i.tenant_id = new.tenant_id and i.is_active) then
    raise exception 'INS_NOT_FOUND: active insurer' using errcode = '23514';
  end if;
  if new.product_line_id is distinct from old.product_line_id
     and not exists (select 1 from ins_product_lines p
                     where p.id = new.product_line_id and p.tenant_id = new.tenant_id and p.is_active) then
    raise exception 'INS_NOT_FOUND: active product line' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.ins_policies_active_refs() from public, anon, authenticated;

drop trigger if exists ins_policies_active_refs_trg on public.ins_policies;
create trigger ins_policies_active_refs_trg
  before update of insurer_id, product_line_id on public.ins_policies
  for each row
  when (old.insurer_id is distinct from new.insurer_id or old.product_line_id is distinct from new.product_line_id)
  execute function public.ins_policies_active_refs();
