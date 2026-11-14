-- hr_leave_requests: two decisions on the HR leave workflow.
--
-- 1. HR may file a leave request on an employee's behalf.
--    The leave screen has always offered "New Leave Request" for any employee
--    (its comment says an approver may need to log one for someone else), but
--    the INSERT policy only allowed the employee's own record, so that action
--    failed. INSERT now also allows an HR module admin/manager to file for any
--    employee in their own tenant. The filed request must still be 'pending'
--    with no approver, so the approval step cannot be skipped by filing.
--
-- 2. Nobody approves or rejects their own leave request, HR manager included.
--    Payroll already blocks self-approval; leave now does too. In the UPDATE
--    policy the HR admin/manager branch no longer applies when the request
--    belongs to the caller's own employee record. USING covers the old row and
--    WITH CHECK covers the new row, so re-pointing employee_id at (or away
--    from) the caller's own record does not get around it. A request by an HR
--    manager can therefore only be decided by another HR admin/manager.
--
-- Unchanged: the employee's own-request branch (pending, no approver), the
-- tenant checks, SELECT and DELETE. The web app already sends status 'pending'
-- with no approver_id.
--
-- Roles are named explicitly (to authenticated), per MIGRATION_POLICY.md rule 10.

drop policy if exists hr_leave_requests_insert on public.hr_leave_requests;
create policy hr_leave_requests_insert on public.hr_leave_requests
  for insert to authenticated
  with check (
    tenant_id = public.get_my_tenant_id()
    and status = 'pending'
    and approver_id is null
    and (
      -- the employee, for their own record
      exists (
        select 1 from public.hr_employees e
        where e.id = hr_leave_requests.employee_id
          and e.user_id = (select auth.uid())
      )
      -- or HR, on behalf of any employee in the same tenant
      or (
        public.has_module_role('hr', array['admin', 'manager'])
        and exists (
          select 1 from public.hr_employees e
          where e.id = hr_leave_requests.employee_id
            and e.tenant_id = hr_leave_requests.tenant_id
        )
      )
    )
  );

drop policy if exists hr_leave_requests_update on public.hr_leave_requests;
create policy hr_leave_requests_update on public.hr_leave_requests
  for update to authenticated
  using (
    tenant_id = public.get_my_tenant_id()
    and (
      (
        public.has_module_role('hr', array['admin', 'manager'])
        and not exists (
          select 1 from public.hr_employees e
          where e.id = hr_leave_requests.employee_id
            and e.user_id = (select auth.uid())
        )
      )
      or (
        status = 'pending'
        and approver_id is null
        and exists (
          select 1 from public.hr_employees e
          where e.id = hr_leave_requests.employee_id
            and e.user_id = (select auth.uid())
        )
      )
    )
  )
  with check (
    tenant_id = public.get_my_tenant_id()
    and (
      (
        public.has_module_role('hr', array['admin', 'manager'])
        and not exists (
          select 1 from public.hr_employees e
          where e.id = hr_leave_requests.employee_id
            and e.user_id = (select auth.uid())
        )
      )
      or (
        status = 'pending'
        and approver_id is null
        and exists (
          select 1 from public.hr_employees e
          where e.id = hr_leave_requests.employee_id
            and e.user_id = (select auth.uid())
        )
      )
    )
  );
