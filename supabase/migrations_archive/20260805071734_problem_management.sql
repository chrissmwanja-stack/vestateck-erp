create table problems (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  problem_number text unique,
  title text not null,
  description text,
  root_cause text,
  status text not null default 'open' check (status in ('open','investigating','resolved','closed')),
  category text,
  priority text not null default 'medium' check (priority in ('low','medium','high','urgent')),
  created_by uuid references app_users(id),
  assigned_to uuid references app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz,
  closed_at timestamptz
);

create table problem_tickets (
  problem_id uuid not null references problems(id) on delete cascade,
  ticket_id uuid not null references it_tickets(id) on delete cascade,
  tenant_id uuid not null references tenants(id),
  linked_at timestamptz not null default now(),
  primary key (problem_id, ticket_id)
);

alter table problems enable row level security;
alter table problem_tickets enable row level security;

create policy problems_select on problems
  for select using (tenant_id = get_my_tenant_id() and is_it_support());

create policy problem_tickets_select on problem_tickets
  for select using (tenant_id = get_my_tenant_id() and is_it_support());

create or replace function public.next_problem_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(problem_number, '^PRB-', ''), problem_number)::int), 0) + 1
  into v_next_num
  from problems
  where tenant_id = p_tenant_id and problem_number like 'PRB-%';

  return 'PRB-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

create or replace function public.set_problem_number()
returns trigger
language plpgsql
as $function$
begin
  if NEW.problem_number is null then
    NEW.problem_number := next_problem_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$function$;

create trigger trg_set_problem_number
before insert on problems
for each row execute function set_problem_number();

create or replace function public.create_problem(p_title text, p_description text default null, p_category text default null, p_priority text default 'medium')
returns problems
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_problem public.problems%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create problems';
  end if;
  if p_priority not in ('low','medium','high','urgent') then
    raise exception 'invalid priority: %', p_priority;
  end if;

  insert into problems (tenant_id, title, description, category, priority, created_by)
  values (get_my_tenant_id(), p_title, p_description, p_category, p_priority, auth.uid())
  returning * into v_problem;
  return v_problem;
end;
$function$;

create or replace function public.update_problem(
  p_problem_id uuid,
  p_status text default null,
  p_root_cause text default null,
  p_assigned_to uuid default null,
  p_title text default null,
  p_description text default null
)
returns problems
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_problem public.problems%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update problems';
  end if;
  select * into v_problem from problems where id = p_problem_id for update;
  if not found then
    raise exception 'problem not found';
  end if;
  if v_problem.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this problem';
  end if;
  if p_status is not null and p_status not in ('open','investigating','resolved','closed') then
    raise exception 'invalid status: %', p_status;
  end if;

  update problems
  set status = coalesce(p_status, status),
      root_cause = coalesce(p_root_cause, root_cause),
      assigned_to = coalesce(p_assigned_to, assigned_to),
      title = coalesce(p_title, title),
      description = coalesce(p_description, description),
      resolved_at = case when p_status = 'resolved' and resolved_at is null then now() else resolved_at end,
      closed_at = case when p_status = 'closed' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_problem_id
  returning * into v_problem;

  return v_problem;
end;
$function$;

create or replace function public.link_ticket_to_problem(p_problem_id uuid, p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant uuid := get_my_tenant_id();
begin
  if not is_it_support() then
    raise exception 'not authorized to link tickets to problems';
  end if;
  if not exists (select 1 from problems where id = p_problem_id and tenant_id = v_tenant) then
    raise exception 'problem not found';
  end if;
  if not exists (select 1 from it_tickets where id = p_ticket_id and tenant_id = v_tenant) then
    raise exception 'ticket not found';
  end if;

  insert into problem_tickets (problem_id, ticket_id, tenant_id)
  values (p_problem_id, p_ticket_id, v_tenant)
  on conflict do nothing;
end;
$function$;

create or replace function public.unlink_ticket_from_problem(p_problem_id uuid, p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not is_it_support() then
    raise exception 'not authorized to unlink tickets from problems';
  end if;
  delete from problem_tickets
  where problem_id = p_problem_id and ticket_id = p_ticket_id and tenant_id = get_my_tenant_id();
end;
$function$;

create or replace function public.get_problems()
returns setof problems
language sql
stable security definer
set search_path to 'public'
as $function$
  select * from problems
  where tenant_id = get_my_tenant_id() and is_it_support()
  order by
    case status when 'open' then 0 when 'investigating' then 1 when 'resolved' then 2 else 3 end,
    created_at desc;
$function$;

create or replace function public.get_problem_tickets(p_problem_id uuid)
returns setof it_tickets
language sql
stable security definer
set search_path to 'public'
as $function$
  select t.* from it_tickets t
  join problem_tickets pt on pt.ticket_id = t.id
  where pt.problem_id = p_problem_id and t.tenant_id = get_my_tenant_id() and is_it_support()
  order by t.created_at desc;
$function$;
