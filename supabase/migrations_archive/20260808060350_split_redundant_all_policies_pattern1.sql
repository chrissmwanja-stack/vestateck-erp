-- Performance fix: 10 tables each had an ALL-command "_write" policy whose
-- condition (tenant match + module role) is a strict subset of the broader
-- "_select" policy's condition (tenant match only). That meant every SELECT
-- was evaluating two permissive policies when the broader one alone already
-- covers every row the narrower one would. Splitting "_write" into
-- INSERT/UPDATE/DELETE removes the redundant implicit SELECT grant.
-- No permission changes: every USING/WITH CHECK expression is preserved
-- verbatim, just scoped to the commands that actually need it.

-- hr_employees: split ALL policy 'hr_employees_write' into INSERT/UPDATE/DELETE
DROP POLICY hr_employees_write ON public.hr_employees;
CREATE POLICY hr_employees_insert ON public.hr_employees
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY hr_employees_update ON public.hr_employees
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY hr_employees_delete ON public.hr_employees
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  );

-- hr_job_applications: split ALL policy 'hr_job_applications_write' into INSERT/UPDATE/DELETE
DROP POLICY hr_job_applications_write ON public.hr_job_applications;
CREATE POLICY hr_job_applications_insert ON public.hr_job_applications
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY hr_job_applications_update ON public.hr_job_applications
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY hr_job_applications_delete ON public.hr_job_applications
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text, 'manager'::text]))
  );

-- hr_job_postings: split ALL policy 'hr_job_postings_write' into INSERT/UPDATE/DELETE
DROP POLICY hr_job_postings_write ON public.hr_job_postings;
CREATE POLICY hr_job_postings_insert ON public.hr_job_postings
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );
CREATE POLICY hr_job_postings_update ON public.hr_job_postings
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );
CREATE POLICY hr_job_postings_delete ON public.hr_job_postings
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );

-- hr_leave_types: split ALL policy 'hr_leave_types_write' into INSERT/UPDATE/DELETE
DROP POLICY hr_leave_types_write ON public.hr_leave_types;
CREATE POLICY hr_leave_types_insert ON public.hr_leave_types
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );
CREATE POLICY hr_leave_types_update ON public.hr_leave_types
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );
CREATE POLICY hr_leave_types_delete ON public.hr_leave_types
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );

-- hr_positions: split ALL policy 'hr_positions_write' into INSERT/UPDATE/DELETE
DROP POLICY hr_positions_write ON public.hr_positions;
CREATE POLICY hr_positions_insert ON public.hr_positions
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );
CREATE POLICY hr_positions_update ON public.hr_positions
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );
CREATE POLICY hr_positions_delete ON public.hr_positions
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('hr'::text, ARRAY['admin'::text]))
  );

-- law_case_types: split ALL policy 'law_case_types_write' into INSERT/UPDATE/DELETE
DROP POLICY law_case_types_write ON public.law_case_types;
CREATE POLICY law_case_types_insert ON public.law_case_types
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  );
CREATE POLICY law_case_types_update ON public.law_case_types
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  );
CREATE POLICY law_case_types_delete ON public.law_case_types
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  );

-- law_cases: split ALL policy 'law_cases_write' into INSERT/UPDATE/DELETE
DROP POLICY law_cases_write ON public.law_cases;
CREATE POLICY law_cases_insert ON public.law_cases
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY law_cases_update ON public.law_cases
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY law_cases_delete ON public.law_cases
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  );

-- law_contract_types: split ALL policy 'law_contract_types_write' into INSERT/UPDATE/DELETE
DROP POLICY law_contract_types_write ON public.law_contract_types;
CREATE POLICY law_contract_types_insert ON public.law_contract_types
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  );
CREATE POLICY law_contract_types_update ON public.law_contract_types
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  );
CREATE POLICY law_contract_types_delete ON public.law_contract_types
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text]))
  );

-- law_contracts: split ALL policy 'law_contracts_write' into INSERT/UPDATE/DELETE
DROP POLICY law_contracts_write ON public.law_contracts;
CREATE POLICY law_contracts_insert ON public.law_contracts
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY law_contracts_update ON public.law_contracts
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  );
CREATE POLICY law_contracts_delete ON public.law_contracts
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND has_module_role('legal'::text, ARRAY['admin'::text, 'manager'::text]))
  );

-- staff_roles: split ALL policy 'platform_admin_write_staff_roles' into INSERT/UPDATE/DELETE
DROP POLICY platform_admin_write_staff_roles ON public.staff_roles;
CREATE POLICY staff_roles_insert ON public.staff_roles
  FOR INSERT
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM app_users
  WHERE ((app_users.id = (select auth.uid())) AND app_users.is_platform_admin))))
  );
CREATE POLICY staff_roles_update ON public.staff_roles
  FOR UPDATE
  USING (
    ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM app_users
  WHERE ((app_users.id = (select auth.uid())) AND app_users.is_platform_admin))))
  )
  WITH CHECK (
    ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM app_users
  WHERE ((app_users.id = (select auth.uid())) AND app_users.is_platform_admin))))
  );
CREATE POLICY staff_roles_delete ON public.staff_roles
  FOR DELETE
  USING (
    ((tenant_id = get_my_tenant_id()) AND (EXISTS ( SELECT 1
   FROM app_users
  WHERE ((app_users.id = (select auth.uid())) AND app_users.is_platform_admin))))
  );
