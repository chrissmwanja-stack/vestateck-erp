-- =====================================================================
-- Platform team, global user directory, and "View as this user"
-- =====================================================================
--
-- Operator-console item 4 (see ROADMAP Priority 5). Three related gaps:
--
--  A. THE PLATFORM TEAM WAS HARD-WIRED TO ONE PERSON.
--     app_users_single_platform_admin was a partial unique index that
--     allowed exactly one is_platform_admin = true row in the whole table.
--     Fine for day one; not fine once a second person helps run the
--     platform. It is replaced by a trigger guard that (a) refuses direct
--     flips from ordinary sessions -- the flag can only change through
--     set_platform_admin(), which needs a reason and is audited, (b) still
--     lets the bootstrap-admin edge function claim the *first* admin under
--     an advisory lock (raising the same 23505 it already handles when it
--     loses that race), and (c) never lets the last admin be removed.
--
--  B. NO CROSS-TENANT VIEW OF PEOPLE.
--     app_users RLS is tenant-scoped, so the console had no way to answer
--     "who is this email?", "who are the company admins without MFA?",
--     "who hasn't signed in for 60 days?". platform_users_directory() is a
--     SECURITY DEFINER search over app_users + tenants + auth.users
--     (last_sign_in_at) + auth.mfa_factors, filtered and paged.
--
--  C. IMPERSONATION WAS ALL-OR-NOTHING.
--     "View as" put the operator inside a company with every permission
--     check bypassed -- useful for fixing things, useless for reproducing
--     "why can't Jane see the HR menu?". impersonation_sessions gains an
--     optional impersonated_user_id; when set, the permission helpers
--     evaluate *that* user's staff_roles / finance / approval / admin
--     flags instead of granting the platform bypass. Writes are still
--     attributed to the operator's own auth.uid() (created_by etc.), and
--     the read-only guard applies exactly as it would for the user.
--
-- Additive: no column or table drops. The index drop in A is a
-- constraint relaxation, replaced by the trigger in the same file.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. The reserved platform home tenant must exist
-- ---------------------------------------------------------------------
-- bootstrap-admin inserts app_users rows with this tenant_id and the
-- baseline only ever *commented* on the id. Make it real so a fresh
-- stack can bootstrap without a manual insert.
insert into public.tenants (id, name, status, plan, subscription_status, industry_template)
values ('00000000-0000-0000-0000-000000000099', 'Platform (internal)', 'active', 'internal', 'active', 'general')
on conflict (id) do nothing;


-- ---------------------------------------------------------------------
-- A. Platform team: many admins, guarded flag, audited grant/revoke
-- ---------------------------------------------------------------------
drop index if exists public.app_users_single_platform_admin;

-- The flag guard. Policed only for API-originated writes (a JWT role is
-- present); migrations, seeds and SQL tests run without claims and are
-- left alone.
create or replace function public.app_users_platform_admin_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_req_role text := platform_request_role();
  v_others   integer;
begin
  if v_req_role is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.is_platform_admin is not distinct from old.is_platform_admin then
    return new;
  end if;
  if tg_op = 'INSERT' and not new.is_platform_admin then
    return new;
  end if;

  -- Path 1: set_platform_admin() marks the transaction with the id it is
  -- changing. Anything else from an ordinary session is refused below.
  if current_setting('platform.admin_change', true) = new.id::text then
    return new;
  end if;

  if v_req_role = 'service_role' then
    if new.is_platform_admin then
      -- Path 2: bootstrap. Serialise concurrent claims and allow only
      -- while nobody holds the flag. Same errcode + constraint name the
      -- old partial unique index produced, so bootstrap-admin's existing
      -- 23505 handling keeps working unchanged.
      perform pg_advisory_xact_lock(hashtext('app_users_single_platform_admin'));
      select count(*) into v_others from app_users u where u.is_platform_admin and u.id <> new.id;
      if v_others > 0 then
        raise exception 'duplicate key value violates unique constraint "app_users_single_platform_admin": a platform admin already exists; further grants go through set_platform_admin()'
          using errcode = '23505';
      end if;
      return new;
    else
      select count(*) into v_others from app_users u where u.is_platform_admin and u.id <> new.id;
      if v_others = 0 then
        raise exception 'PLATFORM_LAST_ADMIN: cannot remove the only platform admin'
          using errcode = '23514';
      end if;
      return new;
    end if;
  end if;

  raise exception 'PLATFORM_ADMIN_GUARD: platform admin status is changed from the operator console (set_platform_admin), not by editing the user'
    using errcode = '42501';
