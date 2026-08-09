-- 0001_init_core_schema.sql
-- Core schema for the ERP platform: tenants, departments, users, cost centers,
-- workflow stages, requests, offers, approvals, delegations, and purchase orders.
--
-- NOTE: Row Level Security is enabled per-table but policies are NOT defined yet.
-- That is a deliberate, separate step to be designed once the schema stabilizes.
-- Until policies are added, these tables are only reachable via the service role.

create extension if not exists "pgcrypto";

-- ============================================================================
-- TENANTS
-- ============================================================================
create table tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  industry_template text not null default 'general', -- e.g. 'general', 'construction'
  created_at timestamptz not null default now()
);

-- ============================================================================
-- DEPARTMENTS (self-referencing for nesting)
-- ============================================================================
create table departments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null,
  parent_department_id uuid references departments(id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index idx_departments_tenant on departments(tenant_id);
create index idx_departments_parent on departments(parent_department_id);

-- ============================================================================
-- APP_USERS (profile row linked 1:1 to an auth.users row)
-- ============================================================================
create table app_users (
  id uuid primary key references auth.users(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  department_id uuid references departments(id) on delete set null,
  name text not null,
  email text not null,
  role_title text, -- free-text job title, e.g. "Cost Control Manager"
  created_at timestamptz not null default now()
);

create index idx_app_users_tenant on app_users(tenant_id);
create index idx_app_users_department on app_users(department_id);

-- ============================================================================
-- COST CENTERS / PROJECTS
-- ============================================================================
create table cost_centers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null,
  project_code text,
  budget_amount numeric(14, 2),
  created_at timestamptz not null default now()
);

create index idx_cost_centers_tenant on cost_centers(tenant_id);

-- ============================================================================
-- WORKFLOW STAGES (tenant-configurable, ordered, branching)
-- ============================================================================
create table workflow_stages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  name text not null,                         -- e.g. "Cost Control Manager"
  sequence_order int not null,
  approver_role text not null,                -- role_title expected to act at this stage
  threshold_amount numeric(14, 2),            -- null = no threshold check at this stage
  next_stage_low_id uuid references workflow_stages(id),   -- default / below-threshold path
  next_stage_high_id uuid references workflow_stages(id),  -- above-threshold branch (nullable)
  created_at timestamptz not null default now()
);

create index idx_workflow_stages_tenant on workflow_stages(tenant_id);

-- ============================================================================
-- REQUESTS (the core object)
-- ============================================================================
create table requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  requester_id uuid not null references app_users(id),
  department_id uuid not null references departments(id),
  cost_center_id uuid references cost_centers(id),
  current_stage_id uuid references workflow_stages(id),
  item_description text not null,
  quantity int not null default 1,
  status text not null default 'open'
    check (status in ('open', 'rejected', 'closed')),
  replaces_request_id uuid references requests(id), -- optional lineage for resubmissions
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_requests_tenant on requests(tenant_id);
create index idx_requests_requester on requests(requester_id);
create index idx_requests_stage on requests(current_stage_id);
create index idx_requests_status on requests(status);

-- ============================================================================
-- REQUEST OFFERS (vendor quotation entered during Procurement)
-- ============================================================================
create table request_offers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references requests(id) on delete cascade,
  vendor_name text not null,
  quotation_amount numeric(14, 2) not null,
  quantity int not null default 1,
  submitted_by uuid not null references app_users(id),
  submitted_at timestamptz not null default now()
);

create index idx_request_offers_request on request_offers(request_id);

-- ============================================================================
-- APPROVAL ASSIGNMENTS (who holds authority for which stage/scope)
-- ============================================================================
create table approval_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  user_id uuid not null references app_users(id) on delete cascade,
  workflow_stage_id uuid not null references workflow_stages(id) on delete cascade,
  scope_type text not null default 'global'
    check (scope_type in ('department', 'cost_center', 'global')),
  scope_id uuid, -- department_id or cost_center_id, depending on scope_type; null if global
  threshold_max numeric(14, 2), -- authority cap this user holds at this stage
  created_at timestamptz not null default now()
);

create index idx_approval_assignments_tenant on approval_assignments(tenant_id);
create index idx_approval_assignments_user on approval_assignments(user_id);
create index idx_approval_assignments_stage on approval_assignments(workflow_stage_id);

-- ============================================================================
-- APPROVAL ACTIONS (full audit trail of every decision at every stage)
-- ============================================================================
create table approval_actions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references requests(id) on delete cascade,
  workflow_stage_id uuid not null references workflow_stages(id),
  approver_id uuid not null references app_users(id),
  acted_on_behalf_of uuid references app_users(id), -- set when a delegate acted
  decision text not null check (decision in ('approved', 'rejected')),
  comment text,
  acted_at timestamptz not null default now()
);

create index idx_approval_actions_request on approval_actions(request_id);
create index idx_approval_actions_stage on approval_actions(workflow_stage_id);

