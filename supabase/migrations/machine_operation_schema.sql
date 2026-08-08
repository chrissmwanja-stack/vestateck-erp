-- ============================================================
-- PMO + Machine Operation module schema
-- Backs the already-built frontend screens:
--   PMO: PMODashboard, ProjectsList, NewProject, TasksList,
--        ProjectCategoriesAdmin, TaskTypesAdmin
--   Machine Operation: MachineDashboard, EquipmentList,
--        MaintenanceRequests, MachineTypesAdmin, MaintenanceTypesAdmin
-- Depends on 00_shared_infrastructure (get_my_tenant_id,
-- has_module_role, staff_roles, next_doc_number).
-- ============================================================

-- ------------------------------------------------------------
-- 0. Extend staff_roles module check constraint
-- ------------------------------------------------------------
alter table public.staff_roles drop constraint if exists staff_roles_module_check;
alter table public.staff_roles add constraint staff_roles_module_check
  check (module in ('hr','legal','bd','it','pmo','machine_operation'));

-- ============================================================
-- PMO
-- ============================================================

create table if not exists public.pmo_project_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create table if not exists public.pmo_task_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create table if not exists public.pmo_projects (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  project_no text not null,
  name text not null,
  category_id uuid references public.pmo_project_categories(id) on delete set null,
  client_name text,
  status text not null default 'not_started' check (status in ('not_started','in_progress','on_hold','completed','cancelled')),
  budget numeric,
  currency text not null default 'USD',
  start_date date,
  end_date date,
  manager_id uuid references public.app_users(id) on delete set null,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, project_no)
);

create table if not exists public.pmo_tasks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  project_id uuid references public.pmo_projects(id) on delete cascade,
  title text not null,
  type_id uuid references public.pmo_task_types(id) on delete set null,
  status text not null default 'todo' check (status in ('todo','in_progress','review','done')),
  priority text not null default 'medium' check (priority in ('low','medium','high','critical')),
  assignee_id uuid references public.app_users(id) on delete set null,
  due_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_pmo_project_categories_tenant on public.pmo_project_categories(tenant_id);
create index if not exists idx_pmo_task_types_tenant on public.pmo_task_types(tenant_id);
create index if not exists idx_pmo_projects_tenant on public.pmo_projects(tenant_id);
create index if not exists idx_pmo_projects_category on public.pmo_projects(category_id);
create index if not exists idx_pmo_tasks_tenant on public.pmo_tasks(tenant_id);
create index if not exists idx_pmo_tasks_project on public.pmo_tasks(project_id);
create index if not exists idx_pmo_tasks_type on public.pmo_tasks(type_id);

-- RLS
alter table public.pmo_project_categories enable row level security;
alter table public.pmo_task_types enable row level security;
alter table public.pmo_projects enable row level security;
alter table public.pmo_tasks enable row level security;

create policy "pmo_project_categories_select" on public.pmo_project_categories
  for select using (tenant_id = public.get_my_tenant_id());
create policy "pmo_project_categories_write" on public.pmo_project_categories
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('pmo', array['admin']));

create policy "pmo_task_types_select" on public.pmo_task_types
  for select using (tenant_id = public.get_my_tenant_id());
create policy "pmo_task_types_write" on public.pmo_task_types
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('pmo', array['admin']));

create policy "pmo_projects_select" on public.pmo_projects
  for select using (tenant_id = public.get_my_tenant_id());
create policy "pmo_projects_write" on public.pmo_projects
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('pmo', array['admin','manager']));

create policy "pmo_tasks_select" on public.pmo_tasks
  for select using (tenant_id = public.get_my_tenant_id());
create policy "pmo_tasks_write" on public.pmo_tasks
  for all using (
    tenant_id = public.get_my_tenant_id()
    and (
      public.has_module_role('pmo', array['admin','manager'])
      or assignee_id = auth.uid()
    )
  );

-- Auto project_no via shared doc-numbering (matches "PMO-P-2026-0001" in the UI)
create or replace function public.generate_pmo_project_no()
returns trigger language plpgsql as $$
begin
  NEW.project_no := public.next_doc_number(NEW.tenant_id, 'pmo_project', 'PMO-P');
  return NEW;
end;
$$;
create trigger trg_pmo_project_no before insert on public.pmo_projects
  for each row execute function public.generate_pmo_project_no();

create trigger trg_pmo_projects_upd before update on public.pmo_projects
  for each row execute function public.handle_updated_at_generic();
create trigger trg_pmo_tasks_upd before update on public.pmo_tasks
  for each row execute function public.handle_updated_at_generic();

-- ============================================================
-- Machine Operation
-- ============================================================

create table if not exists public.machine_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create table if not exists public.maintenance_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

create table if not exists public.machines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  machine_no text not null,
  name text not null,
  type_id uuid references public.machine_types(id) on delete set null,
  model text,
  serial_number text,
  status text not null default 'available' check (status in ('available','in_use','maintenance','retired','breakdown')),
  location text,
  purchase_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, machine_no)
);

create table if not exists public.maintenance_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  machine_id uuid not null references public.machines(id) on delete cascade,
  type text not null check (type in ('preventive','corrective','inspection')),
  description text not null,
  status text not null default 'scheduled' check (status in ('scheduled','in_progress','completed','cancelled')),
  requested_by uuid references public.app_users(id) on delete set null,
  scheduled_date date,
  completed_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_machine_types_tenant on public.machine_types(tenant_id);
create index if not exists idx_maintenance_types_tenant on public.maintenance_types(tenant_id);
create index if not exists idx_machines_tenant on public.machines(tenant_id);
create index if not exists idx_machines_type on public.machines(type_id);
create index if not exists idx_maintenance_requests_tenant on public.maintenance_requests(tenant_id);
create index if not exists idx_maintenance_requests_machine on public.maintenance_requests(machine_id);

-- RLS
alter table public.machine_types enable row level security;
alter table public.maintenance_types enable row level security;
alter table public.machines enable row level security;
alter table public.maintenance_requests enable row level security;

create policy "machine_types_select" on public.machine_types
  for select using (tenant_id = public.get_my_tenant_id());
create policy "machine_types_write" on public.machine_types
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('machine_operation', array['admin']));

create policy "maintenance_types_select" on public.maintenance_types
  for select using (tenant_id = public.get_my_tenant_id());
create policy "maintenance_types_write" on public.maintenance_types
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('machine_operation', array['admin']));

create policy "machines_select" on public.machines
  for select using (tenant_id = public.get_my_tenant_id());
create policy "machines_write" on public.machines
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('machine_operation', array['admin','manager']));

create policy "maintenance_requests_select" on public.maintenance_requests
  for select using (tenant_id = public.get_my_tenant_id());
create policy "maintenance_requests_write" on public.maintenance_requests
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('machine_operation', array['admin','manager']));

-- Auto machine_no via shared doc-numbering
create or replace function public.generate_machine_no()
returns trigger language plpgsql as $$
begin
  NEW.machine_no := public.next_doc_number(NEW.tenant_id, 'machine', 'MCH');
  return NEW;
end;
$$;
create trigger trg_machine_no before insert on public.machines
  for each row execute function public.generate_machine_no();

create trigger trg_machines_upd before update on public.machines
  for each row execute function public.handle_updated_at_generic();
create trigger trg_maintenance_requests_upd before update on public.maintenance_requests
  for each row execute function public.handle_updated_at_generic();