-- Platform-admin hardening, part 1 of the operator-console workstream
-- (see vestateck-erp-platform-admin-review.md §6, item 1).
--
-- The platform-admin account is the vendor's super-user: it can step into
-- any customer tenant (payroll, GL, HR). Before adding helpers to that
-- role, three gaps had to close:
--
--   1. No audit trail. set_tenant_status / set_tenant_modules /
--      update_workflow_stage_threshold / platform_settings edits /
--      invitation revokes left no record of who, when, or why. Only
--      impersonation start/end was logged, and nothing read that table.
--
--   2. Impersonation captured no reason and had no explicit expiry the
--      operator could see (get_my_tenant_id() silently ignores sessions
--      older than 2 h; the banner had no idea).
--
--   3. Privileged actions were reachable with a password-only session.
--      is_platform_admin() only checked the app_users flag; a stolen
--      password was enough to suspend a customer or impersonate them.
--
-- What this migration does (all additive -- no drops, no renames):
--
--   * platform_audit_events            -- append-only, platform-admin
--                                         readable, written only by
--                                         SECURITY DEFINER code via
--                                         log_platform_event().
--   * platform_session_is_mfa()        -- true when the JWT's aal claim is
--                                         'aal2' (Supabase sets this after
--                                         a successful TOTP challenge).
--   * require_platform_admin(p_action) -- single guard every privileged
--                                         platform RPC now calls: flag AND
--                                         MFA-verified session. MFA is
--                                         enforced only when the operator
--                                         has at least one verified TOTP
--                                         factor -- so a fresh install /
--                                         bootstrap admin isn't locked out
--                                         before they've had a chance to
--                                         enrol. The Settings screen and
--                                         RequireAuth already push
--                                         platform admins to enrol.
--   * impersonation_sessions           -- gains reason (required going
--                                         forward), expires_at, and the
--                                         2-hour rule moves from a magic
--                                         number in get_my_tenant_id() to
--                                         that column.
--   * start_impersonation(p_tenant_id, p_reason) -- new 2-arg overload;
--                                         old 1-arg signature kept for
--                                         callers that haven't updated yet
--                                         and rejects with a clear message.
--   * get_active_impersonation()       -- also returns reason, started_at,
--                                         expires_at so the banner can
--                                         show a countdown.
--   * set_tenant_status(p_tenant_id, p_status, p_reason) -- 3-arg overload
--                                         that requires a reason for
--                                         suspension and audits; the 2-arg
--                                         version delegates with null
--                                         reason (still audited, but
--                                         suspension without a reason is
--                                         refused).
--   * set_tenant_modules, update_workflow_stage_threshold,
--     revoke_invitation (platform branch), platform_settings UPDATE
--                                      -- now audited.
--   * list_platform_audit_events(...)  -- paged, filterable read for the
--                                         new /admin/audit screen.
--   * list_impersonation_history(...)  -- paged read over
--                                         impersonation_sessions for the
--                                         same screen.
--
-- Function bodies below restate the baseline versions with the guard /
-- logging added; behaviour for non-platform callers is unchanged.

-- ---------------------------------------------------------------------
-- 1. Audit table
-- ---------------------------------------------------------------------
create table if not exists public.platform_audit_events (
  id            uuid primary key default gen_random_uuid(),
  actor_id      uuid,                                   -- auth.uid() at the time; null for system jobs
  actor_email   text,
  tenant_id     uuid references public.tenants(id) on delete set null,  -- nullable: platform-wide actions
  action        text not null,                          -- e.g. 'tenant.suspend', 'tenant.modules.set'
  target_type   text,                                   -- 'tenant' | 'invitation' | 'workflow_stage' | 'platform_settings' | ...
  target_id     text,                                   -- uuid or other identifier as text
  reason        text,
  before        jsonb,
  after         jsonb,
  mfa_verified  boolean not null default false,
  created_at    timestamptz not null default now()
);

comment on table public.platform_audit_events is
  'Append-only log of every privileged platform-admin action (tenant status/modules, thresholds, settings, invites, impersonation). Written only by SECURITY DEFINER RPCs via log_platform_event(); never by the client.';

create index if not exists platform_audit_events_created_at_idx
  on public.platform_audit_events (created_at desc);
create index if not exists platform_audit_events_tenant_idx
  on public.platform_audit_events (tenant_id, created_at desc);
create index if not exists platform_audit_events_actor_idx
  on public.platform_audit_events (actor_id, created_at desc);

alter table public.platform_audit_events enable row level security;

