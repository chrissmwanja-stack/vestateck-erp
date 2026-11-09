-- hr_employee_compensation_select was the only RLS policy in the schema
-- still calling auth.uid() unwrapped, causing it to be re-evaluated per
-- row instead of once per query (Supabase performance advisor:
-- auth_rls_initplan). Every other policy already uses (select auth.uid()).
-- Same USING clause, just the initplan-friendly form.
drop policy if exists hr_employee_compensation_select on public.hr_employee_compensation;

create policy hr_employee_compensation_select on public.hr_employee_compensation
for select
using (
  (tenant_id = get_my_tenant_id())
  and (
    is_hr_team_member()
    or exists (
      select 1 from hr_employees e
      where e.id = hr_employee_compensation.employee_id
        and e.user_id = (select auth.uid())
    )
  )
);