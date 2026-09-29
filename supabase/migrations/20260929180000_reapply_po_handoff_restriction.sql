-- Re-applies the PO handoff restriction from 20260929160000.
--
-- Production recorded 20260929160000 in schema_migrations, but the live
-- can_manage_po_handoff() still granted handoff to anyone with an
-- approval_actions row on the request (the file was changed after its
-- version was recorded, so the statements never ran there). Same failure
-- mode as the 2026-09-29 RLS hardening incident.
--
-- Only can_manage_po_handoff is re-applied here. approve_payroll_run is NOT
-- repeated: 20260929170000 defines its final version (separation of duties
-- plus effective_user_id / impersonation_session_id), and re-running the
-- older body from 20260929160000 after it would drop that attribution.
--
-- Decision 3: only the selected-offer submitter and PO-access holders may
-- share a PO or confirm delivery. Approval-chain membership no longer counts.

create or replace function public.can_manage_po_handoff(p_purchase_order_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_request_id uuid;
  v_selected_offer_submitter uuid;
  v_me uuid := public.effective_user_id();
begin
  select request_id into v_request_id
  from purchase_orders
  where id = p_purchase_order_id;

  if v_request_id is null then
    return false;
  end if;

  select submitted_by into v_selected_offer_submitter
  from request_offers
  where request_id = v_request_id and is_selected
  limit 1;

  if v_selected_offer_submitter = v_me then
    return true;
  end if;

  return has_po_access();
end;
$$;
