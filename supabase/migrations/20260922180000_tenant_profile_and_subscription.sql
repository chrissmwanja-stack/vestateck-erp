-- Operator-console workstream, item 2: customer profile, subscription
-- status, read-only mode, seat limits, operator notes.
-- (see vestateck-erp-platform-admin-review.md §6, item 2)
--
-- Until now `tenants` was six columns: id, name, industry_template,
-- created_at, created_by, status. The platform admin -- the vendor's
-- operator over every customer company -- had nowhere to record who the
-- customer contact is, what plan they're on, how many seats they've paid
-- for, when their trial ends, or why they were suspended. Nor was there
-- anything between "fully active" and "locked out": a customer 60 days
-- past due either kept full access or was cut off entirely.
--
-- What this migration does (all additive -- no drops of columns/tables,
-- no renames):
--
--   * tenants gains customer-profile columns (contact_*, tax_id,
--     address, country), commercial columns (plan, subscription_status,
--     seat_limit, trial_ends_at, renews_at), lifecycle columns
--     (status_changed_at, read_only, read_only_reason, read_only_since)
--     and updated_at. Every one is nullable or defaulted so existing rows
--     and the create-tenant edge function keep working unchanged.
--
--   * tenant_notes                       -- operator-only timeline
--     ("called re unpaid invoice", "asked for HR module demo"). Lives in
--     its own table because tenants_select lets a customer read their own
--     tenant row; these notes must never be customer-visible.
--
--   * update_tenant_profile(uuid, jsonb) -- whitelisted-key patch, audited
--     with the before/after diff. jsonb rather than 15 positional args so
--     the signature is stable as fields grow.
--   * set_tenant_read_only(uuid, bool, text) -- reason required to turn
--     on; audited.
--   * add_tenant_note(uuid, text)        -- appends to tenant_notes.
--   * get_tenant_profile(uuid)           -- one round-trip summary for the
--     Company Detail screen: row + seat usage + activity + last status
--     event + recent audit events.
--   * get_my_tenant_access()             -- customer-side: status,
--     read_only(+reason), plan, trial_ends_at for the in-app banner.
--   * get_companies_overview()           -- recreated with the new
--     commercial columns appended (same leading columns, so existing
--     callers keep working).
--
--   * Read-only enforcement: tenant_read_only_guard() is a BEFORE
--     INSERT/UPDATE/DELETE row trigger attached to every table that has a
--     tenant_id column (except a short exempt list). It refuses writes
--     from ordinary authenticated users while tenants.read_only is true,
--     with TENANT_READ_ONLY: as the message prefix. Platform admins
--     (support via View-as), service_role (edge functions) and internal
--     sessions with no JWT (migrations, seeds, pg_cron) are exempt.
--     apply_tenant_read_only_guard() is kept as a function so a future
--     migration that adds tenant-scoped tables can re-run it.
--
--   * Seat enforcement: invitations_seat_limit_guard() is a BEFORE INSERT
--     trigger on invitations: when tenants.seat_limit is set, members +
--     pending invitations must stay under it (SEAT_LIMIT_REACHED: prefix).
--     The operator raises the limit from the console; nothing else
--     overrides it.
--
--   * set_tenant_status(uuid, text, text) now also stamps
--     status_changed_at (body otherwise unchanged from 20260922160000).
--
-- Rollback: none of this is destructive; a follow-up migration can drop
-- the triggers with drop trigger ... on <table> and leave the columns.

