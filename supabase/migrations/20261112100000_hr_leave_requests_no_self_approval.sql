-- hr_leave_requests: an employee could file a request that was already approved.
--
-- Found by probing as an ordinary employee (no HR role) on a seeded database:
--
--   insert into hr_leave_requests (..., status) values (..., 'approved');
--
-- succeeded. The INSERT policy checked tenant and that the row belongs to the
-- caller's own employee record, but said nothing about status or approver_id,
-- so the approval step could be skipped entirely. (A later UPDATE to 'approved'
-- was already refused, because the UPDATE policy's USING is reused as the
-- check on the new row. Only the INSERT path was open.)
--
-- The UPDATE policy had a smaller gap of the same kind: while a request was
-- pending, its owner could set approver_id to anyone, forging an approver.
--
-- Fix:
--   INSERT: the owner may only file a request that is pending and has no
--           approver. HR admin/manager decisions still go through UPDATE.
--   UPDATE: the owner's branch additionally requires approver_id is null, on
--           both the old and the new row, so it cannot be set. HR admin and
--           manager are unchanged and still record approver_id on a decision.
--
-- The web app already sends status 'pending' and no approver_id when filing a
-- request (LeaveRequestsList.tsx), so the normal flow is unaffected.
--
-- Roles are named explicitly (to authenticated), per MIGRATION_POLICY.md rule 10.

drop policy if exists hr_leave_requests_insert on public.hr_leave_requests;
create policy hr_leave_requests_insert on public.hr_leave_requests
  for insert to authenticated
  with check (
    tenant_id = public.get_my_tenant_id()
    and status = 'pending'
    and approver_id is null
    and exists (
      select 1 from public.hr_employees e
      where e.id = hr_leave_requests.employee_id
        and e.user_id = (select auth.uid())
    )
  );

drop policy if exists hr_leave_requests_update on public.hr_leave_requests;
create policy hr_leave_requests_update on public.hr_leave_requests
  for update to authenticated
  using (
    tenant_id = public.get_my_tenant_id()
    and (
      public.has_module_role('hr', array['admin', 'manager'])
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
      public.has_module_role('hr', array['admin', 'manager'])
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