end;
$$;

drop trigger if exists app_users_platform_admin_guard on public.app_users;
create trigger app_users_platform_admin_guard
  before insert or update of is_platform_admin on public.app_users
  for each row execute function public.app_users_platform_admin_guard();

comment on column public.app_users.is_platform_admin is
  'Operator (vendor) super-admin. Changed only via set_platform_admin() (reason required, audited); app_users_platform_admin_guard() enforces that and keeps at least one admin.';


create or replace function public.set_platform_admin(p_user_id uuid, p_enabled boolean, p_reason text default null)
returns public.app_users
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user   app_users%rowtype;
  v_reason text := nullif(btrim(p_reason), '');
  v_others integer;
begin
  perform require_platform_admin('Changing the platform team');

  if v_reason is null or length(v_reason) < 5 then
    raise exception 'A reason (at least 5 characters) is required to change who is on the platform team';
  end if;

  select * into v_user from app_users where id = p_user_id for update;
  if not found then
    raise exception 'No such user';
  end if;

  -- Idempotent: nothing to do, nothing to audit.
  if v_user.is_platform_admin = p_enabled then
    return v_user;
  end if;

  if not p_enabled then
    if p_user_id = auth.uid() then
      raise exception 'You cannot remove yourself from the platform team; ask another platform admin to do it';
    end if;
    select count(*) into v_others from app_users u where u.is_platform_admin and u.id <> p_user_id;
    if v_others = 0 then
      raise exception 'PLATFORM_LAST_ADMIN: cannot remove the only platform admin';
    end if;
    -- A revoked operator must not keep an open View-as session.
    update impersonation_sessions
    set ended_at = now()
    where platform_admin_id = p_user_id and ended_at is null;
  end if;

  perform set_config('platform.admin_change', p_user_id::text, true);
  update app_users set is_platform_admin = p_enabled where id = p_user_id returning * into v_user;
  perform set_config('platform.admin_change', '', true);

  perform log_platform_event(
    case when p_enabled then 'platform_admin.grant' else 'platform_admin.revoke' end,
    v_user.tenant_id, 'app_user', p_user_id::text, v_reason,
    jsonb_build_object('is_platform_admin', not p_enabled),
    jsonb_build_object('is_platform_admin', p_enabled, 'email', v_user.email, 'name', v_user.name)
  );

  return v_user;
end;
$$;

revoke execute on function public.set_platform_admin(uuid, boolean, text) from public;
grant  execute on function public.set_platform_admin(uuid, boolean, text) to authenticated;


