-- Offers no longer auto-advance the request on insert -- procurement
-- needs to gather multiple competing quotes first, then explicitly
-- send the request to Budget Controller once ready. The old trigger
-- fired on the very first offer, which is exactly what we no longer
-- want.
drop trigger trg_advance_after_offer_entry on public.request_offers;
drop function public.advance_after_offer_entry();

create or replace function public.submit_offers_for_approval(p_request_id uuid)
returns requests
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_request     requests%rowtype;
  v_stage       workflow_stages%rowtype;
  v_next_stage  workflow_stages%rowtype;
  v_offer_count int;
begin
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

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;
  if not v_stage.requires_offer_entry then
    raise exception 'this request is not at an offer-entry stage';
  end if;
  if not can_act_on_stage(v_stage.id) then
    raise exception 'not authorized to submit offers on this request';
  end if;

  select count(*) into v_offer_count from request_offers where request_id = p_request_id;
  if v_offer_count < 2 then
    raise exception 'at least 2 competing offers are required before sending to Budget Controller (currently %)', v_offer_count;
  end if;

  if v_stage.next_stage_low_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  update requests
  set current_stage_id = v_stage.next_stage_low_id, updated_at = now()
  where id = p_request_id
  returning * into v_request;

  select * into v_next_stage from workflow_stages where id = v_stage.next_stage_low_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select distinct
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Offers submitted -- approval needed',
    format('%s competing offers were submitted for request "%s" and are awaiting your review.',
           v_offer_count, v_request.item_description),
    p_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage.id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage.id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage.id)
  ) recipients;

  return v_request;
end;
$$;
