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
  generated_at timestamptz not null default now()
);

create index idx_purchase_orders_request on purchase_orders(request_id);

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