create or replace function public.list_platform_admins()
returns table (
  user_id          uuid,
  name             text,
  email            text,
  tenant_id        uuid,
  tenant_name      text,
  mfa_enrolled     boolean,
  last_sign_in_at  timestamptz,
  created_at       timestamptz,
  granted_at       timestamptz,
  granted_by_email text,
  is_self          boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform require_platform_admin('The platform team list');

  return query
  select
    u.id,
    u.name,
    u.email,
    u.tenant_id,
    t.name,
    exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified'),
    au.last_sign_in_at,
    u.created_at,
    g.created_at,
    g.actor_email,
    (u.id = auth.uid())
  from app_users u
  join tenants t on t.id = u.tenant_id
  left join auth.users au on au.id = u.id
  left join lateral (
    select e.created_at, e.actor_email
    from platform_audit_events e
    where e.action = 'platform_admin.grant' and e.target_id = u.id::text
    order by e.created_at desc
    limit 1
  ) g on true
  where u.is_platform_admin
  order by u.created_at, u.email;
end;
$$;

revoke execute on function public.list_platform_admins() from public;
grant  execute on function public.list_platform_admins() to authenticated;


-- update_app_user() (IT-support account screen) used to let a platform
-- admin flip the flag on anyone in their tenant with no reason and no
-- audit trail. The guard trigger would now refuse that anyway; fail with
-- a message that points at the right place instead of a trigger error.
create or replace function public.update_app_user(
  p_user_id uuid,
  p_department_id uuid default null,
  p_role_title text default null,
  p_is_platform_admin boolean default null
)
returns public.app_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.app_users%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage accounts';
  end if;
  select * into v_user from app_users where id = p_user_id for update;
  if not found or v_user.tenant_id != get_my_tenant_id() then
    raise exception 'user not found';
  end if;
  if p_is_platform_admin is not null and p_is_platform_admin is distinct from v_user.is_platform_admin then
    raise exception 'Platform admin status is managed from the platform console (Team), not from account management';
  end if;

  update app_users
  set department_id = coalesce(p_department_id, department_id),
      role_title = coalesce(p_role_title, role_title)
  where id = p_user_id
  returning * into v_user;

  return v_user;
end;
$$;


-- ---------------------------------------------------------------------
-- B. Global user directory
-- ---------------------------------------------------------------------
-- p_kind: platform_admin | company_admin | finance | member (neither
--         platform nor company admin) | null = everyone
-- p_module: only users holding a staff_roles row for this module
-- p_quiet_days: only users with no sign-in in the last N days (never
--               signed in counts as quiet)
create or replace function public.platform_users_directory(
  p_search     text    default null,
  p_tenant_id  uuid    default null,
  p_kind       text    default null,
  p_module     text    default null,
  p_quiet_days integer default null,
  p_limit      integer default 50,
  p_offset     integer default 0
)
returns table (
  user_id           uuid,
  name              text,
  email             text,
  role_title        text,
  tenant_id         uuid,
  tenant_name       text,
  tenant_status     text,
  is_platform_admin boolean,
  is_company_admin  boolean,
  modules           jsonb,
  finance_role      text,
  mfa_enrolled      boolean,
  last_sign_in_at   timestamptz,
  created_at        timestamptz,
  total_count       bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_search text := nullif(btrim(p_search), '');
begin
  perform require_platform_admin('The user directory');

  return query
  with base as (
    select
      u.id                as b_user_id,
      u.name              as b_name,
      u.email             as b_email,
      u.role_title        as b_role_title,
      u.tenant_id         as b_tenant_id,
      t.name              as b_tenant_name,
      t.status            as b_tenant_status,
      u.is_platform_admin as b_is_platform_admin,
      u.is_company_admin  as b_is_company_admin,
      coalesce(
        (select jsonb_agg(jsonb_build_object('module', sr.module, 'role', sr.role) order by sr.module)
         from staff_roles sr
         where sr.user_id = u.id and sr.tenant_id = u.tenant_id),
        '[]'::jsonb
      )                   as b_modules,
      (select ftm.role
       from finance_team_members ftm
       where ftm.user_id = u.id and ftm.tenant_id = u.tenant_id
       order by case ftm.role when 'finance' then 0 else 1 end
       limit 1)           as b_finance_role,
      exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified')
                          as b_mfa_enrolled,
      au.last_sign_in_at  as b_last_sign_in_at,
      u.created_at        as b_created_at
    from app_users u
    join tenants t on t.id = u.tenant_id
    left join auth.users au on au.id = u.id
  )
  select
    b.b_user_id, b.b_name, b.b_email, b.b_role_title, b.b_tenant_id, b.b_tenant_name, b.b_tenant_status,
    b.b_is_platform_admin, b.b_is_company_admin, b.b_modules, b.b_finance_role, b.b_mfa_enrolled,
    b.b_last_sign_in_at, b.b_created_at,
    count(*) over () as total_count
  from base b
  where (v_search is null
         or b.b_name ilike '%' || v_search || '%'
         or b.b_email ilike '%' || v_search || '%'
         or b.b_tenant_name ilike '%' || v_search || '%')
    and (p_tenant_id is null or b.b_tenant_id = p_tenant_id)
    and (p_kind is null or case p_kind
           when 'platform_admin' then b.b_is_platform_admin
           when 'company_admin'  then b.b_is_company_admin
           when 'finance'        then b.b_finance_role is not null
           when 'member'         then not b.b_is_platform_admin and not b.b_is_company_admin
           else true end)
    and (p_module is null or b.b_modules @> jsonb_build_array(jsonb_build_object('module', p_module)))
    and (p_quiet_days is null
         or b.b_last_sign_in_at is null
         or b.b_last_sign_in_at < now() - make_interval(days => p_quiet_days))
  order by b.b_tenant_name, b.b_email
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;

revoke execute on function public.platform_users_directory(text, uuid, text, text, integer, integer, integer) from public;
grant  execute on function public.platform_users_directory(text, uuid, text, text, integer, integer, integer) to authenticated;


-- ---------------------------------------------------------------------
-- C. View as a specific user
-- ---------------------------------------------------------------------
alter table public.impersonation_sessions
  add column if not exists impersonated_user_id uuid references public.app_users(id) on delete set null;

create index if not exists impersonation_sessions_user_idx
  on public.impersonation_sessions (impersonated_user_id)
  where impersonated_user_id is not null;

comment on column public.impersonation_sessions.impersonated_user_id is
  'NULL = company-level View-as (platform bypass). Set = evaluate permissions as this user (effective_user_id()); writes still attributed to the operator.';

-- The active session's target user, if any.
create or replace function public.impersonated_user_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.impersonated_user_id
  from impersonation_sessions s
  where s.platform_admin_id = auth.uid()
    and s.ended_at is null
    and s.expires_at > now()
  order by s.started_at desc
  limit 1;
$$;

-- Whose permissions apply to this request.
create or replace function public.effective_user_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(impersonated_user_id(), auth.uid());
$$;

-- "Skip the permission checks": a platform admin NOT viewing as a
-- specific user. Every permission helper below uses this instead of
-- is_platform_admin() -- is_platform_admin() itself is unchanged and
-- keeps meaning "this session belongs to an operator".
create or replace function public.platform_admin_bypass()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select is_platform_admin() and impersonated_user_id() is null;
$$;

revoke execute on function public.impersonated_user_id()   from public;
revoke execute on function public.effective_user_id()      from public;
revoke execute on function public.platform_admin_bypass()  from public;
grant  execute on function public.impersonated_user_id()   to authenticated;
grant  execute on function public.effective_user_id()      to authenticated;
grant  execute on function public.platform_admin_bypass()  to authenticated;


create or replace function public.start_impersonation(p_tenant_id uuid, p_reason text, p_user_id uuid)
returns public.impersonation_sessions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session impersonation_sessions;
  v_reason  text := nullif(btrim(p_reason), '');
  v_tenant  tenants%rowtype;
  v_target  app_users%rowtype;
begin
  perform require_platform_admin('Impersonation');

  if v_reason is null or length(v_reason) < 5 then
    raise exception 'A reason (at least 5 characters) is required to view a company as its users';
  end if;

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    raise exception 'No such tenant';
  end if;

  if p_user_id is not null then
    select * into v_target from app_users where id = p_user_id;
    if not found or v_target.tenant_id <> p_tenant_id then
      raise exception 'No such user in this company';
    end if;
    if v_target.is_platform_admin then
      raise exception 'Platform admins cannot be impersonated';
    end if;
  end if;

  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_sessions (platform_admin_id, tenant_id, reason, expires_at, impersonated_user_id)
  values (auth.uid(), p_tenant_id, v_reason, now() + interval '2 hours', p_user_id)
  returning * into v_session;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_tenant_id, 'start');

  perform log_platform_event(
    'impersonation.start', p_tenant_id,
    case when p_user_id is null then 'tenant' else 'app_user' end,
    coalesce(p_user_id::text, p_tenant_id::text),
    v_reason,
    null,
    jsonb_build_object(
      'session_id', v_session.id,
      'tenant_name', v_tenant.name,
      'expires_at', v_session.expires_at,
      'as_user_id', p_user_id,
      'as_user_email', v_target.email
    )
  );

  return v_session;
end;
$$;

-- Company-level View-as keeps its own signature (PostgREST resolves
-- overloads by the named arguments supplied, so the 3-arg form must not
-- default p_user_id).
create or replace function public.start_impersonation(p_tenant_id uuid, p_reason text)
returns public.impersonation_sessions
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.start_impersonation(p_tenant_id, p_reason, null::uuid);
$$;

revoke execute on function public.start_impersonation(uuid, text, uuid) from public;
revoke execute on function public.start_impersonation(uuid, text)       from public;
grant  execute on function public.start_impersonation(uuid, text, uuid) to authenticated;
grant  execute on function public.start_impersonation(uuid, text)       to authenticated;


-- Output shape changes -> drop and recreate (clients read by column name).
drop function if exists public.get_active_impersonation();
create function public.get_active_impersonation()
returns table (
  tenant_id               uuid,
  tenant_name             text,
  reason                  text,
  started_at              timestamptz,
  expires_at              timestamptz,
  impersonated_user_id    uuid,
  impersonated_user_name  text,
  impersonated_user_email text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.id, t.name, s.reason, s.started_at, s.expires_at, s.impersonated_user_id, u.name, u.email
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  left join app_users u on u.id = s.impersonated_user_id
  where s.platform_admin_id = auth.uid()
    and s.ended_at is null
    and s.expires_at > now()
  order by s.started_at desc
  limit 1;
$$;

revoke execute on function public.get_active_impersonation() from public;
grant  execute on function public.get_active_impersonation() to authenticated;


drop function if exists public.list_impersonation_history(uuid, integer, integer);
create function public.list_impersonation_history(
  p_tenant_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id                      uuid,
  platform_admin_id       uuid,
  platform_admin_email    text,
  tenant_id               uuid,
  tenant_name             text,
  reason                  text,
  started_at              timestamptz,
  ended_at                timestamptz,
  expires_at              timestamptz,
  is_active               boolean,
  impersonated_user_id    uuid,
  impersonated_user_email text,
  total_count             bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    s.id,
    s.platform_admin_id,
    u.email,
    s.tenant_id,
    t.name,
    s.reason,
    s.started_at,
    s.ended_at,
    s.expires_at,
    (s.ended_at is null and s.expires_at > now()) as is_active,
    s.impersonated_user_id,
    iu.email,
    count(*) over () as total_count
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  left join auth.users u on u.id = s.platform_admin_id
  left join app_users iu on iu.id = s.impersonated_user_id
  where is_platform_admin()
    and (p_tenant_id is null or s.tenant_id = p_tenant_id)
  order by s.started_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0));
$$;

revoke execute on function public.list_impersonation_history(uuid, integer, integer) from public;
grant  execute on function public.list_impersonation_history(uuid, integer, integer) to authenticated;


-- ---------------------------------------------------------------------
-- C2. Permission helpers: bypass only when not viewing as a user;
--     otherwise evaluate the impersonated user's rows.
-- ---------------------------------------------------------------------
-- Bodies are the existing ones with is_platform_admin() -> platform_admin_bypass()
-- and auth.uid() (as the *subject of the permission*) -> effective_user_id().
-- Signatures, volatility and grants are unchanged.

create or replace function public.has_module_role(p_module text, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.platform_admin_bypass()
    or (
      exists (
        select 1 from public.tenant_modules
        where tenant_id = public.get_my_tenant_id()
          and module = p_module
      )
      and exists (
        select 1 from public.staff_roles
        where user_id = public.effective_user_id()
          and module = p_module
          and role = any(p_roles)
          and tenant_id = public.get_my_tenant_id()
      )
    );
$$;

create or replace function public.is_any_module_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.platform_admin_bypass()
    or exists (
      select 1 from public.staff_roles
      where user_id = public.effective_user_id()
        and role = 'admin'
        and tenant_id = public.get_my_tenant_id()
    );
$$;

create or replace function public.is_company_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_company_admin from app_users where id = public.effective_user_id()),
    false
  );
