create extension if not exists "pgcrypto";

-- Appraisals (performance review cycle, per employee)
create table if not exists public.hr_appraisals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employee_id uuid not null references public.hr_employees(id) on delete cascade,
  period text not null,
  rating int check (rating between 1 and 5),
  comments text,
  status text not null default 'draft' check (status in ('draft','in_progress','completed','reviewed')),
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Trainings (employee development programs, not tied to a single employee)
create table if not exists public.hr_trainings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  title text not null,
  description text,
  provider text,
  start_date date,
  end_date date,
  status text not null default 'planned' check (status in ('planned','in_progress','completed','cancelled')),
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_hr_appraisals_tenant on public.hr_appraisals(tenant_id);
create index if not exists idx_hr_appraisals_employee on public.hr_appraisals(employee_id);
create index if not exists idx_hr_trainings_tenant on public.hr_trainings(tenant_id);

-- RLS
alter table public.hr_appraisals enable row level security;
alter table public.hr_trainings enable row level security;

create policy "hr_appraisals_select" on public.hr_appraisals
  for select using (
    tenant_id = public.get_my_tenant_id() and (
      public.has_module_role('hr', array['admin','manager'])
      or exists (select 1 from public.hr_employees e where e.id = hr_appraisals.employee_id and e.user_id = auth.uid())
    )
  );
create policy "hr_appraisals_write" on public.hr_appraisals
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('hr', array['admin','manager']));

create policy "hr_trainings_select" on public.hr_trainings
  for select using (tenant_id = public.get_my_tenant_id());
create policy "hr_trainings_write" on public.hr_trainings
  for all using (tenant_id = public.get_my_tenant_id() and public.has_module_role('hr', array['admin','manager']));

create trigger trg_hr_appraisals_upd before update on public.hr_appraisals
  for each row execute function public.handle_updated_at_generic();
create trigger trg_hr_trainings_upd before update on public.hr_trainings
  for each row execute function public.handle_updated_at_generic();
