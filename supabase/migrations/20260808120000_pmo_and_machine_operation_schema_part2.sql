-- ============================================================
-- PMO + Machine Operation schema, part 2
-- Backs the CRUD screens added in "expand remaining stubs to
-- full real CRUD" commit:
--   PMO: MilestonesList, GanttChart, ResourceAllocation
--   Machine Operation: EquipmentAssignments, DailyLogs, FuelLogs
-- Depends on part 1 (20260808080000_pmo_and_machine_operation_schema)
-- and 00_shared_infrastructure / 01_hr_module_schema.
-- ============================================================

-- ------------------------------------------------------------
-- pmo_tasks.start_date — GanttChart reads it, part 1 never added it
-- ------------------------------------------------------------
alter table public.pmo_tasks add column if not exists start_date date;

-- ============================================================
-- PMO: milestones
-- ============================================================

create table if not exists public.pmo_milestones (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  project_id uuid not null references public.pmo_projects(id) on delete cascade,
  title text not null,
  due_date date,
  completion_percent int not null default 0 check (completion_percent between 0 and 100),
  status text not null default 'pending' check (status in ('pending','in_progress','done','missed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pmo_milestones_tenant on public.pmo_milestones(tenant_id);
create index if not exists idx_pmo_milestones_project on public.pmo_milestones(project_id);

alter table public.pmo_milestones enable row level security;

create policy "pmo_milestones_select" on public.pmo_milestones
  for select using (tenant_id = public.get_my_tenant_id());
create policy "pmo_milestones_write" on public.pmo_milestones
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('pmo', array['admin','manager']));

create trigger trg_pmo_milestones_upd before update on public.pmo_milestones
  for each row execute function public.handle_updated_at_generic();

-- ============================================================
-- PMO: resource allocations (employee <-> project, capacity %)
-- ============================================================

create table if not exists public.pmo_resource_allocations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employee_id uuid references public.hr_employees(id) on delete cascade,
  project_id uuid references public.pmo_projects(id) on delete cascade,
  allocation_percent int not null default 100 check (allocation_percent between 0 and 200),
  start_date date,
  end_date date,
  status text not null default 'active' check (status in ('active','planned','completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pmo_resource_allocations_tenant on public.pmo_resource_allocations(tenant_id);
create index if not exists idx_pmo_resource_allocations_employee on public.pmo_resource_allocations(employee_id);
create index if not exists idx_pmo_resource_allocations_project on public.pmo_resource_allocations(project_id);

alter table public.pmo_resource_allocations enable row level security;

create policy "pmo_resource_allocations_select" on public.pmo_resource_allocations
  for select using (tenant_id = public.get_my_tenant_id());
create policy "pmo_resource_allocations_write" on public.pmo_resource_allocations
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('pmo', array['admin','manager']));

create trigger trg_pmo_resource_allocations_upd before update on public.pmo_resource_allocations
  for each row execute function public.handle_updated_at_generic();

-- ============================================================
-- Machine Operation: equipment assignments
-- (project_name / operator_name are free text in the UI, not FKs)
-- ============================================================

create table if not exists public.machine_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  machine_id uuid not null references public.machines(id) on delete cascade,
  project_name text,
  operator_name text,
  start_date date,
  end_date date,
  status text not null default 'active' check (status in ('active','completed','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_machine_assignments_tenant on public.machine_assignments(tenant_id);
create index if not exists idx_machine_assignments_machine on public.machine_assignments(machine_id);

alter table public.machine_assignments enable row level security;

create policy "machine_assignments_select" on public.machine_assignments
  for select using (tenant_id = public.get_my_tenant_id());
create policy "machine_assignments_write" on public.machine_assignments
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('machine_operation', array['admin','manager']));

create trigger trg_machine_assignments_upd before update on public.machine_assignments
  for each row execute function public.handle_updated_at_generic();

-- ============================================================
-- Machine Operation: daily operation logs
-- ============================================================

create table if not exists public.operation_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  machine_id uuid not null references public.machines(id) on delete cascade,
  log_date date not null,
  hours_used numeric not null check (hours_used >= 0 and hours_used <= 24),
  operator_name text,
  work_description text,
  created_at timestamptz not null default now()
);

create index if not exists idx_operation_logs_tenant on public.operation_logs(tenant_id);
create index if not exists idx_operation_logs_machine on public.operation_logs(machine_id);
create index if not exists idx_operation_logs_date on public.operation_logs(log_date);

alter table public.operation_logs enable row level security;

create policy "operation_logs_select" on public.operation_logs
  for select using (tenant_id = public.get_my_tenant_id());
create policy "operation_logs_write" on public.operation_logs
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('machine_operation', array['admin','manager']));

-- ============================================================
-- Machine Operation: fuel logs
-- ============================================================

create table if not exists public.fuel_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  machine_id uuid not null references public.machines(id) on delete cascade,
  log_date date not null,
  fuel_liters numeric not null check (fuel_liters >= 0),
  cost numeric,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists idx_fuel_logs_tenant on public.fuel_logs(tenant_id);
create index if not exists idx_fuel_logs_machine on public.fuel_logs(machine_id);
create index if not exists idx_fuel_logs_date on public.fuel_logs(log_date);

alter table public.fuel_logs enable row level security;

create policy "fuel_logs_select" on public.fuel_logs
  for select using (tenant_id = public.get_my_tenant_id());
create policy "fuel_logs_write" on public.fuel_logs
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('machine_operation', array['admin','manager']));