$$;

create or replace function public.is_tenant_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.platform_admin_bypass()
    or exists (
      select 1 from app_users
      where id = public.effective_user_id()
        and is_company_admin
    );
$$;

create or replace function public.is_finance_team_member(p_role text default null)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    public.platform_admin_bypass()
    or exists (
      select 1 from finance_team_members
      where user_id = public.effective_user_id()
        and tenant_id = get_my_tenant_id()
        and (p_role is null or role = p_role)
    );
$$;

create or replace function public.is_hr_team_member(p_role text default null)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    public.platform_admin_bypass()
    or exists (
      select 1 from hr_team_members
      where user_id = public.effective_user_id()
        and tenant_id = get_my_tenant_id()
        and (p_role is null or role = p_role)
    );
$$;

create or replace function public.is_payroll_approver()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    public.platform_admin_bypass()
    or exists (
      select 1 from payroll_approvers
      where user_id = public.effective_user_id()
        and tenant_id = get_my_tenant_id()
        and is_active
    );
$$;

create or replace function public.has_po_access()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.platform_admin_bypass()
    or exists (
      select 1
      from approval_assignments aa
      join workflow_stages ws on ws.id = aa.workflow_stage_id
      where aa.user_id = public.effective_user_id()
        and ws.next_stage_low_id is null
        and ws.next_stage_high_id is null
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      join workflow_stages ws on ws.id = aa.workflow_stage_id
      where d.delegate_user_id = public.effective_user_id()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and ws.next_stage_low_id is null
        and ws.next_stage_high_id is null
        and (d.workflow_stage_id is null or d.workflow_stage_id = ws.id)
    );
