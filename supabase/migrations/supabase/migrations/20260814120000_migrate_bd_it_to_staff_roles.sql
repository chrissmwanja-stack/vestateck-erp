-- Migrate bd/it module gating from department-membership (is_business_dev(),
-- is_it_support() joining app_users.department_id -> departments.name) onto
-- the staff_roles/has_module_role() pattern already used by hr, legal, pmo,
-- and machine_operation.
--
-- Why: accept-invite/index.ts has always written a staff_roles row for bd/it
-- invites, but nothing in RLS ever read it -- the real gate was
-- department_id, which accept-invite never set. Net effect: inviting someone
-- to BD or IT created a decorative staff_roles row and left them locked out
-- of the module they were just invited into. Verified against live data
-- before writing this migration: zero app_users currently have
-- department_id pointing at 'IT Support' or 'Business Development', and zero
-- existing staff_roles rows for module bd/it -- so this flips the gate with
-- no backfill needed and no risk of revoking anyone's current access.
--
-- 'IT Support' / 'Business Development' departments and department_id are
-- left in place (other things may reference them); this migration only
-- changes what is_business_dev()/is_it_support() check.

create or replace function public.is_business_dev()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.has_module_role('bd', array['admin','manager','member']);
$$;

create or replace function public.is_it_support()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.has_module_role('it', array['admin','manager','member']);
$$;

-- assign_ticket()'s inline assignee-eligibility check independently joined
-- to departments rather than calling is_it_support()/has_module_role() --
-- update it to match, or it would keep gating on the now-abandoned
-- department_id even after the function-level fix above.
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
          select 1 from staff_roles sr
          where sr.user_id = p_assignee_id
            and sr.module = 'it'
            and sr.tenant_id = v_ticket.tenant_id
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