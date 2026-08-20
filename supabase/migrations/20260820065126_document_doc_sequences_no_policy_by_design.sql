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
---
-- Supabase's security advisor flags this table as "RLS enabled, no
-- policy" (INFO level). That's intentional, not a gap: doc_sequences
-- is only ever written to via next_doc_number(), a SECURITY DEFINER
-- function that bypasses RLS by design. With RLS on and zero
-- policies, anon/authenticated get zero rows if they ever query it
-- directly -- the correct default-deny outcome. Documenting this so
-- it doesn't get "fixed" with an unnecessary permissive policy later.
comment on table public.doc_sequences is
  'Per-tenant document numbering counters (MR/PO/etc). Written only via next_doc_number() (SECURITY DEFINER), which bypasses RLS by design. Intentionally has RLS enabled with no policies -- direct table access from anon/authenticated should return zero rows.';