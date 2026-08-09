-- Onboarding flow: schema migration
-- Adds tenant lifecycle tracking and an invitations table for the
-- super admin -> company admin -> team member invite chain.
-- See vestateck-erp-session-notes.md section 5 for the full spec.

-- 1. Track tenant lifecycle -------------------------------------------------

alter table tenants
  add column created_by uuid references app_users(id);

alter table tenants
  add column status text not null default 'pending'
    check (status in ('pending', 'active', 'suspended'));

-- 2. Invitations table --------------------------------------------------

create table invitations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  email text not null,
  invited_by uuid not null references app_users(id),
  role_bundle text not null default 'company_admin'
    check (role_bundle in ('company_admin', 'member')),
  modules_and_roles jsonb,  -- null for company_admin (implies all 4, admin);
                             -- explicit array for member invites, e.g.
                             -- [{"module":"hr","role":"manager"}]
  status text not null default 'pending'
    check (status in ('pending','accepted','expired','revoked')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  unique (tenant_id, email, status)
);

comment on table invitations is
  'Tracks invite lifecycle independently of auth.users. Rows are created by the invite-user edge function and consumed by accept-invite.';

-- Query pattern: "show pending invites for tenant X" (Company Setup checklist,
-- Team -> Invite member screen).
create index invitations_tenant_status_idx
  on invitations (tenant_id, status);

alter table invitations enable row level security;

-- 3. RLS policies ------------------------------------------------------

-- Platform (super) admins can see and manage every invitation, across tenants.
create policy invitations_select_platform_admin
  on invitations for select
  using (is_platform_admin());

create policy invitations_insert_platform_admin
  on invitations for insert
  with check (is_platform_admin());

-- Tenant-scoped module admins can see invites for their own tenant, and can
-- create 'member' invites (not 'company_admin' invites -- that stays a
-- platform-admin-only action, enforced here and again in invite-user).
create policy invitations_select_tenant_admin
  on invitations for select
  using (
    tenant_id = get_my_tenant_id()
    and exists (
      select 1 from staff_roles
      where user_id = auth.uid()
        and tenant_id = invitations.tenant_id
        and role = 'admin'
    )
  );

create policy invitations_insert_tenant_admin
  on invitations for insert
  with check (
    role_bundle = 'member'
    and tenant_id = get_my_tenant_id()
    and exists (
      select 1 from staff_roles
      where user_id = auth.uid()
        and tenant_id = invitations.tenant_id
        and role = 'admin'
    )
  );

-- No UPDATE policy for authenticated users: accept-invite runs with the
-- service role (via the edge function), which bypasses RLS. Revoke/expire
-- flows, when built, should go through a SECURITY DEFINER RPC rather than a
-- direct client-side UPDATE policy, matching the rest of the codebase.

-- 4. Platform admin visibility on tenants --------------------------------
-- Added a session later, while building the Companies console: the only
-- existing SELECT policy on tenants (tenants_select_own) scopes to
-- id = get_my_tenant_id(), so a platform admin couldn't see any tenant
-- but their own. This lets them see all of them, same is_platform_admin()
-- gate used everywhere else in this migration.

create policy tenants_select_platform_admin
  on tenants for select
  using (is_platform_admin());