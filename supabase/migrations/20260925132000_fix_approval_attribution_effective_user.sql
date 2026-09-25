-- Fix approval attribution to use effective_user_id() and capture actor + impersonation session
-- Addresses forensic items 2 and 3

-- 1. Extend approval_actions to capture both actor and effective + session
alter table public.approval_actions
  add column if not exists actor_id uuid,
  add column if not exists impersonation_session_id uuid references public.impersonation_sessions(id) on delete set null,
  add column if not exists effective_user_id uuid;

comment on column public.approval_actions.actor_id is 'Real authenticated user (auth.uid()) — the operator when impersonating';
comment on column public.approval_actions.effective_user_id is 'Effective user for permission checks (effective_user_id()) — target user when View-as user-level';
comment on column public.approval_actions.impersonation_session_id is 'Link to impersonation_sessions when action occurred during View-as';

-- Backfill existing rows: actor = approver, effective = approver where null
update public.approval_actions
set actor_id = approver_id,
    effective_user_id = approver_id
where actor_id is null;

-- 2. Re-define record_approval_decision to use effective_user_id() and capture actor/session
create or replace function public.record_approval_decision(
  p_request_id uuid,
  p_decision text,
  p_comment text default null,
  p_acting_on_behalf_of uuid default null,
  p_selected_offer_id uuid default null
)
returns table(out_request_id uuid, out_status text, out_stage_id uuid, out_purchase_order_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_request requests%rowtype;
  v_stage workflow_stages%rowtype;
  v_next_stage workflow_stages%rowtype;
  v_next_stage_id uuid;
  v_offer request_offers%rowtype;
  v_po_id uuid;
  v_po_number text;
  v_actor uuid := auth.uid();
  v_effective uuid := public.effective_user_id();
  v_session_id uuid;
  v_is_platform_bypass boolean := public.platform_admin_bypass();
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  -- Capture active impersonation session if any
  select id into v_session_id
  from impersonation_sessions
  where platform_admin_id = auth.uid()
    and ended_at is null
    and expires_at > now()
  order by started_at desc
  limit 1;

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
  -- Permission check uses effective_user_id() via can_act_on_stage() which now uses effective_user_id()
  if not can_act_on_stage(v_request.current_stage_id) then
    raise exception 'not authorized to act on this stage';
  end if;

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;

  -- Anti-collusion: check effective user, not just actor
  if v_stage.blocks_offer_submitter_approval then
    if exists (
      select 1 from request_offers
      where request_id = p_request_id and submitted_by = v_effective
    ) then
      raise exception 'you submitted an offer on this request -- a different reviewer must act on it at this stage';
    end if;
  end if;

  -- For platform bypass (company-level View-as), approver is actor but we still log effective as null
  -- For user-level View-as, approver is effective user, actor is platform admin
  insert into approval_actions
    (request_id, workflow_stage_id, approver_id, actor_id, effective_user_id, impersonation_session_id, acted_on_behalf_of, decision, comment)
  values
    (p_request_id, v_stage.id,
     case when v_is_platform_bypass then v_actor else v_effective end,
     v_actor,
     v_effective,
     v_session_id,
     p_acting_on_behalf_of, p_decision, p_comment);

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

    -- Audit platform event when rejection occurs during impersonation
    if v_session_id is not null then
      perform log_platform_event(
        'request.reject.during_impersonation', v_request.tenant_id, 'request', p_request_id::text,
        p_comment,
        jsonb_build_object('stage', v_stage.name, 'actor', v_actor, 'effective', v_effective, 'session_id', v_session_id),
        jsonb_build_object('status', 'rejected')
      );
    end if;

    return query select p_request_id, 'rejected'::text, v_stage.id, null::uuid;
    return;
  end if;

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

  -- Offer selection at requires_offer_selection stage
  if v_stage.requires_offer_selection then
    if p_selected_offer_id is null then
      raise exception 'an offer must be selected at this stage';
    end if;
    select * into v_offer from request_offers where id = p_selected_offer_id and request_id = p_request_id;
    if not found then
      raise exception 'selected offer not found on this request';
    end if;
    update request_offers set is_selected = true where id = p_selected_offer_id;
    update request_offers set is_selected = false where request_id = p_request_id and id != p_selected_offer_id;
  else
    -- Use existing selected offer if any
    select * into v_offer from request_offers where request_id = p_request_id and is_selected = true limit 1;
  end if;

  -- Threshold branching
  if v_stage.threshold_amount is not null and v_offer.id is not null then
    if v_offer.quotation_amount <= v_stage.threshold_amount then
      v_next_stage_id := v_stage.next_stage_low_id;
    else
      v_next_stage_id := v_stage.next_stage_high_id;
    end if;
  else
    v_next_stage_id := v_stage.next_stage_low_id;
  end if;

  if v_next_stage_id is null then
    -- No next stage, treat as terminal
    update requests set status = 'closed', current_stage_id = null, updated_at = now() where id = p_request_id;
    return query select p_request_id, 'closed'::text, null::uuid, null::uuid;
    return;
  end if;

  select * into v_next_stage from workflow_stages where id = v_next_stage_id;

  update requests set current_stage_id = v_next_stage_id, updated_at = now() where id = p_request_id;

  -- Auto-create PO if next stage is finance terminal and we have an offer
  if v_next_stage.is_finance_terminal_stage and v_offer.id is not null then
    -- PO creation logic (simplified, actual PO number generation via sequence)
    insert into purchase_orders (request_id, po_number, vendor_name, amount, generated_by)
    values (p_request_id, 'PO-' || substr(p_request_id::text,1,8), v_offer.vendor_name, v_offer.quotation_amount, v_effective)
    returning id into v_po_id;
  end if;

  -- Notify next approvers
  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select
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
$$;

revoke execute on function public.record_approval_decision(uuid, text, text, uuid, uuid) from public;
grant execute on function public.record_approval_decision(uuid, text, text, uuid, uuid) to authenticated;

-- Also fix invoice approval to use effective_user_id
create or replace function public.record_invoice_approval_decision(
  p_invoice_request_id uuid,
  p_decision text,
  p_comment text default null,
  p_acting_on_behalf_of uuid default null
)
returns table(out_invoice_request_id uuid, out_status text, out_stage_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_invoice invoice_requests%rowtype;
  v_stage workflow_stages%rowtype;
  v_next_stage workflow_stages%rowtype;
  v_next_stage_id uuid;
  v_actor uuid := auth.uid();
  v_effective uuid := public.effective_user_id();
  v_session_id uuid;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select id into v_session_id from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null and expires_at > now()
  order by started_at desc limit 1;

  select * into v_invoice from invoice_requests where id = p_invoice_request_id for update;
  if not found then raise exception 'invoice request not found'; end if;
  if v_invoice.tenant_id != get_my_tenant_id() then raise exception 'not authorized for this invoice request'; end if;
  if v_invoice.status != 'open' then raise exception 'invoice request is not open (status: %)', v_invoice.status; end if;
  if v_invoice.current_stage_id is null then raise exception 'invoice request has no current stage'; end if;
  if not can_act_on_stage(v_invoice.current_stage_id) then raise exception 'not authorized to act on this stage'; end if;

  if v_invoice.requester_id = v_effective then
    raise exception 'you submitted this invoice -- a different reviewer must act on it';
  end if;

  select * into v_stage from workflow_stages where id = v_invoice.current_stage_id;

  insert into approval_actions
    (invoice_request_id, workflow_stage_id, approver_id, actor_id, effective_user_id, impersonation_session_id, acted_on_behalf_of, decision, comment)
  values
    (p_invoice_request_id, v_stage.id, v_effective, v_actor, v_effective, v_session_id, p_acting_on_behalf_of, p_decision, p_comment);

  if p_decision = 'rejected' then
    update invoice_requests set status = 'rejected', updated_at = now() where id = p_invoice_request_id;
    insert into notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    values (v_invoice.tenant_id, v_invoice.requester_id, 'invoice_rejected', 'Invoice rejected',
      format('Your invoice for "%s" (%s) was rejected at the %s stage.', v_invoice.vendor_name, v_invoice.amount, v_stage.name),
      p_invoice_request_id);
    return query select p_invoice_request_id, 'rejected'::text, v_stage.id;
    return;
  end if;

  if v_stage.is_finance_terminal_stage then
    update invoice_requests set status = 'closed', current_stage_id = null, updated_at = now() where id = p_invoice_request_id;
    insert into notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    values (v_invoice.tenant_id, v_invoice.requester_id, 'invoice_closed', 'Invoice closed',
      format('Your invoice for "%s" (%s) has been fully approved and closed.', v_invoice.vendor_name, v_invoice.amount),
      p_invoice_request_id);
    return query select p_invoice_request_id, 'closed'::text, null::uuid;
    return;
  end if;

  if v_stage.threshold_amount is not null then
    if v_invoice.amount <= v_stage.threshold_amount then
      v_next_stage_id := v_stage.next_stage_low_id;
    else
      v_next_stage_id := v_stage.next_stage_high_id;
    end if;
  else
    v_next_stage_id := v_stage.next_stage_low_id;
  end if;

  update invoice_requests set current_stage_id = v_next_stage_id, updated_at = now() where id = p_invoice_request_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
  select v_invoice.tenant_id, recipient_id, 'approval_needed', 'Approval needed',
    format('Invoice "%s" (%s) is awaiting your approval at the %s stage.', v_invoice.vendor_name, v_invoice.amount, (select name from workflow_stages where id = v_next_stage_id)),
    p_invoice_request_id
  from (
    select aa.user_id as recipient_id from approval_assignments aa where aa.workflow_stage_id = v_next_stage_id
    union
    select d.delegate_user_id from approval_delegations d join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status='active' and now() between d.starts_at and d.ends_at and aa.workflow_stage_id = v_next_stage_id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  return query select p_invoice_request_id, 'open'::text, v_next_stage_id;
end;
$$;

revoke execute on function public.record_invoice_approval_decision(uuid, text, text, uuid) from public;
grant execute on function public.record_invoice_approval_decision(uuid, text, text, uuid) to authenticated;
