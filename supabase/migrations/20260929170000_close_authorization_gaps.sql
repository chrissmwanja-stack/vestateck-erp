-- Closes the three GAP notices reported by supabase/tests/security_authorization.sql.
--
--   1. set_staff_module_role accepted a role in a module the tenant has not
--      enabled (inert until enabled, then silently active). Now refused.
--   2. staff_roles write policies checked the raw app_users.is_platform_admin
--      flag, so a user-level View-as session still wrote the table directly
--      even though every RPC treated it as the impersonated user. They now
--      use platform_admin_bypass() (platform admin NOT viewing as a user).
--   3. hr_payroll_runs did not record who a platform admin was acting as.
--      It now stores effective_user_id and impersonation_session_id for the
--      latest approve/reject decision, matching approval_actions.

-- 1 ------------------------------------------------------------------
create or replace function public.set_staff_module_role(p_user_id uuid, p_module text, p_role text)
returns public.staff_roles
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row public.staff_roles%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage team access';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;
  if not exists (select 1 from tenant_modules where tenant_id = get_my_tenant_id() and module = p_module) then
    raise exception 'module % is not enabled for this tenant', p_module
      using errcode = 'check_violation';
  end if;

  insert into staff_roles (tenant_id, user_id, module, role)
  values (get_my_tenant_id(), p_user_id, p_module, p_role)
  on conflict (tenant_id, user_id, module) do update set role = excluded.role
  returning * into v_row;

  return v_row;
end;
$function$;

-- 2 ------------------------------------------------------------------
drop policy if exists "staff_roles_insert" on public.staff_roles;
drop policy if exists "staff_roles_update" on public.staff_roles;
drop policy if exists "staff_roles_delete" on public.staff_roles;

create policy "staff_roles_insert" on public.staff_roles
  as permissive for insert to public
  with check (tenant_id = (select public.get_my_tenant_id()) and (select public.platform_admin_bypass()));

create policy "staff_roles_update" on public.staff_roles
  as permissive for update to public
  using (tenant_id = (select public.get_my_tenant_id()) and (select public.platform_admin_bypass()))
  with check (tenant_id = (select public.get_my_tenant_id()) and (select public.platform_admin_bypass()));

create policy "staff_roles_delete" on public.staff_roles
  as permissive for delete to public
  using (tenant_id = (select public.get_my_tenant_id()) and (select public.platform_admin_bypass()));

-- 3 ------------------------------------------------------------------
alter table public.hr_payroll_runs
  add column if not exists effective_user_id uuid references public.app_users(id) on delete set null,
  add column if not exists impersonation_session_id uuid references public.impersonation_sessions(id) on delete set null;

comment on column public.hr_payroll_runs.effective_user_id is
  'Whose permissions applied when the run was last approved/rejected (the impersonated user during View-as, otherwise the actor). approved_by/rejected_by hold the real actor.';
comment on column public.hr_payroll_runs.impersonation_session_id is
  'impersonation_sessions row active when the run was last approved/rejected, if any.';

create index if not exists hr_payroll_runs_effective_user_idx on public.hr_payroll_runs (effective_user_id) where effective_user_id is not null;
create index if not exists hr_payroll_runs_impersonation_session_idx on public.hr_payroll_runs (impersonation_session_id) where impersonation_session_id is not null;

create or replace function public.approve_payroll_run(p_run_id uuid)
returns public.hr_payroll_runs
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row       hr_payroll_runs%rowtype;
  v_effective uuid := effective_user_id();
  v_session   uuid;
begin
  if not is_payroll_approver() then
    raise exception 'not authorized to approve payroll';
  end if;
  if exists (select 1 from hr_payroll_runs where id = p_run_id and tenant_id = get_my_tenant_id()
             and prepared_by = v_effective) then
    raise exception 'the preparer of a payroll run cannot approve it';
  end if;

  select id into v_session from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null and expires_at > now()
  order by started_at desc limit 1;

  update hr_payroll_runs
  set status = 'approved', approved_by = auth.uid(), approved_at = now(),
      effective_user_id = v_effective, impersonation_session_id = v_session
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'pending_approval'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'payroll run not found, or not pending approval';
  end if;

  if v_row.prepared_by is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (v_row.tenant_id, v_row.prepared_by, 'payroll_run_approved', 'Payroll run approved: ' || v_row.period,
            format('The %s payroll run has been approved.', v_row.period));
  end if;

  return v_row;
end;
$function$;

create or replace function public.reject_payroll_run(p_run_id uuid, p_reason text)
returns public.hr_payroll_runs
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row       hr_payroll_runs%rowtype;
  v_effective uuid := effective_user_id();
  v_session   uuid;
begin
  if not is_payroll_approver() then
    raise exception 'not authorized to reject payroll';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a rejection reason is required';
  end if;

  select id into v_session from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null and expires_at > now()
  order by started_at desc limit 1;

  update hr_payroll_runs
  set status = 'rejected', rejected_by = auth.uid(), rejected_at = now(), rejection_reason = p_reason,
      effective_user_id = v_effective, impersonation_session_id = v_session
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'pending_approval'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'payroll run not found, or not pending approval';
  end if;

  if v_row.prepared_by is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (v_row.tenant_id, v_row.prepared_by, 'payroll_run_rejected', 'Payroll run rejected: ' || v_row.period,
            format('The %s payroll run was rejected. Reason: %s', v_row.period, p_reason));
  end if;

  return v_row;
end;
$function$;

-- A revised run is a fresh draft: the decision attribution goes with the rejection fields.
create or replace function public.revise_payroll_run(p_run_id uuid)
returns public.hr_payroll_runs
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row hr_payroll_runs%rowtype;
begin
  if not is_hr_team_member() then
    raise exception 'not authorized: HR team membership required';
  end if;

  update hr_payroll_runs
  set status = 'draft', rejected_by = null, rejected_at = null, rejection_reason = null,
      effective_user_id = null, impersonation_session_id = null
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'rejected'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'payroll run not found, or not in rejected status';
  end if;

  return v_row;
end;
$function$;
