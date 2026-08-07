create extension if not exists "pgcrypto";

-- Positions (lookup)
create table if not exists public.hr_positions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  title text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, title)
);

-- Leave Types
create table if not exists public.hr_leave_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  days_per_year int not null default 21,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, name)
);

-- Employees
create table if not exists public.hr_employees (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  user_id uuid references public.app_users(id) on delete set null,
  employee_no text not null,
  first_name text not null,
  last_name text not null,
  email text not null,
  phone text,
  department_id uuid references public.departments(id) on delete set null,
  position_id uuid references public.hr_positions(id) on delete set null,
  manager_id uuid references public.hr_employees(id) on delete set null,
  employment_status text not null default 'active' check (employment_status in ('active','on_leave','terminated','resigned')),
  hire_date date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, employee_no),
  unique (tenant_id, email)
);

-- Attendance
create table if not exists public.hr_attendance (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employee_id uuid not null references public.hr_employees(id) on delete cascade,
  attendance_date date not null,
  check_in timestamptz,
  check_out timestamptz,
  status text not null default 'present' check (status in ('present','absent','late','on_leave')),
  notes text,
  created_at timestamptz not null default now(),
  unique (tenant_id, employee_id, attendance_date)
);

-- Leave Requests
create table if not exists public.hr_leave_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  leave_no text not null,
  employee_id uuid not null references public.hr_employees(id) on delete cascade,
  leave_type_id uuid not null references public.hr_leave_types(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  days int not null,
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  approver_id uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, leave_no)
);

-- Job Postings
create table if not exists public.hr_job_postings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  title text not null,
  department_id uuid references public.departments(id) on delete set null,
  position_id uuid references public.hr_positions(id) on delete set null,
  description text,
  status text not null default 'open' check (status in ('open','closed','on_hold')),
  created_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_hr_positions_tenant on public.hr_positions(tenant_id);
create index if not exists idx_hr_leave_types_tenant on public.hr_leave_types(tenant_id);
create index if not exists idx_hr_employees_tenant on public.hr_employees(tenant_id);
create index if not exists idx_hr_employees_user on public.hr_employees(user_id);
create index if not exists idx_hr_employees_department on public.hr_employees(department_id);
create index if not exists idx_hr_employees_manager on public.hr_employees(manager_id);
create index if not exists idx_hr_attendance_tenant on public.hr_attendance(tenant_id);
create index if not exists idx_hr_attendance_employee on public.hr_attendance(employee_id);
create index if not exists idx_hr_leave_requests_tenant on public.hr_leave_requests(tenant_id);
create index if not exists idx_hr_leave_requests_employee on public.hr_leave_requests(employee_id);
create index if not exists idx_hr_job_postings_tenant on public.hr_job_postings(tenant_id);

-- RLS enable
alter table public.hr_positions enable row level security;
alter table public.hr_leave_types enable row level security;
alter table public.hr_employees enable row level security;
alter table public.hr_attendance enable row level security;
alter table public.hr_leave_requests enable row level security;
alter table public.hr_job_postings enable row level security;

create policy "hr_positions_select" on public.hr_positions
  for select using (tenant_id = public.get_my_tenant_id());
create policy "hr_positions_write" on public.hr_positions
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('hr', array['admin']));

create policy "hr_leave_types_select" on public.hr_leave_types
  for select using (tenant_id = public.get_my_tenant_id());
create policy "hr_leave_types_write" on public.hr_leave_types
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('hr', array['admin']));

create policy "hr_employees_select" on public.hr_employees
  for select using (tenant_id = public.get_my_tenant_id());
create policy "hr_employees_write" on public.hr_employees
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('hr', array['admin','manager']));

create policy "hr_job_postings_select" on public.hr_job_postings
  for select using (tenant_id = public.get_my_tenant_id());
create policy "hr_job_postings_write" on public.hr_job_postings
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('hr', array['admin']));

create policy "hr_attendance_select" on public.hr_attendance
  for select using (
    tenant_id = public.get_my_tenant_id() and (
      public.has_module_role('hr', array['admin','manager'])
      or exists (select 1 from public.hr_employees e where e.id = hr_attendance.employee_id and e.user_id = auth.uid())
    )
  );
create policy "hr_attendance_insert" on public.hr_attendance
  for insert with check (
    tenant_id = public.get_my_tenant_id() and (
      public.has_module_role('hr', array['admin','manager'])
      or exists (select 1 from public.hr_employees e where e.id = hr_attendance.employee_id and e.user_id = auth.uid())
    )
  );
create policy "hr_attendance_update" on public.hr_attendance
  for update using (
    tenant_id = public.get_my_tenant_id() and public.has_module_role('hr', array['admin','manager'])
  );

create policy "hr_leave_requests_select" on public.hr_leave_requests
  for select using (
    tenant_id = public.get_my_tenant_id() and (
      public.has_module_role('hr', array['admin','manager'])
      or exists (select 1 from public.hr_employees e where e.id = hr_leave_requests.employee_id and e.user_id = auth.uid())
    )
  );
create policy "hr_leave_requests_insert" on public.hr_leave_requests
  for insert with check (
    tenant_id = public.get_my_tenant_id()
    and exists (select 1 from public.hr_employees e where e.id = hr_leave_requests.employee_id and e.user_id = auth.uid())
  );
create policy "hr_leave_requests_update" on public.hr_leave_requests
  for update using (
    tenant_id = public.get_my_tenant_id() and (
      public.has_module_role('hr', array['admin','manager'])
      or (
        status = 'pending'
        and exists (select 1 from public.hr_employees e where e.id = hr_leave_requests.employee_id and e.user_id = auth.uid())
      )
    )
  );

-- Auto employee_no / leave_no via shared sequence function
create or replace function public.generate_hr_employee_no()
returns trigger language plpgsql as $$
begin
  NEW.employee_no := public.next_doc_number(NEW.tenant_id, 'hr_employee', 'HR-EMP');
  return NEW;
end;
$$;
create trigger trg_hr_emp_no before insert on public.hr_employees
  for each row execute function public.generate_hr_employee_no();

create or replace function public.generate_hr_leave_no()
returns trigger language plpgsql as $$
begin
  NEW.leave_no := public.next_doc_number(NEW.tenant_id, 'hr_leave', 'HR-LV');
  return NEW;
end;
$$;
create trigger trg_hr_leave_no before insert on public.hr_leave_requests
  for each row execute function public.generate_hr_leave_no();

create trigger trg_hr_emp_upd before update on public.hr_employees
  for each row execute function public.handle_updated_at_generic();
create trigger trg_hr_leave_upd before update on public.hr_leave_requests
  for each row execute function public.handle_updated_at_generic();
