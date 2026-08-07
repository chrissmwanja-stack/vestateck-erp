-- IT Support: Service Operations (tickets), first pass.
-- Simple status pipeline per decision (not a multi-stage approval chain
-- like procurement requests). Ticket Approvals / Problem Management
-- sidebar nodes are deliberately out of scope for this pass.

create table public.it_tickets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  ticket_number text not null,
  requester_id uuid not null references public.app_users(id),
  assignee_id uuid references public.app_users(id),
  department_id uuid not null references public.departments(id),
  subject text not null,
  description text not null,
  category text not null check (category in ('Hardware','Software','Network','Access','Other')),
  priority text not null default 'medium' check (priority in ('low','medium','high','urgent')),
  status text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  resolution_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz,
  closed_at timestamptz,
  unique (tenant_id, ticket_number)
);

create index it_tickets_requester_idx on public.it_tickets(requester_id);
create index it_tickets_assignee_idx on public.it_tickets(assignee_id);
create index it_tickets_tenant_status_idx on public.it_tickets(tenant_id, status);

alter table public.it_tickets enable row level security;

-- Ticket numbering, mirrors next_mr_number()'s tenant-scoped max+1 pattern.
create or replace function public.next_ticket_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(ticket_number, '^TCK-', ''), ticket_number)::int), 0) + 1
  into v_next_num
  from it_tickets
  where tenant_id = p_tenant_id and ticket_number like 'TCK-%';

  return 'TCK-' || lpad(v_next_num::text, 5, '0');
end;
$$;

create or replace function public.set_ticket_number()
returns trigger
language plpgsql
as $$
begin
  if NEW.ticket_number is null then
    NEW.ticket_number := next_ticket_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$$;

create trigger it_tickets_set_number
  before insert on public.it_tickets
  for each row execute function public.set_ticket_number();

-- Who counts as IT Support staff: assigned to the IT Support department,
-- or a platform admin. Mirrors the has_po_access()-style helper pattern
-- used elsewhere for role-gated screens.
create or replace function public.is_it_support()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from app_users u
    join departments d on d.id = u.department_id
    where u.id = auth.uid()
      and (d.name = 'IT Support' or u.is_platform_admin)
  );
$$;

create policy it_tickets_select on public.it_tickets
  for select
  using (
    tenant_id = get_my_tenant_id()
    and (requester_id = auth.uid() or assignee_id = auth.uid() or is_it_support())
  );

create policy it_tickets_insert on public.it_tickets
  for insert
  with check (
    tenant_id = get_my_tenant_id()
    and requester_id = auth.uid()
  );

-- No direct UPDATE/DELETE policies -- status changes and assignment go
-- through record_ticket_decision()/assign_ticket() below, same as how
-- record_approval_decision() is the sole write path for requests.

grant select, insert on public.it_tickets to authenticated;

-- Move a ticket through the status pipeline. IT Support only.
create or replace function public.update_ticket_status(
  p_ticket_id uuid,
  p_status text,
  p_resolution_notes text default null
)
returns public.it_tickets
language plpgsql
security definer
set search_path to 'public'
as $$
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
$$;

revoke all on function public.update_ticket_status(uuid, text, text) from public;
grant execute on function public.update_ticket_status(uuid, text, text) to authenticated;

-- Assign or reassign a ticket. IT Support only, assignee must also be IT Support staff.
create or replace function public.assign_ticket(
  p_ticket_id uuid,
  p_assignee_id uuid
)
returns public.it_tickets
language plpgsql
security definer
set search_path to 'public'
as $$
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
$$;

revoke all on function public.assign_ticket(uuid, uuid) from public;
grant execute on function public.assign_ticket(uuid, uuid) to authenticated;

-- Read helpers for the three screens.
create or replace function public.get_my_tickets()
returns setof public.it_tickets
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and requester_id = auth.uid()
  order by created_at desc;
$$;

create or replace function public.get_all_tickets()
returns setof public.it_tickets
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and is_it_support()
  order by
    case status when 'open' then 0 when 'in_progress' then 1 when 'resolved' then 2 else 3 end,
    created_at desc;
$$;

revoke all on function public.get_my_tickets() from public;
revoke all on function public.get_all_tickets() from public;
grant execute on function public.get_my_tickets() to authenticated;
grant execute on function public.get_all_tickets() to authenticated;
