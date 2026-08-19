-- Tenant module entitlements.
--
-- Until now, "which modules does a company have" was never actually
-- enforced -- has_module_role() only checked whether the calling user
-- held a staff_roles row for that module within their own tenant. A
-- company_admin invite grants staff_roles for ALL 8 modules
-- (accept-invite's ALL_MODULES insert), so in practice every tenant
-- already had every module unlocked the moment its first admin
-- accepted their invite. This migration adds the missing tenant-level
-- gate so a platform admin can actually decide which modules a given
-- company gets.
--
-- Design: presence in tenant_modules = enabled. No boolean column --
-- absence of a row is the "disabled" state, matching the pattern
-- already used by staff_roles.
create table public.tenant_modules (
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  module     text not null check (module in (
               'hr', 'legal', 'bd', 'it', 'pmo',
               'machine_operation', 'sustainability', 'procurement'
             )),
  enabled_at timestamptz not null default now(),
  enabled_by uuid references public.app_users(id),
  primary key (tenant_id, module)
);

alter table public.tenant_modules enable row level security;

-- Tenant members can see their own tenant's entitlements (nav needs
-- this to hide modules the company doesn't have); platform admins can
-- see any tenant's, for the Companies Console management screen.
create policy "tenant_modules_select"
  on public.tenant_modules
  for select
  using (tenant_id = public.get_my_tenant_id() or public.is_platform_admin());

-- Only platform admins grant/revoke modules for a company.
create policy "tenant_modules_insert_platform_admin"
  on public.tenant_modules
  for insert
  with check (public.is_platform_admin());

create policy "tenant_modules_delete_platform_admin"
  on public.tenant_modules
  for delete
  using (public.is_platform_admin());

-- Backfill: every existing tenant keeps full access to every module
-- it already effectively had (there was no gate before this
-- migration, so removing access here would be a silent regression).
-- New tenants created after this migration get scoped defaults via
-- seed_tenant_defaults() below instead.
insert into public.tenant_modules (tenant_id, module)
select t.id, m.module
from public.tenants t
cross join (
  values ('hr'), ('legal'), ('bd'), ('it'), ('pmo'),
         ('machine_operation'), ('sustainability'), ('procurement')
) as m(module)
on conflict do nothing;

-- Wire the gate into the one function every module's access check
-- (is_business_dev, is_it_support, has_module_role callers in HR/
-- legal/pmo/sustainability/machine_operation RLS policies) already
-- funnels through. Platform admins keep their existing full bypass --
-- they need it for cross-tenant support/impersonation regardless of
-- what a given company has enabled.
create or replace function public.has_module_role(p_module text, p_roles text[])
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select
    exists (
      select 1 from public.app_users
      where id = auth.uid() and is_platform_admin
    )
    or (
      exists (
        select 1 from public.tenant_modules
        where tenant_id = public.get_my_tenant_id()
          and module = p_module
      )
      and exists (
        select 1 from public.staff_roles
        where user_id = auth.uid()
          and module = p_module
          and role = any(p_roles)
          and tenant_id = public.get_my_tenant_id()
      )
    );
$function$;

-- Scoped module defaults for newly created tenants, layered onto the
-- existing department/workflow seeding. Same idempotency guard as the
-- rest of the function (skipped if departments/workflow_stages
-- already exist for this tenant).
create or replace function public.seed_tenant_defaults(p_tenant_id uuid, p_industry_template text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_dept_cost_control uuid;
  v_dept_procurement uuid;
  v_dept_finance uuid;
  v_dept_pmo uuid;
  v_dept_it uuid;
  v_dept_hr uuid;
  v_dept_law uuid;
  v_dept_bd uuid;
  v_stage_cce uuid;
  v_stage_ccm uuid;
  v_stage_offer uuid;
  v_stage_chief uuid;
  v_stage_finance uuid;
  v_stage_pm uuid;
  v_stage_dgm uuid;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can seed tenant defaults';
  end if;

  -- Idempotency guards -- do nothing if this tenant already has either.
  if exists (select 1 from departments where tenant_id = p_tenant_id)
     or exists (select 1 from workflow_stages where tenant_id = p_tenant_id) then
    return;
  end if;

  -- ── Departments ──────────────────────────────────────────────────
  insert into departments (tenant_id, name) values (p_tenant_id, 'Cost Control')
    returning id into v_dept_cost_control;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Procurement & Logistics')
    returning id into v_dept_procurement;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Finance & Financial Reporting')
    returning id into v_dept_finance;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Project Management Office')
    returning id into v_dept_pmo;
  insert into departments (tenant_id, name) values (p_tenant_id, 'IT Support')
    returning id into v_dept_it;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Human Resources')
    returning id into v_dept_hr;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Law & Compliance')
    returning id into v_dept_law;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Business Development')
    returning id into v_dept_bd;

  if p_industry_template = 'construction' then
    insert into departments (tenant_id, name) values (p_tenant_id, 'Machine Operations');
    insert into departments (tenant_id, name) values (p_tenant_id, 'Sustainability & Business Excellence');
  end if;

  -- ── Workflow stages (same pipeline for every template) ──────────
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Engineer', 1, 'Cost Control Engineer')
    returning id into v_stage_cce;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Manager', 2, 'Cost Control Manager')
    returning id into v_stage_ccm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Procurement: Offer Entry', 3, 'Procurement/Logistics Expert')
    returning id into v_stage_offer;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount)
    values (p_tenant_id, 'Control Chief/Manager', 4, 'Procurement & Logistics Chief', 5000000.00)
    returning id into v_stage_chief;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Finance', 5, 'Finance Officer')
    returning id into v_stage_finance;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Project Manager', 6, 'Project Manager')
    returning id into v_stage_pm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Deputy General Manager', 7, 'Deputy General Manager')
    returning id into v_stage_dgm;

  update workflow_stages set next_stage_low_id = v_stage_ccm where id = v_stage_cce;
  update workflow_stages set next_stage_low_id = v_stage_offer where id = v_stage_ccm;
  update workflow_stages set next_stage_low_id = v_stage_chief where id = v_stage_offer;
  update workflow_stages
    set next_stage_low_id = v_stage_finance, next_stage_high_id = v_stage_pm
    where id = v_stage_chief;
  update workflow_stages set next_stage_low_id = v_stage_dgm where id = v_stage_pm;
  update workflow_stages set next_stage_low_id = v_stage_finance where id = v_stage_dgm;

  -- ── Module entitlements ─────────────────────────────────────────
  -- 'general' template: the six modules every company plausibly needs.
  -- 'construction' template: same six, plus the two construction-
  -- specific modules whose departments were just seeded above.
  insert into tenant_modules (tenant_id, module, enabled_by)
  select p_tenant_id, m.module, auth.uid()
  from (values ('hr'), ('legal'), ('bd'), ('it'), ('pmo'), ('procurement')) as m(module);

  if p_industry_template = 'construction' then
    insert into tenant_modules (tenant_id, module, enabled_by)
    values
      (p_tenant_id, 'machine_operation', auth.uid()),
      (p_tenant_id, 'sustainability', auth.uid());
  end if;
end;
$function$;

-- ── Management RPCs for the Companies Console ──────────────────────

create or replace function public.get_tenant_modules(p_tenant_id uuid)
 returns setof text
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select module from public.tenant_modules
  where tenant_id = p_tenant_id and public.is_platform_admin()
  order by module;
$function$;

-- Replace-all semantics: pass the full desired module set for the
-- tenant. Simpler for a checkbox-list UI than separate enable/disable
-- calls, and avoids partial-update races.
create or replace function public.set_tenant_modules(p_tenant_id uuid, p_modules text[])
 returns setof text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can change a company''s modules';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  delete from tenant_modules
  where tenant_id = p_tenant_id
    and module != all(coalesce(p_modules, array[]::text[]));

  insert into tenant_modules (tenant_id, module, enabled_by)
  select p_tenant_id, m, auth.uid()
  from unnest(coalesce(p_modules, array[]::text[])) as m
  on conflict (tenant_id, module) do nothing;

  return query select module from tenant_modules where tenant_id = p_tenant_id order by module;
end;
$function$;