$$;

create or replace function public.can_act_on_stage(check_stage_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.platform_admin_bypass()
    or exists (
      select 1 from approval_assignments aa
      where aa.user_id = public.effective_user_id()
        and aa.workflow_stage_id = check_stage_id
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      where d.delegate_user_id = public.effective_user_id()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and aa.workflow_stage_id = check_stage_id
        and (d.workflow_stage_id is null or d.workflow_stage_id = check_stage_id)
    );
$$;

create or replace function public.has_receipt_access()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from material_receipt_assignments
    where user_id = public.effective_user_id() and tenant_id = get_my_tenant_id()
  );
$$;

create or replace function public.can_manage_po_handoff(p_purchase_order_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_request_id uuid;
  v_selected_offer_submitter uuid;
  v_me uuid := public.effective_user_id();
begin
  select request_id into v_request_id
  from purchase_orders
  where id = p_purchase_order_id;

  if v_request_id is null then
    return false;
  end if;

  select submitted_by into v_selected_offer_submitter
  from request_offers
  where request_id = v_request_id and is_selected
  limit 1;

  if v_selected_offer_submitter = v_me then
    return true;
  end if;

  if exists (
    select 1 from approval_actions
    where request_id = v_request_id and approver_id = v_me
  ) then
    return true;
  end if;

  return has_po_access();
end;
$$;

-- Read-only mode: an operator viewing as a user is refused writes just
-- like that user would be. Company-level View-as still bypasses.
create or replace function public.tenant_read_only_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id uuid;
  v_read_only boolean;
  v_reason    text;
  v_name      text;
begin
  if coalesce(platform_request_role(), '') <> 'authenticated' then
    return coalesce(new, old);
  end if;
  if platform_admin_bypass() then
    return coalesce(new, old);
  end if;

  v_tenant_id := coalesce(
    case when tg_op = 'DELETE' then old.tenant_id else new.tenant_id end,
    get_my_tenant_id()
  );
  if v_tenant_id is null then
    return coalesce(new, old);
  end if;

  select read_only, read_only_reason, name
  into v_read_only, v_reason, v_name
  from tenants where id = v_tenant_id;

  if coalesce(v_read_only, false) then
    raise exception 'TENANT_READ_ONLY: % is currently in read-only mode (%). Changes are not being accepted.',
      coalesce(v_name, 'This company'), coalesce(v_reason, 'no reason recorded')
      using errcode = 'insufficient_privilege';
  end if;

  return coalesce(new, old);
end;
$$;