-- ============================================================================
-- APPROVAL DELEGATIONS (time-boxed, stage-scoped, capped at delegator's authority)
-- ============================================================================
create table approval_delegations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  delegator_user_id uuid not null references app_users(id) on delete cascade,
  delegate_user_id uuid not null references app_users(id) on delete cascade,
  workflow_stage_id uuid references workflow_stages(id), -- null = all stages delegator owns
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  status text not null default 'active'
    check (status in ('active', 'expired', 'revoked')),
  created_at timestamptz not null default now(),

  constraint chk_delegation_window check (ends_at > starts_at)
);

create index idx_approval_delegations_tenant on approval_delegations(tenant_id);
create index idx_approval_delegations_delegator on approval_delegations(delegator_user_id);
create index idx_approval_delegations_delegate on approval_delegations(delegate_user_id);
create index idx_approval_delegations_status on approval_delegations(status);

-- ============================================================================
-- PURCHASE ORDERS (generated once a request clears Finance)
-- ============================================================================
create table purchase_orders (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references requests(id) on delete cascade,
  po_number text not null unique,
  vendor_name text not null,
  amount numeric(14, 2) not null,
  generated_by uuid not null references app_users(id),
  generated_at timestamptz not null default now(),
  -- shared_with_supplier/delivered_at/completed_at were added directly via
  -- the Supabase Studio table editor before migration tracking began on
  -- 2026-07-30, so there was never a standalone ALTER TABLE for them.
  -- Included directly in the initial CREATE TABLE here (rather than a
  -- separate backfill migration) since no filename can sort between the
  -- legacy bare-numbered 0001-0017 files that the Supabase CLI accepts --
  -- timestamped files always sort after all of them, and lettered suffixes
  -- (0001b, 0001c) are rejected outright by the CLI's filename pattern.
  -- This file is already applied on the live DB and won't be re-run there;
  -- this edit only affects fresh replays (shadow db, staging, disaster
  -- recovery).
  shared_with_supplier boolean not null default false,
  delivered_at timestamptz,
  completed_at timestamptz
);

create index idx_purchase_orders_request on purchase_orders(request_id);

-- ============================================================================
-- PRE-TRACKING HELPER FUNCTIONS
-- ============================================================================
-- get_my_tenant_id() and can_act_on_stage() were created directly via the
-- Supabase SQL Editor before migration tracking began on 2026-07-30, so
-- there was never a standalone CREATE FUNCTION for either. 0005 calls
-- get_my_tenant_id() and 0008 calls can_act_on_stage() with no earlier
-- migration defining them, which breaks fresh replays the same way the
-- pre-tracking tenant/department/workflow_stage rows above did.
--
-- Defined here in their ORIGINAL pre-tracking form -- neither one has the
-- is_platform_admin() bypass yet, since is_platform_admin() itself isn't
-- created until 20260801132413_platform_admin_and_finance_team.sql and the
-- bypass isn't added to either function until
-- 20260807075702_add_platform_admin_bypass_to_po_and_stage_functions.sql,
-- which CREATE OR REPLACEs both later in the timeline. This file is already
-- applied on the live DB and won't be re-run there; this addition only
-- affects fresh replays.

create or replace function public.get_my_tenant_id()
returns uuid
language sql
stable security definer
set search_path to 'public'
as $$
  select tenant_id from app_users where id = auth.uid();
$$;

