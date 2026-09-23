-- Item 7 of the operator-console build order: the scale tooling.
--
--  A. Industry templates as data. `industry_templates` + `industry_template_items`
--     replace the two hard-coded branches in seed_tenant_defaults() and the
--     matching enum in create-tenant / CompanyCreateWizard. Onboarding a new
--     vertical is now an insert, not a deploy. seed_tenant_defaults() keeps
--     its signature and behaviour for 'general' / 'construction' (the same
--     rows are seeded from the same data) and now accepts any active
--     template key. apply_workflow_template() copies a template's stages
--     onto an existing tenant that has no open items in flight.
--
--  B. Announcements. `platform_announcements` (severity, all-companies or
--     one company, schedule window, dismissible). get_active_announcements()
--     is what every signed-in user's banner reads; dismissals are per user.
--
--  C. Feature flags. `platform_feature_flags` (key, default) +
--     `tenant_feature_flags` (override per company). feature_enabled(key)
--     resolves for the current (or impersonated) tenant and is usable from
--     RLS, RPCs and the client (get_my_feature_flags()). Independent of
--     module entitlement: a flag can gate a behaviour inside a module.
--
--  D. Health. `platform_job_runs` records every run of the "cronless cron"
--     sweeps (which now log themselves), the digest job and anything else
--     that should be watched. get_platform_health() folds that together with
--     migration version, cron job state, stuck approvals per company,
--     pending invites older than a week, storage footprint and failed
--     digest deliveries into one document for /admin/health.
--
-- Additive: no drops, no column changes. Passes scripts/check-migration-policy.sh.


-- =====================================================================
-- A. Industry templates as data
-- =====================================================================
create table if not exists public.industry_templates (
  key          text primary key,
  name         text not null,
  description  text,
  is_active    boolean not null default true,
  is_default   boolean not null default false,
  sort_order   integer not null default 100,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint industry_templates_key_check check (key ~ '^[a-z][a-z0-9_]{1,39}$')
);

-- Exactly one default at a time.
create unique index if not exists industry_templates_one_default on public.industry_templates ((true)) where is_default;

create table if not exists public.industry_template_items (
  id            uuid primary key default gen_random_uuid(),
  template_key  text not null references public.industry_templates(key) on delete cascade,
  kind          text not null,                         -- 'department' | 'module' | 'workflow_stage'
  sort_order    integer not null default 0,
  name          text not null,                         -- department name / module key / stage name
  payload       jsonb not null default '{}'::jsonb,    -- stage: approver_role, threshold_amount, next_low, next_high (by sort_order), flags
  constraint industry_template_items_kind_check check (kind in ('department', 'module', 'workflow_stage')),
  constraint industry_template_items_unique unique (template_key, kind, name)
);

create index if not exists idx_industry_template_items_key on public.industry_template_items (template_key, kind, sort_order);

alter table public.industry_templates enable row level security;
alter table public.industry_template_items enable row level security;

drop policy if exists industry_templates_select_admin on public.industry_templates;
create policy industry_templates_select_admin on public.industry_templates for select using (is_platform_admin());
drop policy if exists industry_template_items_select_admin on public.industry_template_items;
create policy industry_template_items_select_admin on public.industry_template_items for select using (is_platform_admin());
-- Writes only through RPCs below.

comment on table public.industry_templates is
  'Operator-console onboarding presets. seed_tenant_defaults(tenant, key) materialises one of these into departments / tenant_modules / workflow_stages for a new company.';

-- Seed the two presets that used to be hard-coded, byte-for-byte the same
-- departments, modules and 7-stage pipeline (low/high routing by sort
-- order; the 5,000,000 threshold on stage 4).
insert into public.industry_templates (key, name, description, is_default, sort_order) values
  ('general', 'General', '8 departments: Cost Control, Procurement & Logistics, Finance, PMO, IT, HR, Law & Compliance, BD. Modules: HR, Law, BD, IT, PMO, Purchasing+.', true, 10),
  ('construction', 'Construction', 'General + Machine Operations and Sustainability & Business Excellence departments and modules (10 departments).', false, 20)
on conflict (key) do nothing;

insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select t.key, 'department', d.ord, d.name, '{}'::jsonb
from public.industry_templates t
cross join (values
  (1, 'Cost Control'), (2, 'Procurement & Logistics'), (3, 'Finance & Financial Reporting'),
  (4, 'Project Management Office'), (5, 'IT Support'), (6, 'Human Resources'),
  (7, 'Law & Compliance'), (8, 'Business Development')
) as d(ord, name)
where t.key in ('general', 'construction')
on conflict do nothing;

insert into public.industry_template_items (template_key, kind, sort_order, name, payload) values
  ('construction', 'department', 9,  'Machine Operations', '{}'),
  ('construction', 'department', 10, 'Sustainability & Business Excellence', '{}')
on conflict do nothing;

insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select t.key, 'module', m.ord, m.name, '{}'::jsonb
from public.industry_templates t
cross join (values (1, 'hr'), (2, 'legal'), (3, 'bd'), (4, 'it'), (5, 'pmo'), (6, 'procurement')) as m(ord, name)
where t.key in ('general', 'construction')
on conflict do nothing;

insert into public.industry_template_items (template_key, kind, sort_order, name, payload) values
  ('construction', 'module', 7, 'machine_operation', '{}'),
  ('construction', 'module', 8, 'sustainability', '{}')
on conflict do nothing;

