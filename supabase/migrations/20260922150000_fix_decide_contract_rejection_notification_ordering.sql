-- decide_contract() (20260921100000_law_contract_approval_flow.sql) updated
-- law_contracts BEFORE inserting the law_contract_decisions row. The UPDATE
-- fires notify_contract_status_change(), which -- on rejection -- looks up
-- the reason from law_contract_decisions:
--
--   select d.notes into v_reason from law_contract_decisions d
--   where d.contract_id = NEW.id and d.decision = 'rejected' ...
--
-- Since the decision row didn't exist yet at that point, v_reason was
-- always NULL and the rejection notification body never carried the
-- reason. Caught by supabase/tests/test_law_contract_approval_flow.sql
-- (step 6/7: "FAIL: rejection notification missing or reason not carried").
--
-- Fix: insert the decision row BEFORE updating the contract, so the
-- trigger can see it when it fires. No other behavior change.

CREATE OR REPLACE FUNCTION "public"."decide_contract"("p_contract_id" "uuid", "p_decision" "text", "p_notes" "text" DEFAULT NULL)
RETURNS "public"."law_contracts"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_contract public.law_contracts%rowtype;
begin
  if not has_module_role('legal', array['admin', 'manager']) then
    raise exception 'not authorized: contract approval requires a legal admin or manager role';
  end if;

  if p_decision not in ('approved', 'rejected') then
    raise exception 'p_decision must be ''approved'' or ''rejected''';
  end if;

  if p_decision = 'rejected' and (p_notes is null or btrim(p_notes) = '') then
    raise exception 'rejection requires notes explaining why';
  end if;

  select * into v_contract from law_contracts
  where id = p_contract_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'contract not found in this tenant';
  end if;
  if v_contract.status <> 'pending_approval' then
    raise exception 'only contracts pending approval can be decided (current status: %)', v_contract.status;
  end if;

  -- Separation of duties: the person who drafted a contract must not be
  -- the one who approves it, even if they hold an approver role.
  if v_contract.created_by is not null and v_contract.created_by = auth.uid() then
    raise exception 'you cannot decide a contract you created -- another legal admin/manager must approve it';
  end if;

  -- Insert the decision row BEFORE updating the contract, so the
  -- notify_contract_status_change trigger (fired by the UPDATE below)
  -- can find it when it looks up the rejection reason.
  insert into law_contract_decisions (tenant_id, contract_id, decision, decided_by, notes)
  values (v_contract.tenant_id, v_contract.id, p_decision, auth.uid(), nullif(btrim(coalesce(p_notes, '')), ''));

  update law_contracts
  set status = case p_decision when 'approved' then 'active' else 'rejected' end,
      updated_at = now()
  where id = v_contract.id
  returning * into v_contract;

  return v_contract;
end;
$$;