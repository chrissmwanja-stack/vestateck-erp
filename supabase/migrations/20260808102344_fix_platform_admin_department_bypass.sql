-- is_it_support() and is_business_dev() used an inner join to departments
-- before checking is_platform_admin, which silently excluded any platform
-- admin with department_id = null (e.g. gm@test.local, a Deputy General
-- Manager not tied to a specific department). Fix: check is_platform_admin
-- directly, independent of the departments join, matching the pattern
-- already used by is_finance_team_member().

create or replace function public.is_it_support()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select is_platform_admin from app_users where id = auth.uid()), false)
    or exists (
      select 1 from app_users u
      join departments d on d.id = u.department_id
      where u.id = auth.uid()
        and d.name = 'IT Support'
    );
$$;

create or replace function public.is_business_dev()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select is_platform_admin from app_users where id = auth.uid()), false)
    or exists (
      select 1 from app_users u
      join departments d on d.id = u.department_id
      where u.id = auth.uid()
        and d.name = 'Business Development'
    );
$$;

-- Same fix inside assign_ticket()'s inline assignee-eligibility check, so a
-- platform admin without a department can still be assigned tickets.
create or replace function public.assign_ticket(p_ticket_id uuid, p_assignee_id uuid)
returns it_tickets
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
  if v_ticket.approval_status = 'pending' then
    raise exception 'ticket is awaiting approval and cannot be assigned yet';
  end if;

  if p_assignee_id is not null and not exists (
    select 1 from app_users u
    where u.id = p_assignee_id
      and (
        coalesce(u.is_platform_admin, false)
        or exists (
          select 1 from departments d
          where d.id = u.department_id and d.name = 'IT Support'
        )
      )
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