-- Read: platform admins only. No INSERT/UPDATE/DELETE policies at all --
-- rows arrive exclusively through SECURITY DEFINER functions owned by
-- postgres, and nothing (not even a platform admin) may edit or purge
-- them from the client.
drop policy if exists platform_audit_events_select_platform_admin on public.platform_audit_events;
create policy platform_audit_events_select_platform_admin
  on public.platform_audit_events
  for select
  using (public.is_platform_admin());

revoke all on table public.platform_audit_events from anon;
grant select on table public.platform_audit_events to authenticated;

-- ---------------------------------------------------------------------
-- 2. MFA helpers + the single platform guard
-- ---------------------------------------------------------------------

-- Supabase encodes the assurance level of the current session in the JWT
-- as "aal": "aal1" (password only) or "aal2" (password + verified second
-- factor this session). Reading it from request.jwt.claims keeps this a
-- pure function of the request -- no round-trip to auth.mfa_factors.
create or replace function public.platform_session_is_mfa()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (current_setting('request.jwt.claims', true)::jsonb ->> 'aal') = 'aal2',
    false
  );
$$;

revoke execute on function public.platform_session_is_mfa() from public;
grant  execute on function public.platform_session_is_mfa() to authenticated;

-- Does the caller have at least one verified TOTP factor? Used to decide
-- whether to *enforce* aal2. Once you've enrolled, aal1 sessions can no
-- longer perform privileged platform actions.
create or replace function public.platform_admin_has_mfa_factor()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from auth.mfa_factors f
    where f.user_id = auth.uid()
      and f.status = 'verified'
  );
$$;

revoke execute on function public.platform_admin_has_mfa_factor() from public;
grant  execute on function public.platform_admin_has_mfa_factor() to authenticated;

-- The one guard. Raises with a distinguishable message so the UI can tell
-- "not a platform admin" from "platform admin, but step up with MFA".
create or replace function public.require_platform_admin(p_action text default null)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: % is restricted to platform admins',
      coalesce(p_action, 'this action')
      using errcode = '42501';
  end if;

  if platform_admin_has_mfa_factor() and not platform_session_is_mfa() then
    raise exception 'PLATFORM_MFA_REQUIRED: % requires a session verified with your authenticator (sign out and back in with your code)',
      coalesce(p_action, 'this action')
      using errcode = '42501';
  end if;
end;
$$;

revoke execute on function public.require_platform_admin(text) from public;
grant  execute on function public.require_platform_admin(text) to authenticated;

-- Convenience for the UI: one call to know whether privileged buttons
-- should be enabled, and if not, why.
create or replace function public.get_platform_admin_session()
returns table (
  is_platform_admin boolean,
  has_mfa_factor    boolean,
  session_is_mfa    boolean,
  can_act           boolean
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    is_platform_admin(),
    platform_admin_has_mfa_factor(),
    platform_session_is_mfa(),
    is_platform_admin()
      and (not platform_admin_has_mfa_factor() or platform_session_is_mfa());
$$;

revoke execute on function public.get_platform_admin_session() from public;
grant  execute on function public.get_platform_admin_session() to authenticated;

-- ---------------------------------------------------------------------
-- 3. Logging helper (internal; not granted to clients)
-- ---------------------------------------------------------------------
create or replace function public.log_platform_event(
  p_action      text,
  p_tenant_id   uuid    default null,
  p_target_type text    default null,
  p_target_id   text    default null,
  p_reason      text    default null,
  p_before      jsonb   default null,
  p_after       jsonb   default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into platform_audit_events (
    actor_id, actor_email, tenant_id, action, target_type, target_id,
    reason, before, after, mfa_verified
  )
  values (
    auth.uid(),
    (select email from auth.users where id = auth.uid()),
    p_tenant_id, p_action, p_target_type, p_target_id,
    nullif(btrim(p_reason), ''), p_before, p_after,
    platform_session_is_mfa()
  )
  returning id into v_id;
  return v_id;
end;
$$;

-- Deliberately NOT executable by authenticated: only other SECURITY
-- DEFINER functions (running as postgres) may call it.
revoke execute on function public.log_platform_event(text, uuid, text, text, text, jsonb, jsonb) from public;
revoke execute on function public.log_platform_event(text, uuid, text, text, text, jsonb, jsonb) from authenticated;

-- ---------------------------------------------------------------------
-- 4. Impersonation: reason + explicit expiry
-- ---------------------------------------------------------------------
alter table public.impersonation_sessions
  add column if not exists reason     text,
  add column if not exists expires_at timestamptz;

-- Backfill the implicit rule for any historical rows.
update public.impersonation_sessions
set expires_at = started_at + interval '2 hours'
where expires_at is null;

alter table public.impersonation_sessions
  alter column expires_at set default (now() + interval '2 hours');

comment on column public.impersonation_sessions.reason is
  'Operator-supplied justification, required by start_impersonation(uuid, text). Surfaced in the banner and the audit screen.';
comment on column public.impersonation_sessions.expires_at is
  'Hard expiry honoured by get_my_tenant_id(). Replaces the previous inline "started_at > now() - 2 hours" rule.';

-- get_my_tenant_id(): same semantics, but the window is now the column.
create or replace function public.get_my_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select tenant_id from impersonation_sessions
     where platform_admin_id = auth.uid()
       and ended_at is null
       and expires_at > now()
     limit 1),
    (select u.tenant_id
     from app_users u
     join tenants t on t.id = u.tenant_id
     where u.id = auth.uid()
       and t.status != 'suspended')
  );
