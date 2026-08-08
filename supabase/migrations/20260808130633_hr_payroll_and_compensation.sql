-- ============================================================
-- HR Payroll and Compensation module
-- Recovered/as-built migration: this was applied directly to
-- Supabase via the SQL editor in an earlier session and never
-- saved locally. Reconstructed by introspecting the live schema
-- so local history matches supabase_migrations.schema_migrations
-- (version 20260808130633).
--
-- Backs: hr/pages/payroll/PayrollList.tsx, CompensationHistory.tsx,
-- PayrollApprovals.tsx, and features/financial/PayrollDisbursement.tsx.
--
-- Flow: draft -> pending_approval -> approved -> disbursed (or rejected,
-- which sends the run back to draft with an audit trail).
-- Membership in hr_team_members / payroll_approvers is a pure
-- platform-admin decision per tenant -- same pattern as
-- finance_team_members. The same person can be in both tables.
-- ============================================================

-- ------------------------------------------------------------
-- 0. HR team membership + payroll approver membership
--    (mirrors finance_team_members from platform_admin_and_finance_team)
-- ------------------------------------------------------------
create table if not exists public.hr_team_members (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references public.app_users(id),
  role text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.payroll_approvers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references public.app_users(id),
  role text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, user_id)
);

alter table public.hr_team_members enable row level security;
alter table public.payroll_approvers enable row level security;

create policy hr_team_members_select on public.hr_team_members
  for select using (tenant_id = get_my_tenant_id());

create policy payroll_approvers_select on public.payroll_approvers
  for select using (tenant_id = get_my_tenant_id());

create or replace function public.is_hr_team_member(p_role text default null)
returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select
    is_platform_admin()
    or exists (
      select 1 from hr_team_members
      where user_id = auth.uid()
        and tenant_id = get_my_tenant_id()
        and (p_role is null or role = p_role)
    );
$$;

create or replace function public.is_payroll_approver()
returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select
    is_platform_admin()
    or exists (
      select 1 from payroll_approvers
      where user_id = auth.uid()
        and tenant_id = get_my_tenant_id()
        and is_active
    );
$$;

-- ------------------------------------------------------------
-- 1. Compensation history
-- ------------------------------------------------------------
create table public.hr_employee_compensation (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid not null references public.hr_employees(id) on delete cascade,
  basic_salary numeric not null check (basic_salary >= 0),
  currency text not null default 'UGX',
  effective_date date not null,
  contract_reference text,
  note text,
  created_by uuid not null references public.app_users(id),
  created_at timestamptz not null default now()
);

alter table public.hr_employee_compensation enable row level security;

create policy hr_employee_compensation_select on public.hr_employee_compensation
  for select using (tenant_id = get_my_tenant_id());

-- Latest effective compensation row per employee, as of today.
create or replace view public.hr_employee_current_compensation as
select distinct on (employee_id)
  employee_id, tenant_id, basic_salary, currency, effective_date, contract_reference
from public.hr_employee_compensation
where effective_date <= current_date
order by employee_id, effective_date desc, created_at desc;

-- ------------------------------------------------------------
-- 2. Payroll runs and items
-- ------------------------------------------------------------
create table public.hr_payroll_runs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  period text not null,
  status text not null default 'draft'
    check (status in ('draft', 'pending_approval', 'approved', 'rejected', 'disbursed')),
  prepared_by uuid not null references public.app_users(id),
  submitted_at timestamptz,
  approved_by uuid references public.app_users(id),
  approved_at timestamptz,
  rejected_by uuid references public.app_users(id),
  rejected_at timestamptz,
  rejection_reason text,
  amount_disbursed numeric not null default 0,
  created_at timestamptz not null default now(),
  unique (tenant_id, period)
);

create table public.hr_payroll_items (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid not null references public.hr_payroll_runs(id) on delete cascade,
  employee_id uuid not null references public.hr_employees(id),
  basic_salary numeric not null check (basic_salary >= 0),
  allowances numeric not null default 0 check (allowances >= 0),
  deductions numeric not null default 0 check (deductions >= 0),
  net_pay numeric generated always as (basic_salary + allowances - deductions) stored,
  note text,
  unique (payroll_run_id, employee_id)
);

alter table public.hr_payroll_runs enable row level security;
alter table public.hr_payroll_items enable row level security;

create policy hr_payroll_runs_select on public.hr_payroll_runs
  for select using (tenant_id = get_my_tenant_id());

create policy hr_payroll_items_select on public.hr_payroll_items
  for select using (
    exists (
      select 1 from hr_payroll_runs pr
      where pr.id = hr_payroll_items.payroll_run_id
        and pr.tenant_id = get_my_tenant_id()
    )
  );

-- No insert/update/delete policies -- all writes go through the
-- SECURITY DEFINER RPCs below, matching the procurement/finance pattern.

-- ------------------------------------------------------------
-- 3. RPCs: HR-side run builder
-- ------------------------------------------------------------
create or replace function public.create_payroll_run(p_period text)
returns hr_payroll_runs
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_run hr_payroll_runs%rowtype;
begin
  if not is_hr_team_member() then
    raise exception 'not authorized to prepare payroll';
  end if;

  insert into hr_payroll_runs (tenant_id, period, prepared_by)
  values (get_my_tenant_id(), p_period, auth.uid())
  returning * into v_run;

  return v_run;
end;
$$;

