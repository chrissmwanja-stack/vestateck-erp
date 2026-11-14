-- can_decide_leave(): may the caller decide leave requests for anyone?
--
-- Backs the Leave Approvals screen (/hr/leaves/approvals) and its sidebar entry,
-- the same way can_view_payroll_approvals() backs payroll approvals. Until now
-- that screen sat behind RequireModule module="hr", so a company admin or a line
-- manager with no HR role was blocked at the screen even though
-- 20261114100000_hr_leave_deciders.sql lets the database accept their decisions.
--
-- True for the same three groups the hr_leave_requests update policy accepts:
--
--   * an HR module admin or manager   (has_module_role('hr', admin/manager)),
--   * the company admin               (is_tenant_admin()),
--   * anyone who is the line manager of at least one employee in their tenant
--     (some hr_employees.manager_id points at their own hr_employees row).
--
-- It deliberately mirrors the policy, not is_hr_team_member(): that function
-- reads the separate hr_team_members table, which is the payroll grant. Keep
-- the two in step: test_hr_can_decide_leave.sql asserts that this function and
-- the policy agree.
--
-- This only decides whether the screen is offered. It says nothing about a
-- particular request: the policy still refuses a decision on one's own request,
-- and a line manager still only decides their own reports'.
--
-- Same identity helper as the other helpers (effective_user_id()), so "view as"
-- shows the viewed user's nav. Same platform-admin pass as has_module_role().

create or replace function public.can_decide_leave()
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select
    public.has_module_role('hr', array['admin', 'manager'])
    or public.is_tenant_admin()
    or exists (
      select 1
      from public.hr_employees m
      join public.hr_employees e on e.manager_id = m.id
      where m.user_id = public.effective_user_id()
        and m.tenant_id = public.get_my_tenant_id()
        and e.tenant_id = public.get_my_tenant_id()
    );
$$;

revoke all on function public.can_decide_leave() from public, anon;
grant execute on function public.can_decide_leave() to authenticated;