-- Workflow stages. next_low / next_high reference the sort_order of the
-- target stage within the same template.
insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select t.key, 'workflow_stage', s.ord, s.name, s.payload
from public.industry_templates t
cross join (values
  (1, 'Cost Control Engineer',     '{"approver_role":"Cost Control Engineer","next_low":2}'::jsonb),
  (2, 'Cost Control Manager',      '{"approver_role":"Cost Control Manager","next_low":3}'::jsonb),
  (3, 'Procurement: Offer Entry',  '{"approver_role":"Procurement/Logistics Expert","next_low":4}'::jsonb),
  (4, 'Control Chief/Manager',     '{"approver_role":"Procurement & Logistics Chief","threshold_amount":5000000,"next_low":5,"next_high":6}'::jsonb),
  (5, 'Finance',                   '{"approver_role":"Finance Officer"}'::jsonb),
  (6, 'Project Manager',           '{"approver_role":"Project Manager","next_low":7}'::jsonb),
  (7, 'Deputy General Manager',    '{"approver_role":"Deputy General Manager","next_low":5}'::jsonb)
) as s(ord, name, payload)
where t.key in ('general', 'construction')
on conflict do nothing;

-- A1. Read for the wizard / template screen. Platform admin only.
create or replace function public.list_industry_templates(p_include_inactive boolean default false)
returns table (
  key              text,
  name             text,
  description      text,
  is_active        boolean,
  is_default       boolean,
  sort_order       integer,
  updated_at       timestamptz,
  department_count integer,
  module_count     integer,
  stage_count      integer,
  tenants_using    bigint,
  items            jsonb
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    t.key, t.name, t.description, t.is_active, t.is_default, t.sort_order, t.updated_at,
    (select count(*) from industry_template_items i where i.template_key = t.key and i.kind = 'department')::integer,
    (select count(*) from industry_template_items i where i.template_key = t.key and i.kind = 'module')::integer,
    (select count(*) from industry_template_items i where i.template_key = t.key and i.kind = 'workflow_stage')::integer,
    (select count(*) from tenants x where x.industry_template = t.key),
    (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'sort_order', i.sort_order, 'name', i.name, 'payload', i.payload)
                                order by i.kind, i.sort_order), '[]'::jsonb)
       from industry_template_items i where i.template_key = t.key)
  from industry_templates t
  where is_platform_admin()
    and (p_include_inactive or t.is_active)
  order by t.sort_order, t.name;
$$;

revoke all on function public.list_industry_templates(boolean) from public;
grant execute on function public.list_industry_templates(boolean) to authenticated;

