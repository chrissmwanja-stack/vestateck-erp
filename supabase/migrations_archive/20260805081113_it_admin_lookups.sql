
-- Ticket Categories: admin-managed reference list. Note this is a
-- separate lookup from it_tickets.category, which stays a fixed CHECK
-- constraint (Hardware/Software/Network/Access/Other) for now since the
-- ticket submission form isn't wired to read from a table yet -- this
-- gives IT support a place to curate the list ahead of that follow-up.
create table public.ticket_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

alter table public.ticket_categories enable row level security;

create policy ticket_categories_select on public.ticket_categories
  for select using (tenant_id = get_my_tenant_id());

create or replace function public.get_ticket_categories()
returns setof public.ticket_categories
language sql
security definer
set search_path = public
as $$
  select * from ticket_categories where tenant_id = get_my_tenant_id() order by name;
$$;

create or replace function public.create_ticket_category(p_code text, p_name text)
returns public.ticket_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  insert into ticket_categories (tenant_id, code, name)
  values (get_my_tenant_id(), p_code, p_name)
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.update_ticket_category(p_id uuid, p_name text default null, p_is_active boolean default null)
returns public.ticket_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  update ticket_categories
  set name = coalesce(p_name, name), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'ticket category not found';
  end if;
  return v_row;
end;
$$;

-- Seed from the categories already used on it_tickets.category so the
-- list starts populated instead of empty.
insert into ticket_categories (tenant_id, code, name)
select t.id, c.code, c.code
from tenants t
cross join (values ('Hardware'),('Software'),('Network'),('Access'),('Other')) as c(code)
on conflict (tenant_id, code) do nothing;

-- SLA Policies: target resolution hours per ticket priority. One row
-- per tenant per priority (matches the fixed it_tickets.priority enum).
create table public.sla_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  priority text not null check (priority in ('low','medium','high','urgent')),
  target_hours integer not null check (target_hours > 0),
  description text,
  updated_at timestamptz not null default now(),
  unique (tenant_id, priority)
);

alter table public.sla_policies enable row level security;

create policy sla_policies_select on public.sla_policies
  for select using (tenant_id = get_my_tenant_id());

create or replace function public.get_sla_policies()
returns setof public.sla_policies
language sql
security definer
set search_path = public
as $$
  select * from sla_policies where tenant_id = get_my_tenant_id()
  order by case priority when 'urgent' then 0 when 'high' then 1 when 'medium' then 2 else 3 end;
$$;

create or replace function public.upsert_sla_policy(p_priority text, p_target_hours integer, p_description text default null)
returns public.sla_policies
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.sla_policies%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage SLA policies';
  end if;
  if p_priority not in ('low','medium','high','urgent') then
    raise exception 'invalid priority: %', p_priority;
  end if;

  insert into sla_policies (tenant_id, priority, target_hours, description)
  values (get_my_tenant_id(), p_priority, p_target_hours, p_description)
  on conflict (tenant_id, priority)
  do update set target_hours = excluded.target_hours, description = excluded.description, updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

-- Seed default SLA targets so the report/admin screens start populated.
insert into sla_policies (tenant_id, priority, target_hours, description)
select t.id, v.priority, v.target_hours, v.description
from tenants t
cross join (values
  ('urgent', 4, 'Critical outage or blocker'),
  ('high', 8, 'Significant impact, no workaround'),
  ('medium', 24, 'Moderate impact, workaround available'),
  ('low', 72, 'Minor issue, low urgency')
) as v(priority, target_hours, description)
on conflict (tenant_id, priority) do nothing;

-- Priority Levels: display metadata (label/color) for the fixed
-- it_tickets.priority enum. Update-only by design -- codes are not
-- addable/removable here since the underlying CHECK constraint on
-- it_tickets.priority would need a matching migration to support a new
-- code.
create table public.priority_levels (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  code text not null check (code in ('low','medium','high','urgent')),
  label text not null,
  color text not null default '#757575',
  sort_order integer not null default 0,
  unique (tenant_id, code)
);

