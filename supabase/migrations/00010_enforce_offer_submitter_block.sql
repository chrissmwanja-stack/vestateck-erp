-- supabase/migrations/0004_enforce_offer_submitter_block.sql
--
-- record_approval_decision() currently only checks can_act_on_stage(),
-- which has no notion of blocks_offer_submitter_approval or who submitted
-- the offer on a request. The rule ("if you submitted the offer, a
-- different reviewer must act on it here") was only enforced by disabling
-- the button in ApprovalQueue.tsx -- calling the RPC directly bypasses it
-- entirely. This adds the same check inside the function itself.

create or replace function public.record_approval_decision(
  p_request_id uuid,
  p_decision text,
  p_comment text default null::text,
  p_acting_on_behalf_of uuid default null::uuid
)
returns table(out_request_id uuid, out_status text, out_stage_id uuid, out_purchase_order_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_request       requests%rowtype;
  v_stage         workflow_stages%rowtype;
  v_next_stage    workflow_stages%rowtype;
  v_next_stage_id uuid;
  v_offer         request_offers%rowtype;
  v_po_id         uuid;
  v_po_number     text;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  -- Lock the request so two approvers can't act on it concurrently.
  select * into v_request from requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'open' then
    raise exception 'request is not open (status: %)', v_request.status;
  end if;
  if v_request.current_stage_id is null then
    raise exception 'request has no current stage';
  end if;
  if not can_act_on_stage(v_request.current_stage_id) then
    raise exception 'not authorized to act on this stage';
  end if;

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;

  -- NEW: block the offer submitter from acting on their own offer at a
  -- stage configured to require a different reviewer.
  if v_stage.blocks_offer_submitter_approval then
    select * into v_offer from request_offers
    where request_id = p_request_id
    order by submitted_at desc limit 1;

    if found and v_offer.submitted_by = auth.uid() then
      raise exception 'you submitted the offer on this request -- a different reviewer must act on it at this stage';
    end if;
  end if;

  -- Always record the decision, regardless of outcome (audit trail).
  insert into approval_actions
    (request_id, workflow_stage_id, approver_id, acted_on_behalf_of, decision, comment)
  values
    (p_request_id, v_stage.id, auth.uid(), p_acting_on_behalf_of, p_decision, p_comment);

  -- Rejection stops the workflow immediately, at any stage.
  if p_decision = 'rejected' then
    update requests set status = 'rejected', updated_at = now() where id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_rejected',
      'Request rejected',
      format('Your request "%s" was rejected at the %s stage.', v_request.item_description, v_stage.name),
      p_request_id
    );

    return query select p_request_id, 'rejected'::text, v_stage.id, null::uuid;
    return;
  end if;

  -- Finance's own sign-off closes the request. The PO already exists
  -- from an earlier stage (steps 9/10 in the flow) -- nothing new is
  -- created here.
  if v_stage.is_finance_terminal_stage then
    update requests
    set status = 'closed', current_stage_id = null, updated_at = now()
    where id = p_request_id;

    select id into v_po_id from purchase_orders where request_id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_closed',
      'Request closed',
      format('Your request "%s" has been closed. The purchase order is ready for procurement.', v_request.item_description),
      p_request_id,
      v_po_id
    );

    return query select p_request_id, 'closed'::text, null::uuid, v_po_id;
    return;
  end if;

  select * into v_offer from request_offers
  where request_id = p_request_id
  order by submitted_at desc limit 1;

  -- Only the Budget Controller stage has a threshold; everywhere else
  -- is a single path (next_stage_low_id).
  if v_stage.threshold_amount is not null then
    if not found then
      raise exception 'no offer on file to evaluate threshold';
    end if;
    if v_offer.quotation_amount <= v_stage.threshold_amount then
      v_next_stage_id := v_stage.next_stage_low_id;   -- <= 5M -> Finance
    else
      v_next_stage_id := v_stage.next_stage_high_id;  -- > 5M -> Project Manager
    end if;
  else
    v_next_stage_id := v_stage.next_stage_low_id;
  end if;

  if v_next_stage_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  select * into v_next_stage from workflow_stages where id = v_next_stage_id;

  -- Generate the PO the moment either branch is about to enter Finance
  -- (matches steps 8a/8b: PO generated immediately).
  if v_next_stage.is_finance_terminal_stage then
    if v_offer.id is null then
      raise exception 'no offer on file to generate a purchase order';
    end if;
    if exists (select 1 from purchase_orders where request_id = p_request_id) then
      raise exception 'a purchase order already exists for this request';
    end if;

    v_po_number := 'PO-' || to_char(now(), 'YYYY') || '-'
                   || lpad(nextval('public.po_number_seq')::text, 5, '0');

    insert into purchase_orders (request_id, po_number, vendor_name, amount, generated_by)
    values (p_request_id, v_po_number, v_offer.vendor_name, v_offer.quotation_amount, auth.uid())
    returning id into v_po_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'purchase_order_generated',
      'Purchase order generated',
      format('A purchase order (%s) has been generated for your request "%s".', v_po_number, v_request.item_description),
      p_request_id,
      v_po_id
    );
  end if;

  update requests
  set current_stage_id = v_next_stage_id, updated_at = now()
  where id = p_request_id;

  -- Notify whoever is now responsible for this request: direct
  -- assignees on the new stage, plus anyone actively delegated to
  -- cover them.
  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select distinct
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('Request "%s" is awaiting your approval at the %s stage.', v_request.item_description, v_next_stage.name),
    p_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage_id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage_id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  return query select p_request_id, 'open'::text, v_next_stage_id, v_po_id;
end;
$function$;