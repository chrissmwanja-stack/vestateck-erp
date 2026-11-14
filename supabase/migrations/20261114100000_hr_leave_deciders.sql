-- hr_leave_requests: who may decide a leave request.
--
-- Follow-up to 20261114090000, which blocked self-approval. On its own that
-- left a company with one HR person unable to approve that person's leave.
-- A request can now be decided by any of:
--
--   * an HR module admin or manager (for everyone, as before),
--   * the company admin (is_tenant_admin()),
--   * the employee's line manager (hr_employees.manager_id).
--
-- Never by the employee it belongs to, whichever of the above they are. So an
-- HR manager's request goes to another HR admin/manager, their line manager or
-- the company admin, and a boss's own request goes to HR or the company admin.
--
-- SELECT changes with it. A request nobody can see cannot be decided, and until
-- now only HR and the owner could see leave requests, so a line manager or the
-- company admin would have had nothing to approve. They now see the requests
-- they may decide (a line manager: their direct reports').
--
-- hr_employees_select is tenant-wide, so the line-manager lookup needs no
-- SECURITY DEFINER helper. is_tenant_admin() already exists and is used the same
-- way by other policies. Every branch stays inside the caller's own tenant.
-- INSERT, DELETE, the owner's own-request branch and the 'pending, no approver'
-- rule on filing are unchanged.
--
-- Roles are named explicitly (to authenticated), per MIGRATION_POLICY.md rule 10.

drop policy if exists hr_leave_requests_select on public.hr_leave_requests;
create policy hr_leave_requests_select on public.hr_leave_requests
  for select to authenticated
  using (
    tenant_id = public.get_my_tenant_id()
    and (
      public.has_module_role('hr', array['admin', 'manager'])
      or public.is_tenant_admin()
      -- the owner
      or exists (
        select 1 from public.hr_employees e
        where e.id = hr_leave_requests.employee_id
          and e.user_id = (select auth.uid())
      )
      -- the employee's line manager
      or exists (
        select 1
        from public.hr_employees e
        join public.hr_employees m on m.id = e.manager_id
        where e.id = hr_leave_requests.employee_id
          and m.user_id = (select auth.uid())
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
        (
          public.has_module_role('hr', array['admin', 'manager'])
          or public.is_tenant_admin()
          or exists (
            select 1
            from public.hr_employees e
            join public.hr_employees m on m.id = e.manager_id
            where e.id = hr_leave_requests.employee_id
              and m.user_id = (select auth.uid())
          )
        )
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
        (
          public.has_module_role('hr', array['admin', 'manager'])
          or public.is_tenant_admin()
          or exists (
            select 1
            from public.hr_employees e
            join public.hr_employees m on m.id = e.manager_id
            where e.id = hr_leave_requests.employee_id
              and m.user_id = (select auth.uid())
          )
        )
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
