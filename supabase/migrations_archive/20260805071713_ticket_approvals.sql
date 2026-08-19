-- Approval columns on it_tickets
alter table it_tickets
  add column requires_approval boolean not null default false,
  add column approval_status text not null default 'not_required',
  add column approved_by uuid references app_users(id),
  add column approved_at timestamptz,
  add column approval_notes text;

alter table it_tickets
  add constraint it_tickets_approval_status_check
  check (approval_status in ('not_required','pending','approved','rejected'));

-- Auto-flag Access-category tickets for approval at creation time
create or replace function public.set_ticket_number()
returns trigger
language plpgsql
as $function$
begin
  if NEW.ticket_number is null then
    NEW.ticket_number := next_ticket_number(NEW.tenant_id);
  end if;
  if NEW.category = 'Access' then
    NEW.requires_approval := true;
    NEW.approval_status := 'pending';
  end if;
  return NEW;
end;
$function$;

-- Approval decision RPC (any IT Support staff can decide)
create or replace function public.record_ticket_approval(p_ticket_id uuid, p_decision text, p_notes text default null)
returns it_tickets
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;
  if not is_it_support() then
    raise exception 'not authorized to approve tickets';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status != 'pending' then
    raise exception 'ticket is not pending approval';
  end if;

  update it_tickets
  set approval_status = p_decision,
      approved_by = auth.uid(),
      approved_at = now(),
      approval_notes = p_notes,
      status = case when p_decision = 'rejected' then 'closed' else status end,
      resolution_notes = case when p_decision = 'rejected'
        then coalesce(resolution_notes, 'Rejected at approval: ' || coalesce(p_notes, 'no reason given'))
        else resolution_notes end,
      closed_at = case when p_decision = 'rejected' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_ticket.tenant_id,
    v_ticket.requester_id,
    'ticket_approval_decision',
    'Ticket ' || v_ticket.ticket_number || ' ' || p_decision,
    format('Your ticket "%s" was %s.', v_ticket.subject, p_decision)
  );

  return v_ticket;
end;
$function$;

-- Gate assign_ticket against pending approval
create or replace function public.assign_ticket(p_ticket_id uuid, p_assignee_id uuid)
returns it_tickets
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to assign tickets';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status = 'pending' then
    raise exception 'ticket is awaiting approval and cannot be assigned yet';
  end if;

  if p_assignee_id is not null and not exists (
    select 1 from app_users u
    join departments d on d.id = u.department_id
    where u.id = p_assignee_id and (d.name = 'IT Support' or u.is_platform_admin)
  ) then
    raise exception 'assignee must be IT Support staff';
  end if;

  update it_tickets
  set assignee_id = p_assignee_id,
      status = case when status = 'open' and p_assignee_id is not null then 'in_progress' else status end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  if p_assignee_id is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (
      v_ticket.tenant_id,
      p_assignee_id,
      'ticket_assigned',
      'Ticket ' || v_ticket.ticket_number || ' assigned to you',
      format('"%s" has been assigned to you.', v_ticket.subject)
    );
  end if;

  return v_ticket;
end;
$function$;

-- Gate update_ticket_status against pending approval (only for the in_progress transition)
create or replace function public.update_ticket_status(p_ticket_id uuid, p_status text, p_resolution_notes text DEFAULT NULL::text)
returns it_tickets
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if p_status not in ('open','in_progress','resolved','closed') then
    raise exception 'invalid status: %', p_status;
  end if;
  if not is_it_support() then
    raise exception 'not authorized to update ticket status';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status = 'pending' and p_status = 'in_progress' then
    raise exception 'ticket is awaiting approval and cannot be actioned yet';
  end if;

  update it_tickets
  set status = p_status,
      resolution_notes = coalesce(p_resolution_notes, resolution_notes),
      resolved_at = case when p_status = 'resolved' and resolved_at is null then now() else resolved_at end,
      closed_at = case when p_status = 'closed' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_ticket.tenant_id,
    v_ticket.requester_id,
    'ticket_status_changed',
    'Ticket ' || v_ticket.ticket_number || ' updated',
    format('Your ticket "%s" is now %s.', v_ticket.subject, p_status)
  );

  return v_ticket;
end;
$function$;

-- Read helper for the approval queue
create or replace function public.get_pending_ticket_approvals()
returns setof it_tickets
language sql
stable security definer
set search_path to 'public'
as $function$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and is_it_support() and approval_status = 'pending'
  order by created_at asc;
$function$;