-- ---------------------------------------------------------------------
-- 1. tenants: profile, commercial, lifecycle columns
-- ---------------------------------------------------------------------
alter table public.tenants
  add column if not exists contact_name        text,
  add column if not exists contact_email       text,
  add column if not exists contact_phone       text,
  add column if not exists tax_id              text,      -- URA TIN or equivalent
  add column if not exists address             text,
  add column if not exists country             text not null default 'UG',
  add column if not exists plan                text not null default 'trial',
  add column if not exists subscription_status text not null default 'trialing',
  add column if not exists seat_limit          integer,
  add column if not exists trial_ends_at       timestamptz,
  add column if not exists renews_at           timestamptz,
  add column if not exists status_changed_at   timestamptz,
  add column if not exists read_only           boolean not null default false,
  add column if not exists read_only_reason    text,
  add column if not exists read_only_since     timestamptz,
  add column if not exists updated_at          timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'tenants_plan_check') then
    alter table public.tenants
      add constraint tenants_plan_check
      check (plan in ('trial', 'starter', 'standard', 'enterprise', 'internal'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tenants_subscription_status_check') then
    alter table public.tenants
      add constraint tenants_subscription_status_check
      check (subscription_status in ('trialing', 'active', 'past_due', 'cancelled'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tenants_seat_limit_check') then
    alter table public.tenants
      add constraint tenants_seat_limit_check
      check (seat_limit is null or seat_limit > 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tenants_read_only_reason_check') then
    alter table public.tenants
      add constraint tenants_read_only_reason_check
      check (not read_only or read_only_reason is not null);
  end if;
end $$;

comment on column public.tenants.plan is
  'Commercial plan as recorded by the platform operator. ''internal'' is for the platform-admin home tenant only.';
comment on column public.tenants.subscription_status is
  'trialing | active | past_due | cancelled. Informational -- the operator decides whether to set read_only or suspend.';
comment on column public.tenants.seat_limit is
  'Max members + pending invitations. NULL = unlimited. Enforced by invitations_seat_limit_guard().';
comment on column public.tenants.read_only is
  'When true, ordinary users of this tenant can read but not write (tenant_read_only_guard()). Platform admins and edge functions are exempt.';

-- The reserved platform-admin home tenant is not a customer.
update public.tenants
set plan = 'internal', subscription_status = 'active'
where id = '00000000-0000-0000-0000-000000000099'
  and plan = 'trial';

-- Keep updated_at honest. touch_updated_at() already exists in this
-- schema (used by several tables); reuse it.
drop trigger if exists tenants_touch_updated_at on public.tenants;
create trigger tenants_touch_updated_at
  before update on public.tenants
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 2. tenant_notes: operator-only timeline
-- ---------------------------------------------------------------------
create table if not exists public.tenant_notes (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  author_id    uuid,
  author_email text,
  body         text not null check (length(btrim(body)) between 1 and 4000),
  created_at   timestamptz not null default now()
);

comment on table public.tenant_notes is
  'Platform-operator notes about a customer company (account history, calls, commitments). Never visible to the customer; written only via add_tenant_note().';

create index if not exists tenant_notes_tenant_created_idx
  on public.tenant_notes (tenant_id, created_at desc);

alter table public.tenant_notes enable row level security;

drop policy if exists tenant_notes_select_platform_admin on public.tenant_notes;
create policy tenant_notes_select_platform_admin
  on public.tenant_notes
  for select
  using (public.is_platform_admin());
-- No INSERT/UPDATE/DELETE policies: rows arrive via add_tenant_note()
-- (SECURITY DEFINER) and are immutable from the client.

revoke all on table public.tenant_notes from anon;

-- ---------------------------------------------------------------------
-- 3. Request-role helper (shared by both guards)
-- ---------------------------------------------------------------------
-- Returns the JWT role claim ('authenticated', 'service_role', 'anon') or
-- NULL when there is no JWT at all (psql, migrations, seeds, pg_cron).
create or replace function public.platform_request_role()
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
$$;

revoke execute on function public.platform_request_role() from public;

-- ---------------------------------------------------------------------
-- 4. Read-only guard
-- ---------------------------------------------------------------------
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
  -- Only ordinary end-user sessions are subject to read-only mode.
  if coalesce(platform_request_role(), '') <> 'authenticated' then
    return coalesce(new, old);
  end if;
  if is_platform_admin() then
    return coalesce(new, old);
  end if;

  -- Several tables have a BEFORE INSERT trigger that fills tenant_id from
  -- get_my_tenant_id() *after* this one fires (alphabetical order), so a
  -- null tenant_id here means "the caller's own tenant", not "unknown".
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

revoke execute on function public.tenant_read_only_guard() from public;

-- Attach the guard to every tenant-scoped table. Kept as a callable
-- function so later migrations that add tenant-scoped tables can simply
-- `select public.apply_tenant_read_only_guard();` again -- it is
-- idempotent.
create or replace function public.apply_tenant_read_only_guard()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r        record;
  v_count  integer := 0;
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname not in (
        -- platform-side / operator tables: never customer writes
        'platform_audit_events', 'impersonation_sessions', 'impersonation_logs', 'tenant_notes',
        -- a read-only user must still be able to mark notifications read
        'notifications',
        -- created by edge functions (service_role) -- exempt anyway, listed for clarity
        'invitations', 'app_users'
      )
  loop
    execute format('drop trigger if exists tenant_read_only_guard on public.%I', r.relname);
    execute format(
      'create trigger tenant_read_only_guard before insert or update or delete on public.%I '
      'for each row execute function public.tenant_read_only_guard()',
      r.relname
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.apply_tenant_read_only_guard() from public;

select public.apply_tenant_read_only_guard();

-- ---------------------------------------------------------------------
-- 5. Seat-limit guard on invitations
-- ---------------------------------------------------------------------
create or replace function public.invitations_seat_limit_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit   integer;
  v_used    integer;
begin
  select seat_limit into v_limit from tenants where id = new.tenant_id;
  if v_limit is null then
    return new;
  end if;

  select
    (select count(*) from app_users   u where u.tenant_id = new.tenant_id)
  + (select count(*) from invitations i where i.tenant_id = new.tenant_id and i.status = 'pending')
  into v_used;

  if v_used >= v_limit then
    raise exception 'SEAT_LIMIT_REACHED: this company has used all % of its seats (members + pending invitations). Raise the seat limit in the platform console before inviting more people.',
      v_limit
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

revoke execute on function public.invitations_seat_limit_guard() from public;

drop trigger if exists invitations_seat_limit_guard on public.invitations;
create trigger invitations_seat_limit_guard
  before insert on public.invitations
  for each row execute function public.invitations_seat_limit_guard();

-- ---------------------------------------------------------------------
-- 6. set_tenant_status: also stamp status_changed_at
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
  set status = p_status,
      status_changed_at = now()
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

-- ---------------------------------------------------------------------
-- 7. update_tenant_profile(uuid, jsonb)
-- ---------------------------------------------------------------------
create or replace function public.update_tenant_profile(p_tenant_id uuid, p_patch jsonb)
returns public.tenants
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before  public.tenants;
  v_row     public.tenants;
  v_allowed text[] := array[
    'name', 'contact_name', 'contact_email', 'contact_phone', 'tax_id', 'address', 'country',
    'plan', 'subscription_status', 'seat_limit', 'trial_ends_at', 'renews_at'
  ];
  v_key     text;
  v_diff_before jsonb := '{}'::jsonb;
  v_diff_after  jsonb := '{}'::jsonb;
  v_before_json jsonb;
  v_after_json  jsonb;
begin
  perform require_platform_admin('Editing a company''s profile');

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'p_patch must be a JSON object';
  end if;

  for v_key in select jsonb_object_keys(p_patch) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'Field "%" cannot be edited through update_tenant_profile', v_key;
    end if;
  end loop;

  select * into v_before from tenants where id = p_tenant_id for update;
  if not found then
    raise exception 'tenant not found';
  end if;

  if p_patch ? 'name' and length(btrim(coalesce(p_patch->>'name', ''))) = 0 then
    raise exception 'Company name cannot be blank';
  end if;
  if p_patch ? 'contact_email'
     and nullif(btrim(p_patch->>'contact_email'), '') is not null
     and (p_patch->>'contact_email') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'contact_email does not look like an email address';
  end if;

  update tenants t
  set
    name                = case when p_patch ? 'name'                then btrim(p_patch->>'name')                 else t.name end,
    contact_name        = case when p_patch ? 'contact_name'        then nullif(btrim(p_patch->>'contact_name'), '')  else t.contact_name end,
    contact_email       = case when p_patch ? 'contact_email'       then lower(nullif(btrim(p_patch->>'contact_email'), '')) else t.contact_email end,
    contact_phone       = case when p_patch ? 'contact_phone'       then nullif(btrim(p_patch->>'contact_phone'), '') else t.contact_phone end,
    tax_id              = case when p_patch ? 'tax_id'              then nullif(btrim(p_patch->>'tax_id'), '')        else t.tax_id end,
    address             = case when p_patch ? 'address'             then nullif(btrim(p_patch->>'address'), '')       else t.address end,
    country             = case when p_patch ? 'country'             then coalesce(nullif(upper(btrim(p_patch->>'country')), ''), 'UG') else t.country end,
    plan                = case when p_patch ? 'plan'                then p_patch->>'plan'                        else t.plan end,
    subscription_status = case when p_patch ? 'subscription_status' then p_patch->>'subscription_status'         else t.subscription_status end,
    seat_limit          = case when p_patch ? 'seat_limit'          then nullif(p_patch->>'seat_limit', '')::integer else t.seat_limit end,
    trial_ends_at       = case when p_patch ? 'trial_ends_at'       then nullif(p_patch->>'trial_ends_at', '')::timestamptz else t.trial_ends_at end,
    renews_at           = case when p_patch ? 'renews_at'           then nullif(p_patch->>'renews_at', '')::timestamptz else t.renews_at end
  where t.id = p_tenant_id
  returning * into v_row;

  -- Audit only the keys that actually changed.
  v_before_json := to_jsonb(v_before);
  v_after_json  := to_jsonb(v_row);
  for v_key in select jsonb_object_keys(p_patch) loop
    if v_before_json -> v_key is distinct from v_after_json -> v_key then
      v_diff_before := v_diff_before || jsonb_build_object(v_key, v_before_json -> v_key);
      v_diff_after  := v_diff_after  || jsonb_build_object(v_key, v_after_json  -> v_key);
    end if;
  end loop;

  if v_diff_after <> '{}'::jsonb then
    perform log_platform_event(
      'tenant.profile.update', p_tenant_id, 'tenant', p_tenant_id::text, null,
      v_diff_before, v_diff_after || jsonb_build_object('tenant_name', v_row.name)
    );
  end if;

  return v_row;
end;
$$;

revoke execute on function public.update_tenant_profile(uuid, jsonb) from public;
grant  execute on function public.update_tenant_profile(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 8. set_tenant_read_only(uuid, bool, text)
-- ---------------------------------------------------------------------
create or replace function public.set_tenant_read_only(p_tenant_id uuid, p_read_only boolean, p_reason text default null)
returns public.tenants
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before public.tenants;
  v_row    public.tenants;
  v_reason text := nullif(btrim(p_reason), '');
begin
  perform require_platform_admin('Changing a company''s read-only mode');

  select * into v_before from tenants where id = p_tenant_id for update;
  if not found then
    raise exception 'tenant not found';
  end if;

  if p_read_only and v_reason is null then
    raise exception 'A reason is required to put a company into read-only mode';
  end if;

  if v_before.read_only = p_read_only then
    return v_before;
  end if;

  update tenants
  set read_only        = p_read_only,
      read_only_reason = case when p_read_only then v_reason else null end,
      read_only_since  = case when p_read_only then now() else null end
  where id = p_tenant_id
  returning * into v_row;

  perform log_platform_event(
    case when p_read_only then 'tenant.read_only.on' else 'tenant.read_only.off' end,
    p_tenant_id, 'tenant', p_tenant_id::text, v_reason,
    jsonb_build_object('read_only', v_before.read_only, 'read_only_reason', v_before.read_only_reason),
    jsonb_build_object('read_only', v_row.read_only, 'read_only_reason', v_row.read_only_reason, 'tenant_name', v_row.name)
  );

  return v_row;
end;
$$;

revoke execute on function public.set_tenant_read_only(uuid, boolean, text) from public;
grant  execute on function public.set_tenant_read_only(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- 9. add_tenant_note(uuid, text)
-- ---------------------------------------------------------------------
create or replace function public.add_tenant_note(p_tenant_id uuid, p_body text)
returns public.tenant_notes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.tenant_notes;
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: Only platform admins can add company notes';
  end if;
  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;
  if length(btrim(coalesce(p_body, ''))) = 0 then
    raise exception 'Note cannot be blank';
  end if;

  insert into tenant_notes (tenant_id, author_id, author_email, body)
  values (
    p_tenant_id,
    auth.uid(),
    (select email from auth.users where id = auth.uid()),
    btrim(p_body)
  )
  returning * into v_row;
  return v_row;
end;
$$;

revoke execute on function public.add_tenant_note(uuid, text) from public;
grant  execute on function public.add_tenant_note(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 10. get_tenant_profile(uuid): one round-trip for Company Detail
-- ---------------------------------------------------------------------
create or replace function public.get_tenant_profile(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant tenants;
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: Only platform admins can view company profiles';
  end if;

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    return null;
  end if;

  select jsonb_build_object(
    'tenant', to_jsonb(v_tenant),
    'seats', jsonb_build_object(
      'limit',           v_tenant.seat_limit,
      'members',         (select count(*) from app_users u where u.tenant_id = p_tenant_id),
      'pending_invites', (select count(*) from invitations i where i.tenant_id = p_tenant_id and i.status = 'pending')
    ),
    'activity', jsonb_build_object(
      'modules',          (select count(*) from tenant_modules tm where tm.tenant_id = p_tenant_id),
      'requests_30d',     (select count(*) from requests r where r.tenant_id = p_tenant_id and r.created_at >= now() - interval '30 days'),
      'last_request_at',  (select max(r.created_at) from requests r where r.tenant_id = p_tenant_id),
      'last_sign_in_at',  (select max(au.last_sign_in_at)
                           from app_users u join auth.users au on au.id = u.id
                           where u.tenant_id = p_tenant_id),
      'company_admins',   (select coalesce(jsonb_agg(jsonb_build_object('name', u.name, 'email', u.email) order by u.name), '[]'::jsonb)
                           from app_users u where u.tenant_id = p_tenant_id and u.is_company_admin)
    ),
    'last_status_event', (
      select to_jsonb(e) from (
        select action, reason, created_at, actor_email
        from platform_audit_events
        where tenant_id = p_tenant_id
          and action in ('tenant.suspend', 'tenant.activate', 'tenant.read_only.on', 'tenant.read_only.off')
        order by created_at desc
        limit 1
      ) e
    ),
    'recent_events', (
      select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc), '[]'::jsonb) from (
        select id, action, reason, created_at, actor_email, mfa_verified
        from platform_audit_events
        where tenant_id = p_tenant_id
        order by created_at desc
        limit 8
      ) e
    ),
    'notes_count', (select count(*) from tenant_notes n where n.tenant_id = p_tenant_id)
  )
  into v_result;

  return v_result;
end;
$$;

revoke execute on function public.get_tenant_profile(uuid) from public;
grant  execute on function public.get_tenant_profile(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 11. get_my_tenant_access(): customer-side banner data
-- ---------------------------------------------------------------------
-- Uses get_my_tenant_id() so an impersonating platform admin sees exactly
-- what the customer sees. Returns NULL for users with no tenant (e.g. a
-- suspended tenant's users -- RequireAuth already handles that case via
-- get_my_tenant_status()).
create or replace function public.get_my_tenant_access()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'tenant_id',           t.id,
    'name',                t.name,
    'status',              t.status,
    'read_only',           t.read_only,
    'read_only_reason',    t.read_only_reason,
    'plan',                t.plan,
    'subscription_status', t.subscription_status,
    'trial_ends_at',       t.trial_ends_at
  )
  from tenants t
  where t.id = get_my_tenant_id();
$$;

revoke execute on function public.get_my_tenant_access() from public;
grant  execute on function public.get_my_tenant_access() to authenticated;

-- ---------------------------------------------------------------------
-- 12. get_companies_overview(): append commercial columns
-- ---------------------------------------------------------------------
-- Return type changes require drop + create (CREATE OR REPLACE cannot
-- change OUT columns). Existing columns keep their order, so the
-- dashboard's fallback path and the Companies console keep working.
drop function if exists public.get_companies_overview();
create function public.get_companies_overview()
returns table (
  tenant_id             uuid,
  name                  text,
  status                text,
  created_at            timestamptz,
  member_count          bigint,
  module_count          bigint,
  request_count_30d     bigint,
  pending_request_count bigint,
  plan                  text,
  subscription_status   text,
  seat_limit            integer,
  trial_ends_at         timestamptz,
  read_only             boolean,
  contact_email         text,
  last_activity_at      timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    t.id,
    t.name,
    t.status,
    t.created_at,
    (select count(*) from app_users u where u.tenant_id = t.id),
    (select count(*) from tenant_modules tm where tm.tenant_id = t.id),
    (select count(*) from requests r where r.tenant_id = t.id and r.created_at >= now() - interval '30 days'),
    (select count(*) from requests r where r.tenant_id = t.id and r.status = 'pending'),
    t.plan,
    t.subscription_status,
    t.seat_limit,
    t.trial_ends_at,
    t.read_only,
    t.contact_email,
    greatest(
      (select max(r.created_at) from requests r where r.tenant_id = t.id),
      (select max(au.last_sign_in_at) from app_users u join auth.users au on au.id = u.id where u.tenant_id = t.id)
    )
  from tenants t
  where is_platform_admin()
  order by t.created_at desc;
$$;

revoke all on function public.get_companies_overview() from public;
grant execute on function public.get_companies_overview() to authenticated;
grant execute on function public.get_companies_overview() to service_role;
