-- hr_leave_requests_insert only ever allowed a self-service insert
-- (hr_employees.user_id = auth.uid()), unlike hr_leave_requests_select
-- and hr_leave_requests_update on the same table, which both also allow
-- HR admins/managers via has_module_role('hr', ARRAY['admin','manager']).
--
-- Found while scoping e2e/leave-request-approval.spec.ts. Two compounding
-- problems, not one:
--
-- 1. seed.sql creates exactly two hr_employees rows (Alice Anyanzwa,
--    Brian Byaruhanga) and its own comment says they are "deliberately
--    NOT @test.local login accounts -- these are just payrolled staff
--    records." No seeded login -- not even hr@test.local -- has an
--    hr_employees row with a matching user_id. Under the self-only
--    check, this means no seeded account can currently insert a leave
--    request at all.
-- 2. LeaveRequestsList.tsx's "New Leave Request" dialog lists every
--    active employee in its Employee dropdown (not just the caller's
--    own record), and the component's own code comment says "an
--    approver may also need to log one on someone's behalf" -- i.e.
--    the UI was built assuming HR/managers can file on an employee's
--    behalf. The self-only insert policy rejects that unconditionally,
--    so as built the feature doesn't work for anyone, seeded test data
--    aside.
--
-- Add the has_module_role bypass already present on this table's other
-- two policies. Self-service insert (an employee with a linked
-- hr_employees.user_id filing for themselves) is unchanged and stays in
-- place alongside it -- this only adds the HR admin/manager path back.

drop policy if exists "hr_leave_requests_insert" on "public"."hr_leave_requests";

create policy "hr_leave_requests_insert"
  on "public"."hr_leave_requests"
  as permissive
  for insert
  to public
  with check (
    (tenant_id = public.get_my_tenant_id())
    and (
      public.has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text])
      or (exists (
        select 1
        from public.hr_employees e
        where e.id = hr_leave_requests.employee_id
          and e.user_id = (select auth.uid())
      ))
    )
  );