create or replace function public.generate_payroll_items(p_run_id uuid)
returns setof hr_payroll_items
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_run hr_payroll_runs%rowtype;
begin
  if not is_hr_team_member() then
    raise exception 'not authorized to prepare payroll';
  end if;

  select * into v_run from hr_payroll_runs where id = p_run_id and tenant_id = get_my_tenant_id();
  if not found then
    raise exception 'payroll run not found';
  end if;
  if v_run.status != 'draft' then
    raise exception 'can only generate items while the run is in draft';
  end if;

  return query
  insert into hr_payroll_items (payroll_run_id, employee_id, basic_salary)
  select p_run_id, e.id, cc.basic_salary
  from hr_employees e
  join hr_employee_current_compensation cc on cc.employee_id = e.id
  where e.tenant_id = get_my_tenant_id()
    and e.is_active
    and not exists (select 1 from hr_payroll_items i where i.payroll_run_id = p_run_id and i.employee_id = e.id)
  on conflict (payroll_run_id, employee_id) do nothing
  returning *;
end;
$$;

create or replace function public.update_payroll_item(
  p_item_id uuid, p_allowances numeric, p_deductions numeric, p_note text default null
)
returns hr_payroll_items
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_row hr_payroll_items%rowtype;
begin
  if not is_hr_team_member() then
    raise exception 'not authorized to edit payroll';
  end if;

  update hr_payroll_items i
  set allowances = p_allowances, deductions = p_deductions, note = p_note
  from hr_payroll_runs r
  where i.id = p_item_id
    and r.id = i.payroll_run_id
    and r.tenant_id = get_my_tenant_id()
    and r.status = 'draft'
  returning i.* into v_row;

  if v_row.id is null then
    raise exception 'payroll item not found, or run is no longer in draft';
  end if;

  return v_row;
end;
$$;

create or replace function public.submit_payroll_run(p_run_id uuid)
returns hr_payroll_runs
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_row hr_payroll_runs%rowtype;
begin
  if not is_hr_team_member() then
    raise exception 'not authorized to submit payroll';
  end if;

  if not exists (select 1 from hr_payroll_items where payroll_run_id = p_run_id) then
    raise exception 'cannot submit a payroll run with no line items';
  end if;

  update hr_payroll_runs
  set status = 'pending_approval', submitted_at = now()
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'draft'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'payroll run not found, or not in draft';
  end if;

  return v_row;
end;
$$;

-- ------------------------------------------------------------
-- 4. RPCs: PM/GM-side approvals
-- ------------------------------------------------------------
create or replace function public.approve_payroll_run(p_run_id uuid)
returns hr_payroll_runs
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_row hr_payroll_runs%rowtype;
begin
  if not is_payroll_approver() then
    raise exception 'not authorized to approve payroll';
  end if;

  update hr_payroll_runs
  set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'pending_approval'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'payroll run not found, or not pending approval';
  end if;

  return v_row;
end;
$$;

create or replace function public.reject_payroll_run(p_run_id uuid, p_reason text)
returns hr_payroll_runs
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_row hr_payroll_runs%rowtype;
begin
  if not is_payroll_approver() then
    raise exception 'not authorized to reject payroll';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a rejection reason is required';
  end if;

  -- Sent back to draft (not a separate 'rejected' limbo) so HR can fix
  -- and resubmit through the same path -- rejected_* columns keep the
  -- audit trail of the fact it happened.
  update hr_payroll_runs
  set status = 'draft', rejected_by = auth.uid(), rejected_at = now(), rejection_reason = p_reason,
      submitted_at = null
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'pending_approval'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'payroll run not found, or not pending approval';
  end if;

  return v_row;
end;
$$;

-- ------------------------------------------------------------
-- 5. Finance-side disbursement guard
--    Fires on cash_bank_transactions inserts with
--    reference_type = 'payroll_run'. Blocks disbursing a run that
--    isn't approved yet, blocks paying out more than the run's total
--    net pay, and auto-advances the run to 'disbursed' once the
--    cumulative amount_disbursed covers the full net pay. Supports
--    partial disbursements along the way.
-- ------------------------------------------------------------
create or replace function public.check_payroll_disbursement()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_run hr_payroll_runs%rowtype;
  v_total_net numeric;
begin
  if new.reference_type != 'payroll_run' or new.transaction_type != 'payment' then
    return new;
  end if;

  select * into v_run from hr_payroll_runs where id = new.reference_id;
  if not found then
    return new;
  end if;

  if v_run.status not in ('approved', 'disbursed') then
    raise exception 'payroll run must be approved before it can be disbursed';
  end if;

  select coalesce(sum(net_pay), 0) into v_total_net from hr_payroll_items where payroll_run_id = v_run.id;

  if v_run.amount_disbursed + new.amount > v_total_net + 0.01 then
    raise exception
      'payment blocked: run total is %, already disbursed %, this payment %',
      round(v_total_net, 2), round(v_run.amount_disbursed, 2), new.amount;
  end if;

  update hr_payroll_runs
  set amount_disbursed = amount_disbursed + new.amount,
      status = case when amount_disbursed + new.amount >= v_total_net - 0.01 then 'disbursed' else 'approved' end
  where id = v_run.id;

  return new;
end;
$$;

create trigger trg_check_payroll_disbursement
  before insert on public.cash_bank_transactions
  for each row execute function public.check_payroll_disbursement();