-- A2. Save (create or replace) a template with its items in one call.
--     p_items: [{kind, sort_order, name, payload}] -- replaces all items.
create or replace function public.save_industry_template(
  p_key         text,
  p_name        text,
  p_description text,
  p_items       jsonb,
  p_is_active   boolean default true,
  p_sort_order  integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before jsonb;
  v_item   jsonb;
  v_kinds  text[] := array['department', 'module', 'workflow_stage'];
  v_orders integer[];
begin
  perform require_platform_admin('Editing industry templates');

  if p_key !~ '^[a-z][a-z0-9_]{1,39}$' then
    raise exception 'TEMPLATE_KEY_INVALID: key must be 2-40 chars, lowercase letters, digits or underscores, starting with a letter';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'TEMPLATE_NAME_REQUIRED: a template needs a name';
  end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'TEMPLATE_ITEMS_INVALID: items must be an array';
  end if;

  -- Validate items.
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if not (v_item ->> 'kind') = any (v_kinds) then
      raise exception 'TEMPLATE_ITEMS_INVALID: unknown kind %', v_item ->> 'kind';
    end if;
    if coalesce(btrim(v_item ->> 'name'), '') = '' then
      raise exception 'TEMPLATE_ITEMS_INVALID: every item needs a name';
    end if;
    if (v_item ->> 'kind') = 'module' and not (v_item ->> 'name') = any (array['hr','legal','bd','it','pmo','procurement','machine_operation','sustainability']) then
      raise exception 'TEMPLATE_ITEMS_INVALID: unknown module %', v_item ->> 'name';
    end if;
    if (v_item ->> 'kind') = 'workflow_stage' and coalesce(btrim(v_item -> 'payload' ->> 'approver_role'), '') = '' then
      raise exception 'TEMPLATE_ITEMS_INVALID: stage "%" needs an approver_role', v_item ->> 'name';
    end if;
  end loop;

  -- Stage routing must point at stages that exist in this template.
  select array_agg((i ->> 'sort_order')::integer) into v_orders
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i where i ->> 'kind' = 'workflow_stage';
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i where i ->> 'kind' = 'workflow_stage' loop
    if (v_item -> 'payload' ->> 'next_low') is not null and not ((v_item -> 'payload' ->> 'next_low')::integer = any (v_orders)) then
      raise exception 'TEMPLATE_ITEMS_INVALID: stage "%" routes (low) to a stage that does not exist', v_item ->> 'name';
    end if;
    if (v_item -> 'payload' ->> 'next_high') is not null and not ((v_item -> 'payload' ->> 'next_high')::integer = any (v_orders)) then
      raise exception 'TEMPLATE_ITEMS_INVALID: stage "%" routes (high) to a stage that does not exist', v_item ->> 'name';
    end if;
  end loop;

  select to_jsonb(t) || jsonb_build_object('items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.kind, i.sort_order), '[]'::jsonb) from industry_template_items i where i.template_key = t.key))
    into v_before from industry_templates t where t.key = p_key;

  insert into industry_templates (key, name, description, is_active, sort_order, updated_by)
  values (p_key, btrim(p_name), nullif(btrim(p_description), ''), coalesce(p_is_active, true), coalesce(p_sort_order, 100), auth.uid())
  on conflict (key) do update
    set name = excluded.name, description = excluded.description, is_active = excluded.is_active,
        sort_order = excluded.sort_order, updated_at = now(), updated_by = auth.uid();

  delete from industry_template_items where template_key = p_key;
  insert into industry_template_items (template_key, kind, sort_order, name, payload)
  select p_key, i ->> 'kind', coalesce((i ->> 'sort_order')::integer, rn::integer), btrim(i ->> 'name'), coalesce(i -> 'payload', '{}'::jsonb)
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality as x(i, rn);

  perform log_platform_event(
    case when v_before is null then 'industry_template.create' else 'industry_template.update' end,
    null, 'industry_template', p_key, null, v_before,
    (select to_jsonb(t) || jsonb_build_object('items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.kind, i.sort_order), '[]'::jsonb) from industry_template_items i where i.template_key = t.key))
       from industry_templates t where t.key = p_key)
  );

  return (select to_jsonb(r) from list_industry_templates(true) r where r.key = p_key);
end;
$$;

revoke all on function public.save_industry_template(text, text, text, jsonb, boolean, integer) from public;
grant execute on function public.save_industry_template(text, text, text, jsonb, boolean, integer) to authenticated;

-- A3. Make a template the default for the wizard.
create or replace function public.set_default_industry_template(p_key text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform require_platform_admin('Changing the default template');
  if not exists (select 1 from industry_templates where key = p_key and is_active) then
    raise exception 'TEMPLATE_NOT_FOUND: no active template %', p_key;
  end if;
  update industry_templates set is_default = false where is_default and key <> p_key;
  update industry_templates set is_default = true, updated_at = now(), updated_by = auth.uid() where key = p_key;
  perform log_platform_event('industry_template.set_default', null, 'industry_template', p_key, null, null, null);
end;
$$;

revoke all on function public.set_default_industry_template(text) from public;
grant execute on function public.set_default_industry_template(text) to authenticated;

-- A4. Retire a template. Keys referenced by tenants.industry_template
--     cannot be deleted (history) -- deactivate instead.
create or replace function public.delete_industry_template(p_key text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_before jsonb;
begin
  perform require_platform_admin('Deleting an industry template');
  if exists (select 1 from tenants where industry_template = p_key) then
    raise exception 'TEMPLATE_IN_USE: companies were created from this template - deactivate it instead of deleting';
  end if;
  if exists (select 1 from industry_templates where key = p_key and is_default) then
    raise exception 'TEMPLATE_IS_DEFAULT: choose another default first';
  end if;
  select to_jsonb(t) into v_before from industry_templates t where t.key = p_key;
  if v_before is null then return; end if;
  delete from industry_templates where key = p_key;
  perform log_platform_event('industry_template.delete', null, 'industry_template', p_key, null, v_before, null);
end;
$$;

revoke all on function public.delete_industry_template(text) from public;
grant execute on function public.delete_industry_template(text) to authenticated;

-- A5. Materialise a template's workflow stages onto a tenant. Internal.
create or replace function public.platform_seed_workflow_from_template(p_tenant_id uuid, p_template_key text, p_applies_to text default 'requests')
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item record;
  v_ids  jsonb := '{}'::jsonb;   -- sort_order -> stage id
  v_id   uuid;
  v_n    integer := 0;
begin
  for v_item in
    select i.sort_order, i.name, i.payload
    from industry_template_items i
    where i.template_key = p_template_key and i.kind = 'workflow_stage'
    order by i.sort_order
  loop
    insert into workflow_stages (
      tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to,
      requires_offer_entry, blocks_offer_submitter_approval, is_finance_terminal_stage, requires_offer_selection
    )
    values (
      p_tenant_id, v_item.name, v_item.sort_order, v_item.payload ->> 'approver_role',
      nullif(v_item.payload ->> 'threshold_amount', '')::numeric, p_applies_to,
      coalesce((v_item.payload ->> 'requires_offer_entry')::boolean, false),
      coalesce((v_item.payload ->> 'blocks_offer_submitter_approval')::boolean, false),
      coalesce((v_item.payload ->> 'is_finance_terminal_stage')::boolean, false),
      coalesce((v_item.payload ->> 'requires_offer_selection')::boolean, false)
    )
    returning id into v_id;
    v_ids := v_ids || jsonb_build_object(v_item.sort_order::text, v_id);
    v_n := v_n + 1;
  end loop;

  -- Second pass: routing.
  for v_item in
    select i.sort_order, i.payload
    from industry_template_items i
    where i.template_key = p_template_key and i.kind = 'workflow_stage'
  loop
    update workflow_stages
       set next_stage_low_id  = (v_ids ->> (v_item.payload ->> 'next_low'))::uuid,
           next_stage_high_id = (v_ids ->> (v_item.payload ->> 'next_high'))::uuid
     where id = (v_ids ->> v_item.sort_order::text)::uuid;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.platform_seed_workflow_from_template(uuid, text, text) from public, authenticated, anon;

-- A6a. Pre-existing bug, surfaced by the test for A6: the BEFORE INSERT
--      trigger on departments unconditionally replaced tenant_id with
--      get_my_tenant_id() -- so seed_tenant_defaults(), called by the
--      platform admin from the wizard, wrote the new company's departments
--      into the admin's own home tenant. Honour an explicit tenant_id when
--      the caller is a platform admin operating as themselves; everyone
--      else (including View-as sessions) keeps the old behaviour.
create or replace function public.set_department_defaults()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if NEW.tenant_id is null or not platform_admin_bypass() then
    NEW.tenant_id := get_my_tenant_id();
  end if;
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;

-- A6. seed_tenant_defaults(): same signature, now data-driven. Idempotent
--     as before (no-op if the tenant already has departments or stages).
create or replace function public.seed_tenant_defaults(p_tenant_id uuid, p_industry_template text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text := coalesce(nullif(btrim(p_industry_template), ''), (select key from industry_templates where is_default), 'general');
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can seed tenant defaults';
  end if;

  if not exists (select 1 from industry_templates where key = v_key and is_active) then
    raise exception 'TEMPLATE_NOT_FOUND: no active industry template "%"', v_key;
  end if;

  if exists (select 1 from departments where tenant_id = p_tenant_id)
     or exists (select 1 from workflow_stages where tenant_id = p_tenant_id) then
    return;
  end if;

  insert into departments (tenant_id, name)
  select p_tenant_id, i.name
  from industry_template_items i
  where i.template_key = v_key and i.kind = 'department'
  order by i.sort_order;

  perform platform_seed_workflow_from_template(p_tenant_id, v_key, 'requests');

  insert into tenant_modules (tenant_id, module, enabled_by)
  select p_tenant_id, i.name, auth.uid()
  from industry_template_items i
  where i.template_key = v_key and i.kind = 'module'
  order by i.sort_order
  on conflict do nothing;

  -- Keep tenants.industry_template honest even when the caller passed a
  -- blank (the wizard always passes one; direct callers may not).
  update tenants set industry_template = v_key where id = p_tenant_id and industry_template is distinct from v_key;
end;
$$;

-- A7. Apply a template's workflow to an existing company (Company Detail ->
--     Approval thresholds -> "Apply template"). Refuses while anything is
--     mid-pipeline, because open items point at current stage ids.
create or replace function public.apply_workflow_template(p_tenant_id uuid, p_template_key text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_open   integer;
  v_before jsonb;
  v_n      integer;
begin
  perform require_platform_admin('Applying a workflow template');
  if coalesce(length(btrim(p_reason)), 0) < 5 then
    raise exception 'REASON_REQUIRED: give a reason (at least 5 characters) - it goes in the audit log';
  end if;
  if not exists (select 1 from industry_templates where key = p_template_key and is_active) then
    raise exception 'TEMPLATE_NOT_FOUND: no active template %', p_template_key;
  end if;

  select count(*) into v_open
  from requests r
  where r.tenant_id = p_tenant_id and r.status = 'open' and r.current_stage_id is not null;
  if v_open > 0 then
    raise exception 'WORKFLOW_IN_USE: % open request(s) are mid-approval - wait for them to finish or cancel them first', v_open;
  end if;

  select coalesce(jsonb_agg(to_jsonb(s) order by s.sequence_order), '[]'::jsonb) into v_before
  from workflow_stages s where s.tenant_id = p_tenant_id and s.applies_to = 'requests';

  -- Retire the old pipeline rather than deleting: history rows
  -- (approvals, request_stage_events) still reference the ids.
  update workflow_stages set is_active = false where tenant_id = p_tenant_id and applies_to = 'requests' and is_active;
  v_n := platform_seed_workflow_from_template(p_tenant_id, p_template_key, 'requests');

  perform log_platform_event('tenant.workflow.apply_template', p_tenant_id, 'tenant', p_tenant_id::text, p_reason,
    jsonb_build_object('stages', v_before),
    jsonb_build_object('template', p_template_key, 'stages_created', v_n));

  return jsonb_build_object('stages_created', v_n, 'stages_retired', jsonb_array_length(v_before));
end;
$$;

revoke all on function public.apply_workflow_template(uuid, text, text) from public;
grant execute on function public.apply_workflow_template(uuid, text, text) to authenticated;


-- =====================================================================
-- B. Announcements
-- =====================================================================
create table if not exists public.platform_announcements (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  body          text not null,
  severity      text not null default 'info',          -- info | warning | critical
  tenant_id     uuid references public.tenants(id) on delete cascade,  -- null = every company
  starts_at     timestamptz not null default now(),
  ends_at       timestamptz,
  dismissible   boolean not null default true,
  link_url      text,
  link_label    text,
  is_active     boolean not null default true,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint platform_announcements_severity_check check (severity in ('info', 'warning', 'critical')),
  constraint platform_announcements_window_check check (ends_at is null or ends_at > starts_at),
  constraint platform_announcements_link_check check (link_url is null or link_url ~* '^https?://|^/')
);

create index if not exists idx_platform_announcements_window on public.platform_announcements (is_active, starts_at, ends_at);

create table if not exists public.platform_announcement_dismissals (
  announcement_id uuid not null references public.platform_announcements(id) on delete cascade,
  user_id         uuid not null,
  dismissed_at    timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

alter table public.platform_announcements enable row level security;
alter table public.platform_announcement_dismissals enable row level security;

drop policy if exists platform_announcements_select_admin on public.platform_announcements;
create policy platform_announcements_select_admin on public.platform_announcements for select using (is_platform_admin());
drop policy if exists platform_announcement_dismissals_select_own on public.platform_announcement_dismissals;
create policy platform_announcement_dismissals_select_own on public.platform_announcement_dismissals for select using (user_id = auth.uid());
drop policy if exists platform_announcement_dismissals_insert_own on public.platform_announcement_dismissals;
create policy platform_announcement_dismissals_insert_own on public.platform_announcement_dismissals for insert with check (user_id = auth.uid());

-- B1. What the signed-in user should see right now (their company's +
--     platform-wide, in window, not dismissed). Critical ones are never
--     dismissible regardless of the flag.
create or replace function public.get_active_announcements()
returns table (
  id          uuid,
  title       text,
  body        text,
  severity    text,
  starts_at   timestamptz,
  ends_at     timestamptz,
  dismissible boolean,
  link_url    text,
  link_label  text,
  is_global   boolean
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select a.id, a.title, a.body, a.severity, a.starts_at, a.ends_at,
         (a.dismissible and a.severity <> 'critical') as dismissible,
         a.link_url, a.link_label, (a.tenant_id is null) as is_global
  from platform_announcements a
  where a.is_active
    and a.starts_at <= now()
    and (a.ends_at is null or a.ends_at > now())
    and (a.tenant_id is null or a.tenant_id = get_my_tenant_id())
    and not exists (select 1 from platform_announcement_dismissals d
                    where d.announcement_id = a.id and d.user_id = effective_user_id())
  order by case a.severity when 'critical' then 0 when 'warning' then 1 else 2 end, a.starts_at desc;
$$;

revoke all on function public.get_active_announcements() from public;
grant execute on function public.get_active_announcements() to authenticated;

create or replace function public.dismiss_announcement(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from platform_announcements a where a.id = p_id and a.dismissible and a.severity <> 'critical') then
    raise exception 'ANNOUNCEMENT_NOT_DISMISSIBLE';
  end if;
  insert into platform_announcement_dismissals (announcement_id, user_id)
  values (p_id, auth.uid())
  on conflict do nothing;
end;
$$;

revoke all on function public.dismiss_announcement(uuid) from public;
grant execute on function public.dismiss_announcement(uuid) to authenticated;

-- B2. Admin CRUD.
create or replace function public.list_platform_announcements(p_include_past boolean default false)
returns table (
  id            uuid,
  title         text,
  body          text,
  severity      text,
  tenant_id     uuid,
  tenant_name   text,
  starts_at     timestamptz,
  ends_at       timestamptz,
  dismissible   boolean,
  link_url      text,
  link_label    text,
  is_active     boolean,
  state         text,          -- scheduled | live | ended | disabled
  dismissals    bigint,
  created_at    timestamptz,
  created_by_email text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select a.id, a.title, a.body, a.severity, a.tenant_id, t.name, a.starts_at, a.ends_at, a.dismissible,
         a.link_url, a.link_label, a.is_active,
         case
           when not a.is_active then 'disabled'
           when a.ends_at is not null and a.ends_at <= now() then 'ended'
           when a.starts_at > now() then 'scheduled'
           else 'live'
         end as state,
         (select count(*) from platform_announcement_dismissals d where d.announcement_id = a.id),
         a.created_at,
         (select email from auth.users u where u.id = a.created_by)
  from platform_announcements a
  left join tenants t on t.id = a.tenant_id
  where is_platform_admin()
    and (p_include_past or a.is_active and (a.ends_at is null or a.ends_at > now() - interval '7 days'))
  order by a.is_active desc, a.starts_at desc;
$$;

revoke all on function public.list_platform_announcements(boolean) from public;
grant execute on function public.list_platform_announcements(boolean) to authenticated;

create or replace function public.save_platform_announcement(
  p_id          uuid,
  p_title       text,
  p_body        text,
  p_severity    text default 'info',
  p_tenant_id   uuid default null,
  p_starts_at   timestamptz default now(),
  p_ends_at     timestamptz default null,
  p_dismissible boolean default true,
  p_link_url    text default null,
  p_link_label  text default null,
  p_is_active   boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id     uuid := p_id;
  v_before jsonb;
begin
  perform require_platform_admin('Publishing announcements');
  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_body), '') = '' then
    raise exception 'ANNOUNCEMENT_INVALID: title and body are required';
  end if;
  if p_tenant_id is not null and not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'ANNOUNCEMENT_INVALID: unknown company';
  end if;

  if v_id is not null then
    select to_jsonb(a) into v_before from platform_announcements a where a.id = v_id;
    update platform_announcements
       set title = btrim(p_title), body = btrim(p_body), severity = coalesce(p_severity, 'info'), tenant_id = p_tenant_id,
           starts_at = coalesce(p_starts_at, now()), ends_at = p_ends_at, dismissible = coalesce(p_dismissible, true),
           link_url = nullif(btrim(p_link_url), ''), link_label = nullif(btrim(p_link_label), ''),
           is_active = coalesce(p_is_active, true), updated_at = now()
     where id = v_id;
    if not found then raise exception 'ANNOUNCEMENT_NOT_FOUND'; end if;
  else
    insert into platform_announcements (title, body, severity, tenant_id, starts_at, ends_at, dismissible, link_url, link_label, is_active, created_by)
    values (btrim(p_title), btrim(p_body), coalesce(p_severity, 'info'), p_tenant_id, coalesce(p_starts_at, now()), p_ends_at,
            coalesce(p_dismissible, true), nullif(btrim(p_link_url), ''), nullif(btrim(p_link_label), ''), coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
  end if;

  perform log_platform_event(
    case when v_before is null then 'announcement.create' else 'announcement.update' end,
    p_tenant_id, 'announcement', v_id::text, null, v_before,
    (select to_jsonb(a) from platform_announcements a where a.id = v_id));
  return v_id;
end;
$$;

revoke all on function public.save_platform_announcement(uuid, text, text, text, uuid, timestamptz, timestamptz, boolean, text, text, boolean) from public;
grant execute on function public.save_platform_announcement(uuid, text, text, text, uuid, timestamptz, timestamptz, boolean, text, text, boolean) to authenticated;

create or replace function public.delete_platform_announcement(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_before jsonb;
begin
  perform require_platform_admin('Deleting announcements');
  select to_jsonb(a) into v_before from platform_announcements a where a.id = p_id;
  if v_before is null then return; end if;
  delete from platform_announcements where id = p_id;
  perform log_platform_event('announcement.delete', (v_before ->> 'tenant_id')::uuid, 'announcement', p_id::text, null, v_before, null);
end;
$$;

revoke all on function public.delete_platform_announcement(uuid) from public;
grant execute on function public.delete_platform_announcement(uuid) to authenticated;


-- =====================================================================
-- C. Feature flags
-- =====================================================================
create table if not exists public.platform_feature_flags (
  key             text primary key,
  description     text,
  default_enabled boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  constraint platform_feature_flags_key_check check (key ~ '^[a-z][a-z0-9_.]{1,63}$')
);

create table if not exists public.tenant_feature_flags (
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  flag_key    text not null references public.platform_feature_flags(key) on delete cascade,
  enabled     boolean not null,
  note        text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (tenant_id, flag_key)
);

alter table public.platform_feature_flags enable row level security;
alter table public.tenant_feature_flags enable row level security;

drop policy if exists platform_feature_flags_select_admin on public.platform_feature_flags;
create policy platform_feature_flags_select_admin on public.platform_feature_flags for select using (is_platform_admin());
drop policy if exists tenant_feature_flags_select_admin on public.tenant_feature_flags;
create policy tenant_feature_flags_select_admin on public.tenant_feature_flags for select using (is_platform_admin());

comment on table public.platform_feature_flags is
  'Per-feature switches independent of module entitlement. Resolve with feature_enabled(key) (current/impersonated tenant) in SQL, or get_my_feature_flags() on the client.';

-- C1. Resolve for the calling tenant. Unknown key -> false.
create or replace function public.feature_enabled(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select tf.enabled from tenant_feature_flags tf where tf.flag_key = p_key and tf.tenant_id = get_my_tenant_id()),
    (select f.default_enabled from platform_feature_flags f where f.key = p_key),
    false);
$$;

revoke all on function public.feature_enabled(text) from public;
grant execute on function public.feature_enabled(text) to authenticated;

create or replace function public.get_my_feature_flags()
returns table (key text, enabled boolean)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.key, coalesce(tf.enabled, f.default_enabled)
  from platform_feature_flags f
  left join tenant_feature_flags tf on tf.flag_key = f.key and tf.tenant_id = get_my_tenant_id()
  order by f.key;
$$;

revoke all on function public.get_my_feature_flags() from public;
grant execute on function public.get_my_feature_flags() to authenticated;

-- C2. Admin: list with rollout stats, upsert flag, set/clear per tenant.
create or replace function public.list_feature_flags()
returns table (
  key              text,
  description      text,
  default_enabled  boolean,
  updated_at       timestamptz,
  tenants_on       bigint,
  tenants_off      bigint,
  overrides        jsonb
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.key, f.description, f.default_enabled, f.updated_at,
    (select count(*) from tenant_feature_flags tf where tf.flag_key = f.key and tf.enabled),
    (select count(*) from tenant_feature_flags tf where tf.flag_key = f.key and not tf.enabled),
    (select coalesce(jsonb_agg(jsonb_build_object('tenant_id', tf.tenant_id, 'tenant_name', t.name, 'enabled', tf.enabled, 'note', tf.note, 'updated_at', tf.updated_at) order by t.name), '[]'::jsonb)
       from tenant_feature_flags tf join tenants t on t.id = tf.tenant_id where tf.flag_key = f.key)
  from platform_feature_flags f
  where is_platform_admin()
  order by f.key;
$$;

revoke all on function public.list_feature_flags() from public;
grant execute on function public.list_feature_flags() to authenticated;

create or replace function public.save_feature_flag(p_key text, p_description text, p_default_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_before jsonb;
begin
  perform require_platform_admin('Editing feature flags');
  if p_key !~ '^[a-z][a-z0-9_.]{1,63}$' then
    raise exception 'FLAG_KEY_INVALID: keys are lowercase letters, digits, dots or underscores (2-64 chars)';
  end if;
  select to_jsonb(f) into v_before from platform_feature_flags f where f.key = p_key;
  insert into platform_feature_flags (key, description, default_enabled, updated_by)
  values (p_key, nullif(btrim(p_description), ''), coalesce(p_default_enabled, false), auth.uid())
  on conflict (key) do update
    set description = excluded.description, default_enabled = excluded.default_enabled, updated_at = now(), updated_by = auth.uid();
  perform log_platform_event(
    case when v_before is null then 'feature_flag.create' else 'feature_flag.update' end,
    null, 'feature_flag', p_key, null, v_before, (select to_jsonb(f) from platform_feature_flags f where f.key = p_key));
end;
$$;

revoke all on function public.save_feature_flag(text, text, boolean) from public;
grant execute on function public.save_feature_flag(text, text, boolean) to authenticated;

create or replace function public.delete_feature_flag(p_key text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_before jsonb;
begin
  perform require_platform_admin('Deleting feature flags');
  select to_jsonb(f) into v_before from platform_feature_flags f where f.key = p_key;
  if v_before is null then return; end if;
  delete from platform_feature_flags where key = p_key;
  perform log_platform_event('feature_flag.delete', null, 'feature_flag', p_key, null, v_before, null);
end;
$$;

revoke all on function public.delete_feature_flag(text) from public;
grant execute on function public.delete_feature_flag(text) to authenticated;

-- p_enabled null clears the override (back to the default).
create or replace function public.set_tenant_feature_flag(p_tenant_id uuid, p_key text, p_enabled boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_before jsonb;
begin
  perform require_platform_admin('Changing a company''s feature flags');
  if not exists (select 1 from platform_feature_flags where key = p_key) then
    raise exception 'FLAG_NOT_FOUND: %', p_key;
  end if;
  select to_jsonb(tf) into v_before from tenant_feature_flags tf where tf.tenant_id = p_tenant_id and tf.flag_key = p_key;
  if p_enabled is null then
    delete from tenant_feature_flags where tenant_id = p_tenant_id and flag_key = p_key;
  else
    insert into tenant_feature_flags (tenant_id, flag_key, enabled, note, updated_by)
    values (p_tenant_id, p_key, p_enabled, nullif(btrim(p_note), ''), auth.uid())
    on conflict (tenant_id, flag_key) do update
      set enabled = excluded.enabled, note = excluded.note, updated_at = now(), updated_by = auth.uid();
  end if;
  perform log_platform_event('tenant.feature_flag.set', p_tenant_id, 'feature_flag', p_key, p_note, v_before,
    (select to_jsonb(tf) from tenant_feature_flags tf where tf.tenant_id = p_tenant_id and tf.flag_key = p_key));
end;
$$;

revoke all on function public.set_tenant_feature_flag(uuid, text, boolean, text) from public;
grant execute on function public.set_tenant_feature_flag(uuid, text, boolean, text) to authenticated;

-- Per-company view for Company Detail.
create or replace function public.get_tenant_feature_flags(p_tenant_id uuid)
returns table (key text, description text, default_enabled boolean, override boolean, effective boolean, note text, updated_at timestamptz)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.key, f.description, f.default_enabled, tf.enabled, coalesce(tf.enabled, f.default_enabled), tf.note, tf.updated_at
  from platform_feature_flags f
  left join tenant_feature_flags tf on tf.flag_key = f.key and tf.tenant_id = p_tenant_id
  where is_platform_admin()
  order by f.key;
$$;

revoke all on function public.get_tenant_feature_flags(uuid) from public;
grant execute on function public.get_tenant_feature_flags(uuid) to authenticated;


-- =====================================================================
-- D. Health
-- =====================================================================
create table if not exists public.platform_job_runs (
  id           uuid primary key default gen_random_uuid(),
  job          text not null,                  -- 'machine_maintenance_overdue_sweep' | 'sustainability_cert_expiry_sweep' | 'operator_digest' | ...
  tenant_id    uuid references public.tenants(id) on delete cascade,   -- null for platform-wide jobs
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'ok',     -- ok | error
  affected     integer,
  detail       text,
  constraint platform_job_runs_status_check check (status in ('ok', 'error'))
);

create index if not exists idx_platform_job_runs_job_time on public.platform_job_runs (job, started_at desc);

alter table public.platform_job_runs enable row level security;
drop policy if exists platform_job_runs_select_admin on public.platform_job_runs;
create policy platform_job_runs_select_admin on public.platform_job_runs for select using (is_platform_admin());

-- Internal recorder. Not granted to clients.
create or replace function public.platform_record_job_run(p_job text, p_tenant_id uuid, p_status text, p_affected integer, p_detail text default null)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into platform_job_runs (job, tenant_id, started_at, finished_at, status, affected, detail)
  values (p_job, p_tenant_id, now(), now(), coalesce(p_status, 'ok'), p_affected, left(p_detail, 500));
$$;

revoke all on function public.platform_record_job_run(text, uuid, text, integer, text) from public, authenticated, anon;

-- Keep the table from growing forever: 90 days.
create or replace function public.platform_job_runs_prune()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_n integer;
begin
  delete from platform_job_runs where started_at < now() - interval '90 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.platform_job_runs_prune() from public, authenticated, anon;

-- D1. The two "cronless cron" sweeps now record themselves. Bodies are
--     the originals with the recorder call added; contracts unchanged.
CREATE OR REPLACE FUNCTION "public"."machine_maintenance_overdue_sweep"()
RETURNS integer
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_req record;
  v_count int := 0;
  v_tenant uuid;
begin
  if not has_module_role('machine_operation', array['admin', 'manager', 'member']) then
    return 0; -- outsiders just get nothing
  end if;
  v_tenant := get_my_tenant_id();

  for v_req in
    select r.*, m.machine_no, m.name as machine_name
    from maintenance_requests r
    join machines m on m.id = r.machine_id
    where r.tenant_id = v_tenant
      and r.status in ('scheduled', 'in_progress')
      and r.scheduled_date is not null
      and r.scheduled_date < current_date
      and r.overdue_notified_at is null
  loop
    insert into notifications (tenant_id, recipient_id, type, title, body)
    select distinct on (recipient) v_req.tenant_id, recipient,
      'maintenance_overdue',
      'Maintenance overdue: ' || v_req.machine_no,
      format('"%s" on machine %s - %s was scheduled for %s and is %s day(s) overdue.',
        left(v_req.description, 80), v_req.machine_no, v_req.machine_name,
        v_req.scheduled_date::text, (current_date - v_req.scheduled_date)::text)
    from (values (v_req.requested_by), (v_req.assigned_to)) as rec(recipient)
    where recipient is not null;

    update maintenance_requests
    set overdue_notified_at = now()
    where id = v_req.id;

    v_count := v_count + 1;
  end loop;

  perform platform_record_job_run('machine_maintenance_overdue_sweep', v_tenant, 'ok', v_count);
  return v_count;
end;
$$;

-- Wrap the sustainability sweep the same way without restating its body:
-- rename-free approach -- call the existing function from a recorder.
do $$
begin
  -- Only if the original exists under this name (it does on every stack
  -- that ran 20260921130000); guard so a partial replay cannot fail.
  if to_regprocedure('public.sustainability_cert_expiry_sweep()') is not null
     and to_regprocedure('public.sustainability_cert_expiry_sweep_impl()') is null then
    alter function public.sustainability_cert_expiry_sweep() rename to sustainability_cert_expiry_sweep_impl;
    revoke all on function public.sustainability_cert_expiry_sweep_impl() from public, authenticated, anon;
  end if;
end $$;

create or replace function public.sustainability_cert_expiry_sweep()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_n integer;
begin
  v_n := sustainability_cert_expiry_sweep_impl();
  if has_module_role('sustainability', array['admin', 'manager', 'member']) then
    perform platform_record_job_run('sustainability_cert_expiry_sweep', get_my_tenant_id(), 'ok', v_n);
  end if;
  return v_n;
end;
$$;

revoke all on function public.sustainability_cert_expiry_sweep() from public;
grant execute on function public.sustainability_cert_expiry_sweep() to authenticated;

-- D2. The digest job records itself too (wrap, keep signature).
create or replace function public.platform_run_operator_digest_logged()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  begin
    v_id := platform_run_operator_digest('scheduled');
    perform platform_record_job_run('operator_digest', null, 'ok', case when v_id is null then 0 else 1 end,
      case when v_id is null then 'skipped: digest_enabled = false' else v_id::text end);
    perform platform_job_runs_prune();
  exception when others then
    perform platform_record_job_run('operator_digest', null, 'error', 0, sqlerrm);
    raise;
  end;
  return v_id;
end;
$$;

revoke all on function public.platform_run_operator_digest_logged() from public, authenticated, anon;

do $$
declare v_job bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    select jobid into v_job from cron.job where jobname = 'platform_operator_digest_daily';
    if v_job is not null then perform cron.unschedule(v_job); end if;
    perform cron.schedule('platform_operator_digest_daily', '0 4 * * *', 'select public.platform_run_operator_digest_logged();');
  end if;
end $$;

-- D3. One document for /admin/health.
create or replace function public.get_platform_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
  v_has_cron boolean := exists (select 1 from pg_extension where extname = 'pg_cron');
  v_has_storage boolean := to_regclass('storage.objects') is not null;
  v_storage jsonb := '[]'::jsonb;
  v_cron jsonb := '[]'::jsonb;
  v_migration text;
  v_migration_count integer := 0;
begin
  if not is_platform_admin() then
    raise exception 'PLATFORM_ADMIN_REQUIRED: platform health is restricted to platform admins' using errcode = '42501';
  end if;

  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute 'select max(version), count(*)::int from supabase_migrations.schema_migrations' into v_migration, v_migration_count;
  end if;

  if v_has_storage then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket_id, 'objects', n, 'bytes', bytes) order by bytes desc), '[]'::jsonb)
      from (select bucket_id, count(*) as n, coalesce(sum((metadata ->> 'size')::bigint), 0) as bytes
            from storage.objects group by bucket_id) s
    $q$ into v_storage;
  end if;

  if v_has_cron then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object(
        'jobname', j.jobname, 'schedule', j.schedule, 'active', j.active,
        'last_status', r.status, 'last_start', r.start_time, 'last_end', r.end_time, 'last_message', left(r.return_message, 200)
      ) order by j.jobname), '[]'::jsonb)
      from cron.job j
      left join lateral (select status, start_time, end_time, return_message from cron.job_run_details d
                         where d.jobid = j.jobid order by start_time desc limit 1) r on true
    $q$ into v_cron;
  end if;

  select jsonb_build_object(
    'checked_at', now(),
    'database', jsonb_build_object(
      'version', split_part(version(), ' ', 2),
      'size_bytes', pg_database_size(current_database()),
      'connections', (select count(*) from pg_stat_activity where datname = current_database()),
      'max_connections', current_setting('max_connections')::int
    ),
    'migrations', jsonb_build_object('latest', v_migration, 'count', v_migration_count),
    'cron', jsonb_build_object('installed', v_has_cron, 'jobs', v_cron),
    'jobs', (
      -- Last run per job; the UI decides freshness (sweeps are per tenant
      -- and only run when someone opens the page, so "stale" is a hint
      -- not an alarm; the digest is expected daily).
      select coalesce(jsonb_agg(jsonb_build_object(
        'job', j.job, 'last_run_at', j.last_run_at, 'last_status', j.last_status, 'last_affected', j.last_affected,
        'last_detail', j.last_detail, 'runs_7d', j.runs_7d, 'errors_7d', j.errors_7d, 'tenants_7d', j.tenants_7d
      ) order by j.job), '[]'::jsonb)
      from (
        select r.job,
               max(r.started_at) as last_run_at,
               (array_agg(r.status order by r.started_at desc))[1] as last_status,
               (array_agg(r.affected order by r.started_at desc))[1] as last_affected,
               (array_agg(r.detail order by r.started_at desc))[1] as last_detail,
               count(*) filter (where r.started_at > now() - interval '7 days') as runs_7d,
               count(*) filter (where r.started_at > now() - interval '7 days' and r.status = 'error') as errors_7d,
               count(distinct r.tenant_id) filter (where r.started_at > now() - interval '7 days') as tenants_7d
        from platform_job_runs r
        group by r.job
      ) j
    ),
    'digest', jsonb_build_object(
      'last_generated_at', (select max(generated_at) from platform_digests),
      'failed_7d', (select count(*) from platform_digests where delivery_status = 'failed' and generated_at > now() - interval '7 days'),
      'pending', (select count(*) from platform_digests where delivery_status = 'pending')
    ),
    'stuck_approvals', (
      -- Open requests sitting at a stage for more than 7 days, per company.
      select coalesce(jsonb_agg(jsonb_build_object('tenant_id', s.tenant_id, 'tenant_name', s.name, 'count', s.n, 'oldest_days', s.oldest) order by s.n desc), '[]'::jsonb)
      from (
        select r.tenant_id, t.name, count(*) as n,
               max(extract(epoch from (now() - r.updated_at)) / 86400)::integer as oldest
        from requests r join tenants t on t.id = r.tenant_id
        where r.status = 'open' and r.current_stage_id is not null and r.updated_at < now() - interval '7 days'
        group by r.tenant_id, t.name
        limit 25
      ) s
    ),
    'stale_invites', (
      select coalesce(jsonb_agg(jsonb_build_object('tenant_id', s.tenant_id, 'tenant_name', s.name, 'count', s.n, 'oldest_days', s.oldest) order by s.n desc), '[]'::jsonb)
      from (
        select i.tenant_id, t.name, count(*) as n,
               max(extract(epoch from (now() - i.created_at)) / 86400)::integer as oldest
        from invitations i join tenants t on t.id = i.tenant_id
        where i.status = 'pending' and i.created_at < now() - interval '7 days'
        group by i.tenant_id, t.name
        limit 25
      ) s
    ),
    'read_only_tenants', (select count(*) from tenants where read_only),
    'open_impersonations', (select count(*) from impersonation_sessions where ended_at is null and (expires_at is null or expires_at > now())),
    'storage', jsonb_build_object('available', v_has_storage, 'buckets', v_storage),
    'announcements_live', (select count(*) from platform_announcements a where a.is_active and a.starts_at <= now() and (a.ends_at is null or a.ends_at > now())),
    'feature_flags', (select count(*) from platform_feature_flags)
  ) into v;

  return v;
end;
$$;

revoke all on function public.get_platform_health() from public;
grant execute on function public.get_platform_health() to authenticated;