alter table public.priority_levels enable row level security;

create policy priority_levels_select on public.priority_levels
  for select using (tenant_id = get_my_tenant_id());

create or replace function public.get_priority_levels()
returns setof public.priority_levels
language sql
security definer
set search_path = public
as $$
  select * from priority_levels where tenant_id = get_my_tenant_id() order by sort_order;
$$;

create or replace function public.update_priority_level(p_code text, p_label text default null, p_color text default null)
returns public.priority_levels
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.priority_levels%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage priority levels';
  end if;
  update priority_levels
  set label = coalesce(p_label, label), color = coalesce(p_color, color)
  where code = p_code and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'priority level not found';
  end if;
  return v_row;
end;
$$;

insert into priority_levels (tenant_id, code, label, color, sort_order)
select t.id, v.code, v.label, v.color, v.sort_order
from tenants t
cross join (values
  ('urgent', 'Urgent', '#d32f2f', 0),
  ('high', 'High', '#ed6c02', 1),
  ('medium', 'Medium', '#0288d1', 2),
  ('low', 'Low', '#2e7d32', 3)
) as v(code, label, color, sort_order)
on conflict (tenant_id, code) do nothing;

-- Support Teams: named groupings of IT support staff, usable later as
-- an assignment target on it_tickets.assignee_id (still an individual
-- user for now -- teams are tracked here as a first step).
create table public.support_teams (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.support_team_members (
  team_id uuid not null references public.support_teams(id) on delete cascade,
  user_id uuid not null references public.app_users(id),
  added_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

alter table public.support_teams enable row level security;
alter table public.support_team_members enable row level security;

create policy support_teams_select on public.support_teams
  for select using (tenant_id = get_my_tenant_id());

create policy support_team_members_select on public.support_team_members
  for select using (
    exists (select 1 from support_teams st where st.id = support_team_members.team_id and st.tenant_id = get_my_tenant_id())
  );

create or replace function public.get_support_teams()
returns table (id uuid, name text, description text, is_active boolean, member_count bigint, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select st.id, st.name, st.description, st.is_active, count(m.user_id), st.created_at
  from support_teams st
  left join support_team_members m on m.team_id = st.id
  where st.tenant_id = get_my_tenant_id()
  group by st.id
  order by st.name;
$$;

create or replace function public.create_support_team(p_name text, p_description text default null)
returns public.support_teams
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage support teams';
  end if;
  insert into support_teams (tenant_id, name, description)
  values (get_my_tenant_id(), p_name, p_description)
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.update_support_team(p_id uuid, p_name text default null, p_description text default null, p_is_active boolean default null)
returns public.support_teams
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage support teams';
  end if;
  update support_teams
  set name = coalesce(p_name, name), description = coalesce(p_description, description), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'support team not found';
  end if;
  return v_row;
end;
$$;

create or replace function public.get_support_team_members(p_team_id uuid)
returns table (user_id uuid, name text, email text, added_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view team members';
  end if;
  return query
  select u.id, u.name, u.email, m.added_at
  from support_team_members m
  join app_users u on u.id = m.user_id
  join support_teams st on st.id = m.team_id
  where m.team_id = p_team_id and st.tenant_id = get_my_tenant_id()
  order by u.name;
end;
$$;

create or replace function public.add_support_team_member(p_team_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage team membership';
  end if;
  if not exists (select 1 from support_teams where id = p_team_id and tenant_id = get_my_tenant_id()) then
    raise exception 'team not found';
  end if;
  insert into support_team_members (team_id, user_id) values (p_team_id, p_user_id)
  on conflict do nothing;
end;
$$;

create or replace function public.remove_support_team_member(p_team_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage team membership';
  end if;
  delete from support_team_members
  where team_id = p_team_id and user_id = p_user_id
    and team_id in (select id from support_teams where tenant_id = get_my_tenant_id());
end;
$$;
