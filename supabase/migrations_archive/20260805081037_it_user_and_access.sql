
-- Access Requests: employees request access to a system/resource; IT
-- support decides. Same shape as asset_requests.
create table public.access_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  requested_by uuid not null references public.app_users(id),
  resource text not null,
  access_level text,
  justification text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid references public.app_users(id),
  decided_at timestamptz,
  decision_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.access_requests enable row level security;

create policy access_requests_select on public.access_requests
  for select
  using (
    tenant_id = get_my_tenant_id()
    and (requested_by = auth.uid() or is_it_support())
  );

create or replace function public.create_access_request(
  p_resource text,
  p_access_level text default null,
  p_justification text default null
) returns public.access_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.access_requests%rowtype;
begin
  if p_resource is null or trim(p_resource) = '' then
    raise exception 'resource/system is required';
  end if;

  insert into access_requests (tenant_id, requested_by, resource, access_level, justification)
  values (get_my_tenant_id(), auth.uid(), p_resource, p_access_level, p_justification)
  returning * into v_request;

  return v_request;
end;
$$;

create or replace function public.get_my_access_requests()
returns setof public.access_requests
language sql
security definer
set search_path = public
as $$
  select * from access_requests where requested_by = auth.uid() order by created_at desc;
$$;

create or replace function public.get_access_requests(p_status text default null)
returns table (
  id uuid,
  requested_by uuid,
  requester_name text,
  resource text,
  access_level text,
  justification text,
  status text,
  decided_by uuid,
  decided_at timestamptz,
  decision_notes text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view access requests';
  end if;

  return query
  select r.id, r.requested_by, u.name, r.resource, r.access_level, r.justification,
         r.status, r.decided_by, r.decided_at, r.decision_notes, r.created_at
  from access_requests r
  join app_users u on u.id = r.requested_by
  where r.tenant_id = get_my_tenant_id()
    and (p_status is null or r.status = p_status)
  order by r.created_at desc;
end;
$$;

create or replace function public.decide_access_request(
  p_request_id uuid,
  p_decision text,
  p_notes text default null
) returns public.access_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.access_requests%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to decide access requests';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from access_requests where id = p_request_id for update;
  if not found or v_request.tenant_id != get_my_tenant_id() then
    raise exception 'request not found';
  end if;
  if v_request.status != 'pending' then
    raise exception 'request is not pending (status: %)', v_request.status;
  end if;

  update access_requests
  set status = p_decision, decided_by = auth.uid(), decided_at = now(),
      decision_notes = p_notes, updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_request.tenant_id, v_request.requested_by, 'access_request_' || p_decision,
    'Access request ' || p_decision || ': ' || v_request.resource,
    coalesce(p_notes, 'Your access request has been ' || p_decision || '.')
  );

  return v_request;
end;
$$;

-- Account management: IT support can update a user's department/role
-- title. Escalating is_platform_admin is restricted to callers who are
-- already platform admins, to prevent privilege escalation by any
-- ordinary IT support member.
create or replace function public.update_app_user(
  p_user_id uuid,
  p_department_id uuid default null,
  p_role_title text default null,
  p_is_platform_admin boolean default null
) returns public.app_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.app_users%rowtype;
  v_caller public.app_users%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage accounts';
  end if;
  select * into v_caller from app_users where id = auth.uid();
  select * into v_user from app_users where id = p_user_id for update;
  if not found or v_user.tenant_id != get_my_tenant_id() then
    raise exception 'user not found';
  end if;
  if p_is_platform_admin is not null and not v_caller.is_platform_admin then
    raise exception 'only a platform admin can change platform admin status';
  end if;

  update app_users
  set department_id = coalesce(p_department_id, department_id),
      role_title = coalesce(p_role_title, role_title),
      is_platform_admin = coalesce(p_is_platform_admin, is_platform_admin)
  where id = p_user_id
  returning * into v_user;

  return v_user;
end;
$$;

-- Groups: simple named collections of users, managed by IT support.
create table public.user_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  name text not null,
  description text,
  created_at timestamptz not null default now()
);

create table public.user_group_members (
  group_id uuid not null references public.user_groups(id) on delete cascade,
  user_id uuid not null references public.app_users(id),
  added_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

alter table public.user_groups enable row level security;
alter table public.user_group_members enable row level security;

create policy user_groups_select on public.user_groups
  for select using (tenant_id = get_my_tenant_id() and is_it_support());

create policy user_group_members_select on public.user_group_members
  for select using (
    exists (
      select 1 from user_groups g
      where g.id = user_group_members.group_id
        and g.tenant_id = get_my_tenant_id()
        and is_it_support()
    )
  );

create or replace function public.get_groups()
returns table (id uuid, name text, description text, member_count bigint, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view groups';
  end if;
  return query
  select g.id, g.name, g.description, count(m.user_id), g.created_at
  from user_groups g
  left join user_group_members m on m.group_id = g.id
  where g.tenant_id = get_my_tenant_id()
  group by g.id
  order by g.name;
end;
$$;

create or replace function public.create_group(p_name text, p_description text default null)
returns public.user_groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group public.user_groups%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create groups';
  end if;
  insert into user_groups (tenant_id, name, description)
  values (get_my_tenant_id(), p_name, p_description)
  returning * into v_group;
  return v_group;
end;
$$;

create or replace function public.get_group_members(p_group_id uuid)
returns table (user_id uuid, name text, email text, added_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view group members';
  end if;
  return query
  select u.id, u.name, u.email, m.added_at
  from user_group_members m
  join app_users u on u.id = m.user_id
  join user_groups g on g.id = m.group_id
  where m.group_id = p_group_id and g.tenant_id = get_my_tenant_id()
  order by u.name;
end;
$$;

create or replace function public.add_group_member(p_group_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage group membership';
  end if;
  if not exists (select 1 from user_groups where id = p_group_id and tenant_id = get_my_tenant_id()) then
    raise exception 'group not found';
  end if;
  insert into user_group_members (group_id, user_id)
  values (p_group_id, p_user_id)
  on conflict do nothing;
end;
$$;

create or replace function public.remove_group_member(p_group_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage group membership';
  end if;
  delete from user_group_members
  where group_id = p_group_id and user_id = p_user_id
    and group_id in (select id from user_groups where tenant_id = get_my_tenant_id());
end;
$$;