create or replace function public.can_act_on_stage(check_stage_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select
    exists (
      select 1 from approval_assignments aa
      where aa.user_id = auth.uid()
        and aa.workflow_stage_id = check_stage_id
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      where d.delegate_user_id = auth.uid()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and aa.workflow_stage_id = check_stage_id
        and (d.workflow_stage_id is null or d.workflow_stage_id = check_stage_id)
    );
$$;

-- ============================================================================
-- PRE-TRACKING SEED DATA
-- ============================================================================
-- The rows below (tenant, departments, workflow stages, three test users,
-- and their approval assignments) were created directly via the Supabase
-- Studio table editor / Auth panel on 2026-07-30, before migration tracking
-- began. They were never captured by a migration, which breaks fresh-
-- environment replays (shadow DB for `db pull`, CI, staging, disaster
-- recovery) as soon as 0004_ccm_budget_approval_stage.sql and later
-- migrations try to UPDATE or reference them by hardcoded id.
--
-- Seeded here in their ORIGINAL pre-migration-history shape -- e.g. stage
-- 033 is named "Control Chief/Manager" with approver_role "Procurement &
-- Logistics Chief", not the "Budget Controller" / "Cost Control Manager"
-- it becomes later -- so that the later ALTER/UPDATE statements (0003,
-- 0004, 0006, 0007, 20260731124853, etc.) transform them forward into
-- exactly the state they reached live, rather than snapshotting current
-- values and risking drift from what those later migrations expect.
--
-- This file is already applied on the live DB and won't be re-run there;
-- this addition only affects fresh replays. See also the it@test.local /
-- hr@test.local gap fixed in a small seed migration dated just before
-- 20260806143937_add_it_platform_admin_and_hr_manager.sql, for the same
-- class of issue surfacing later in the history.

insert into tenants (id, name, industry_template, created_at) values
  ('00000000-0000-0000-0000-000000000001', 'Test Construction Co', 'construction', '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

insert into departments (id, tenant_id, name, created_at) values
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'Cost Control', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'Procurement & Logistics', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', 'Finance & Financial Reporting', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', 'Project Management Office', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000001', 'IT Support', '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000001', 'Human Resources', '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

-- Workflow stages, original shape. next_stage_low_id/next_stage_high_id are
-- backfilled via UPDATE afterward (rather than inline in the INSERT) purely
-- to sidestep self-referencing forward-reference ordering.
insert into workflow_stages (id, tenant_id, name, sequence_order, approver_role, threshold_amount, created_at) values
  ('00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000001', 'Cost Control Engineer', 1, 'Cost Control Engineer', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000001', 'Cost Control Manager', 2, 'Cost Control Manager', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000001', 'Procurement: Offer Entry', 3, 'Procurement/Logistics Expert', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000033', '00000000-0000-0000-0000-000000000001', 'Control Chief/Manager', 4, 'Procurement & Logistics Chief', 5000000.00, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000034', '00000000-0000-0000-0000-000000000001', 'Finance', 5, 'Finance Officer', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-000000000001', 'Project Manager', 6, 'Project Manager', null, '2026-07-30 11:30:48.602762+00'),
  ('00000000-0000-0000-0000-000000000036', '00000000-0000-0000-0000-000000000001', 'Deputy General Manager', 7, 'Deputy General Manager', null, '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000031' where id = '00000000-0000-0000-0000-000000000030';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000032' where id = '00000000-0000-0000-0000-000000000031';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000033' where id = '00000000-0000-0000-0000-000000000032';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000034', next_stage_high_id = '00000000-0000-0000-0000-000000000035' where id = '00000000-0000-0000-0000-000000000033';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000036' where id = '00000000-0000-0000-0000-000000000035';
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000034' where id = '00000000-0000-0000-0000-000000000036';

-- Three original test accounts (auth.users + app_users), same "direct
-- auth.users insert, no admin API" pattern as the later
-- 20260730143728_seed_missing_stage_test_users.sql migration for the rest
-- of the roster. Test password for all: Tester123
do $$
declare
  v_tenant_id uuid := '00000000-0000-0000-0000-000000000001';
begin
  if not exists (select 1 from auth.users where id = 'b93bd287-c359-44cc-a7a6-2dd1578b06ee') then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token
    ) values
    ('00000000-0000-0000-0000-000000000000', 'b93bd287-c359-44cc-a7a6-2dd1578b06ee', 'authenticated', 'authenticated',
     'cost.control@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', ''),
    ('00000000-0000-0000-0000-000000000000', 'ed9cd87d-7649-486c-958b-36114271a0b2', 'authenticated', 'authenticated',
     'finance@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', ''),
    ('00000000-0000-0000-0000-000000000000', '6cb314bb-c39e-40e2-aca9-446e12a1795f', 'authenticated', 'authenticated',
     'procurement@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-07-30 11:30:48.602762+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-07-30 11:30:48.602762+00', '2026-07-30 11:30:48.602762+00', '', '');
  end if;

  insert into app_users (id, tenant_id, department_id, name, email, role_title, created_at) values
    ('b93bd287-c359-44cc-a7a6-2dd1578b06ee', v_tenant_id, '00000000-0000-0000-0000-000000000010', 'Test Cost Controller', 'cost.control@test.local', 'Cost Control Manager', '2026-07-30 11:30:48.602762+00'),
    ('ed9cd87d-7649-486c-958b-36114271a0b2', v_tenant_id, '00000000-0000-0000-0000-000000000012', 'Test Finance Officer', 'finance@test.local', 'Finance Officer', '2026-07-30 11:30:48.602762+00'),
    ('6cb314bb-c39e-40e2-aca9-446e12a1795f', v_tenant_id, '00000000-0000-0000-0000-000000000011', 'Test Procurement Lead', 'procurement@test.local', 'Procurement & Logistics Chief', '2026-07-30 11:30:48.602762+00')
  on conflict (id) do nothing;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max, created_at) values
    (v_tenant_id, 'b93bd287-c359-44cc-a7a6-2dd1578b06ee', '00000000-0000-0000-0000-000000000031', 'global', null, '2026-07-30 11:30:48.602762+00'),
    (v_tenant_id, 'ed9cd87d-7649-486c-958b-36114271a0b2', '00000000-0000-0000-0000-000000000034', 'global', null, '2026-07-30 11:30:48.602762+00');
end $$;

-- ============================================================================
-- Row Level Security: enabled now, policies deliberately deferred
-- ============================================================================
alter table tenants enable row level security;
alter table departments enable row level security;
alter table app_users enable row level security;
alter table cost_centers enable row level security;
alter table workflow_stages enable row level security;
alter table requests enable row level security;
alter table request_offers enable row level security;
alter table approval_assignments enable row level security;
alter table approval_actions enable row level security;
alter table approval_delegations enable row level security;
alter table purchase_orders enable row level security;

-- Policies to be added in a later migration once access patterns are finalized.