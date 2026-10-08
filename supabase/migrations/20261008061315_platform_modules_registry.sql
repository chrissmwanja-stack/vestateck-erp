-- Phase 1, step 1 of the Insurance Brokerage vertical work (decision D1 in
-- PHASE0_COUPLING_AUDIT.md): a module registry as data.
--
-- Until now the set of valid module keys lived in three hand-copied CHECK
-- constraints (tenant_modules, staff_roles, platform_module_activity_sources),
-- in save_industry_template(), in two edge functions and in the frontend.
-- Adding a module meant editing all of them. This migration makes the database
-- side a single table; later steps point the edge functions and frontend at it.
--
-- Behaviour is intentionally IDENTICAL to before:
--   * the 8 entitled keys are exactly the old CHECK list;
--   * 'finance' is registered (it is already a valid key in
--     platform_module_activity_sources) but is NOT tenant-entitled, so it is
--     still rejected by tenant_modules / staff_roles, as the old CHECKs did;
--   * unknown keys are still rejected, now by a foreign key instead of a CHECK.
--
-- tier is classification metadata only (core / optional / vertical). Whether a
-- key may be entitled to a tenant is controlled by tenant_entitled, so
-- classifying 'hr' as core does not change that it is entitled per tenant today.
--
-- Additive except for swapping three CHECK constraints for FKs. No column drops.

-- =====================================================================
-- A. Registry
-- =====================================================================
create table if not exists public.platform_modules (
  key             text primary key,
  name            text not null,
  tier            text not null,
  vertical        text,                                -- industry pack this module belongs to (tier = 'vertical')
  route_base      text,                                -- web app base path, e.g. '/pmo'
  depends_on      text[] not null default '{}',        -- other module keys this one needs
  tenant_entitled boolean not null default true,       -- may a row exist in tenant_modules / staff_roles?
  is_active       boolean not null default true,
  sort_order      integer not null default 100,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint platform_modules_key_check check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  constraint platform_modules_tier_check check (tier in ('core', 'optional', 'vertical')),
  constraint platform_modules_vertical_check check ((tier = 'vertical') = (vertical is not null))
);

comment on table public.platform_modules is
  'Registry of platform modules. Source of truth for valid module keys: tenant_modules.module, staff_roles.module and platform_module_activity_sources.module reference it. tier is classification (core/optional/vertical); tenant_entitled says whether a key can be entitled to a tenant (finance is core and not entitled per tenant). Writes are migration/service-role only for now.';

alter table public.platform_modules enable row level security;

-- The registry is non-sensitive metadata and the web app needs it for
-- navigation and admin screens, so any signed-in user may read it.
-- No write policies: changes ship as migrations (or service_role).
drop policy if exists platform_modules_select on public.platform_modules;
create policy platform_modules_select on public.platform_modules
  for select to authenticated using (true);

revoke all on public.platform_modules from anon, authenticated;
grant select on public.platform_modules to authenticated;

insert into public.platform_modules (key, name, tier, vertical, route_base, depends_on, tenant_entitled, sort_order) values
  ('finance',           'Finance & GL',          'core',     null,           '/financial-management', '{}', false, 10),
  ('hr',                'Human Resources',       'core',     null,           '/hr',                   '{}', true,  20),
  ('procurement',       'Procurement',           'optional', null,           '/procurement',          '{}', true,  30),
  ('legal',             'Law & Compliance',      'optional', null,           '/law-compliance',       '{}', true,  40),
  ('it',                'IT Support',            'optional', null,           '/it-support',           '{}', true,  50),
  ('bd',                'Business Development',  'optional', null,           '/business-development', '{}', true,  60),
  ('pmo',               'Project Management',    'vertical', 'construction', '/pmo',                  '{}', true,  70),
  ('machine_operation', 'Machine Operation',     'vertical', 'construction', '/machine-operation',    '{}', true,  80),
  ('sustainability',    'Sustainability',        'vertical', 'construction', '/sustainability',       '{}', true,  90)
on conflict (key) do nothing;

-- =====================================================================
-- B. Replace the three CHECK lists with foreign keys
-- =====================================================================
alter table public.tenant_modules drop constraint if exists tenant_modules_module_check;
alter table public.staff_roles drop constraint if exists staff_roles_module_check;
alter table public.platform_module_activity_sources drop constraint if exists platform_module_activity_sources_module_check;

alter table public.tenant_modules drop constraint if exists tenant_modules_module_fkey;
alter table public.tenant_modules
  add constraint tenant_modules_module_fkey
  foreign key (module) references public.platform_modules (key) on update cascade on delete restrict;

alter table public.staff_roles drop constraint if exists staff_roles_module_fkey;
alter table public.staff_roles
  add constraint staff_roles_module_fkey
  foreign key (module) references public.platform_modules (key) on update cascade on delete restrict;

alter table public.platform_module_activity_sources drop constraint if exists platform_module_activity_sources_module_fkey;
alter table public.platform_module_activity_sources
  add constraint platform_module_activity_sources_module_fkey
  foreign key (module) references public.platform_modules (key) on update cascade on delete restrict;

-- FK-supporting indexes (platform_module_activity_sources already leads its PK with module).
create index if not exists tenant_modules_module_idx on public.tenant_modules (module);
create index if not exists staff_roles_module_idx on public.staff_roles (module);

-- =====================================================================
-- C. Keep 'finance' (and any future non-entitled key) out of entitlements
-- =====================================================================
create or replace function public.enforce_tenant_entitled_module()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Only blocks keys that ARE registered but not entitlable. Unknown keys fall
  -- through so the foreign key reports them (foreign_key_violation).
  if exists (
    select 1 from platform_modules m
    where m.key = new.module and not m.tenant_entitled
  ) then
    raise exception 'MODULE_NOT_ENTITLABLE: % cannot be entitled to a tenant or given staff roles', new.module
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_tenant_entitled_module() from public, anon, authenticated;

drop trigger if exists trg_tenant_modules_entitled on public.tenant_modules;
create trigger trg_tenant_modules_entitled
  before insert or update of module on public.tenant_modules
  for each row execute function public.enforce_tenant_entitled_module();

drop trigger if exists trg_staff_roles_entitled on public.staff_roles;
create trigger trg_staff_roles_entitled
  before insert or update of module on public.staff_roles
  for each row execute function public.enforce_tenant_entitled_module();