$$;

-- New primary signature: reason is mandatory.
create or replace function public.start_impersonation(p_tenant_id uuid, p_reason text)
returns public.impersonation_sessions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session impersonation_sessions;
  v_reason  text := nullif(btrim(p_reason), '');
  v_tenant  tenants%rowtype;
begin
  perform require_platform_admin('Impersonation');

  if v_reason is null or length(v_reason) < 5 then
    raise exception 'A reason (at least 5 characters) is required to view a company as its users';
  end if;

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    raise exception 'No such tenant';
  end if;

  -- Close any stale/dangling session for this admin first.
  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_sessions (platform_admin_id, tenant_id, reason, expires_at)
  values (auth.uid(), p_tenant_id, v_reason, now() + interval '2 hours')
  returning * into v_session;

  -- Keep the legacy log table in step (nothing else writes it) and add
  -- the richer platform event.
  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_tenant_id, 'start');

  perform log_platform_event(
    'impersonation.start', p_tenant_id, 'tenant', p_tenant_id::text, v_reason,
    null,
    jsonb_build_object('session_id', v_session.id, 'tenant_name', v_tenant.name, 'expires_at', v_session.expires_at)
  );

  return v_session;
end;
$$;

revoke execute on function public.start_impersonation(uuid, text) from public;
grant  execute on function public.start_impersonation(uuid, text) to authenticated;

-- Legacy 1-arg signature: kept so an un-updated client fails with a
-- readable message rather than a "function does not exist" 404.
create or replace function public.start_impersonation(p_tenant_id uuid)
returns public.impersonation_sessions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'start_impersonation now requires a reason: call start_impersonation(p_tenant_id, p_reason)';
end;
$$;

create or replace function public.end_impersonation()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session impersonation_sessions%rowtype;
begin
  select * into v_session
  from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null
  order by started_at desc
  limit 1;

  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), v_session.tenant_id, 'end');

  if v_session.id is not null then
    perform log_platform_event(
      'impersonation.end', v_session.tenant_id, 'tenant', v_session.tenant_id::text, null,
      jsonb_build_object('session_id', v_session.id, 'started_at', v_session.started_at),
      jsonb_build_object('ended_at', now())
    );
  end if;
end;
$$;

-- Richer active-session read for the banner (adds reason/started/expires).
-- Same name/arity, wider result set; existing callers only read the first
-- two columns.
drop function if exists public.get_active_impersonation();
create function public.get_active_impersonation()
returns table (
  tenant_id   uuid,
  tenant_name text,
  reason      text,
  started_at  timestamptz,
  expires_at  timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.id, t.name, s.reason, s.started_at, s.expires_at
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  where s.platform_admin_id = auth.uid()
    and s.ended_at is null
    and s.expires_at > now()
  order by s.started_at desc
  limit 1;
$$;

revoke execute on function public.get_active_impersonation() from public;
grant  execute on function public.get_active_impersonation() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Tenant status: reason required for suspension, audited
-- ---------------------------------------------------------------------
create or replace function public.set_tenant_status(p_tenant_id uuid, p_status text, p_reason text)
returns public.tenants
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before public.tenants;
  v_row    public.tenants;
  v_reason text := nullif(btrim(p_reason), '');
begin
  perform require_platform_admin('Changing a company''s status');

  if p_status not in ('active', 'suspended') then
    raise exception 'status must be active or suspended (pending is set automatically)';
  end if;

  select * into v_before from tenants where id = p_tenant_id for update;
  if not found then
    raise exception 'tenant not found';
  end if;

  if p_status = 'suspended' and v_reason is null then
    raise exception 'A reason is required to suspend a company';
  end if;

  if v_before.status = p_status then
    return v_before;  -- no-op, nothing to audit
  end if;

  update tenants
  set status = p_status
  where id = p_tenant_id
  returning * into v_row;

  perform log_platform_event(
    case when p_status = 'suspended' then 'tenant.suspend' else 'tenant.activate' end,
    p_tenant_id, 'tenant', p_tenant_id::text, v_reason,
    jsonb_build_object('status', v_before.status),
    jsonb_build_object('status', v_row.status, 'tenant_name', v_row.name)
  );

  return v_row;
end;
$$;

revoke execute on function public.set_tenant_status(uuid, text, text) from public;
grant  execute on function public.set_tenant_status(uuid, text, text) to authenticated;

-- 2-arg version delegates; suspension without a reason is refused inside.
create or replace function public.set_tenant_status(p_tenant_id uuid, p_status text)
returns public.tenants
language sql
security definer
set search_path = public
as $$
  select public.set_tenant_status(p_tenant_id, p_status, null);
$$;

-- ---------------------------------------------------------------------
-- 6. Modules: audited with before/after sets
-- ---------------------------------------------------------------------
create or replace function public.set_tenant_modules(p_tenant_id uuid, p_modules text[])
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before text[];
  v_after  text[];
begin
  perform require_platform_admin('Changing a company''s modules');

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  select coalesce(array_agg(module order by module), '{}')
    into v_before
  from tenant_modules where tenant_id = p_tenant_id;

  delete from tenant_modules
  where tenant_id = p_tenant_id
    and module != all(coalesce(p_modules, array[]::text[]));

  insert into tenant_modules (tenant_id, module, enabled_by)
  select p_tenant_id, m, auth.uid()
  from unnest(coalesce(p_modules, array[]::text[])) as m
  on conflict (tenant_id, module) do nothing;

  select coalesce(array_agg(module order by module), '{}')
    into v_after
  from tenant_modules where tenant_id = p_tenant_id;

  if v_before is distinct from v_after then
    perform log_platform_event(
      'tenant.modules.set', p_tenant_id, 'tenant', p_tenant_id::text, null,
      jsonb_build_object('modules', to_jsonb(v_before)),
      jsonb_build_object('modules', to_jsonb(v_after))
    );
  end if;

  return query select module from tenant_modules where tenant_id = p_tenant_id order by module;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Workflow threshold: audited
-- ---------------------------------------------------------------------
create or replace function public.update_workflow_stage_threshold(p_stage_id uuid, p_threshold_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stage workflow_stages%rowtype;
begin
  perform require_platform_admin('Editing workflow stage thresholds');

  if p_threshold_amount is null or p_threshold_amount < 0 then
    raise exception 'threshold_amount must be a non-negative number';
  end if;

  select * into v_stage
  from workflow_stages
  where id = p_stage_id;

  if not found then
    raise exception 'workflow stage not found';
  end if;

  if v_stage.threshold_amount is null then
    raise exception 'this stage has no threshold branch to edit';
  end if;

  if v_stage.threshold_amount = p_threshold_amount then
    return;
  end if;

  update workflow_stages
  set threshold_amount = p_threshold_amount
  where id = p_stage_id;

  perform log_platform_event(
    'workflow.threshold.update', v_stage.tenant_id, 'workflow_stage', p_stage_id::text, null,
    jsonb_build_object('stage_name', v_stage.name, 'threshold_amount', v_stage.threshold_amount),
    jsonb_build_object('stage_name', v_stage.name, 'threshold_amount', p_threshold_amount)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Invitation revoke: audit when the platform branch is taken
-- ---------------------------------------------------------------------
create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invitation invitations%rowtype;
  v_caller_is_platform_admin boolean;
  v_caller_tenant_id uuid;
begin
  select * into v_invitation
  from invitations
  where id = p_invitation_id;

  if not found then
    raise exception 'Invitation not found';
  end if;

  v_caller_is_platform_admin := is_platform_admin();
  v_caller_tenant_id := get_my_tenant_id();

  if not (
    v_caller_is_platform_admin
    or (
      v_invitation.role_bundle = 'member'
      and v_invitation.tenant_id = v_caller_tenant_id
      and exists (
        select 1 from staff_roles
        where user_id = auth.uid()
          and tenant_id = v_invitation.tenant_id
          and role = 'admin'
      )
    )
  ) then
    raise exception 'Not authorized to revoke this invitation';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Only pending invitations can be revoked (this one is %)', v_invitation.status;
  end if;

  update invitations set status = 'revoked' where id = p_invitation_id;

  -- Only platform-level revokes are platform events; a company admin
  -- revoking their own member invite is tenant business.
  if v_caller_is_platform_admin then
    perform log_platform_event(
      'invitation.revoke', v_invitation.tenant_id, 'invitation', p_invitation_id::text, null,
      jsonb_build_object('email', v_invitation.email, 'role_bundle', v_invitation.role_bundle, 'status', 'pending'),
      jsonb_build_object('status', 'revoked')
    );
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Platform settings: audit every save via trigger
-- ---------------------------------------------------------------------
create or replace function public.trg_audit_platform_settings()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform log_platform_event(
    'platform_settings.update', null, 'platform_settings', 'singleton', null,
    jsonb_build_object('branding', old.branding, 'notifications', old.notifications, 'security', old.security),
    jsonb_build_object('branding', new.branding, 'notifications', new.notifications, 'security', new.security)
  );
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end;
$$;

-- AdminSettingsPage does `.single()` on this table; on a fresh database the
-- singleton row doesn't exist until something inserts it. Make sure it does
-- so the page (and the trigger below) have a row to work with.
insert into public.platform_settings (id) values (true)
on conflict (id) do nothing;

drop trigger if exists platform_settings_audit on public.platform_settings;
create trigger platform_settings_audit
  before update on public.platform_settings
  for each row
  when (old.branding is distinct from new.branding
     or old.notifications is distinct from new.notifications
     or old.security is distinct from new.security)
  execute function public.trg_audit_platform_settings();

-- ---------------------------------------------------------------------
-- 10. Read RPCs for the audit screen
-- ---------------------------------------------------------------------
create or replace function public.list_platform_audit_events(
  p_tenant_id uuid    default null,
  p_actor_id  uuid    default null,
  p_action    text    default null,   -- exact match or prefix with trailing '%'
  p_from      timestamptz default null,
  p_to        timestamptz default null,
  p_limit     integer default 50,
  p_offset    integer default 0
)
returns table (
  id           uuid,
  created_at   timestamptz,
  actor_id     uuid,
  actor_email  text,
  tenant_id    uuid,
  tenant_name  text,
  action       text,
  target_type  text,
  target_id    text,
  reason       text,
  before       jsonb,
  after        jsonb,
  mfa_verified boolean,
  total_count  bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with filtered as (
    select e.*
    from platform_audit_events e
    where is_platform_admin()
      and (p_tenant_id is null or e.tenant_id = p_tenant_id)
      and (p_actor_id  is null or e.actor_id  = p_actor_id)
      and (p_action    is null or e.action like p_action)
      and (p_from      is null or e.created_at >= p_from)
      and (p_to        is null or e.created_at <  p_to)
  )
  select
    f.id, f.created_at, f.actor_id, f.actor_email, f.tenant_id, t.name,
    f.action, f.target_type, f.target_id, f.reason, f.before, f.after, f.mfa_verified,
    count(*) over () as total_count
  from filtered f
  left join tenants t on t.id = f.tenant_id
  order by f.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0));
$$;

revoke execute on function public.list_platform_audit_events(uuid, uuid, text, timestamptz, timestamptz, integer, integer) from public;
grant  execute on function public.list_platform_audit_events(uuid, uuid, text, timestamptz, timestamptz, integer, integer) to authenticated;

create or replace function public.list_impersonation_history(
  p_tenant_id uuid    default null,
  p_limit     integer default 50,
  p_offset    integer default 0
)
returns table (
  id                   uuid,
  platform_admin_id    uuid,
  platform_admin_email text,
  tenant_id            uuid,
  tenant_name          text,
  reason               text,
  started_at           timestamptz,
  ended_at             timestamptz,
  expires_at           timestamptz,
  is_active            boolean,
  total_count          bigint
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
    count(*) over () as total_count
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  left join auth.users u on u.id = s.platform_admin_id
  where is_platform_admin()
    and (p_tenant_id is null or s.tenant_id = p_tenant_id)
  order by s.started_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0));
$$;

revoke execute on function public.list_impersonation_history(uuid, integer, integer) from public;
grant  execute on function public.list_impersonation_history(uuid, integer, integer) to authenticated;
