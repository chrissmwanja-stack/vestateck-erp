DROP POLICY IF EXISTS hr_job_applications_write ON public.hr_job_applications;

CREATE POLICY hr_job_applications_write ON public.hr_job_applications
FOR ALL
USING (
  tenant_id = get_my_tenant_id()
  AND has_module_role('hr', ARRAY['admin','manager'])
)
WITH CHECK (
  tenant_id = get_my_tenant_id()
  AND has_module_role('hr', ARRAY['admin','manager'])
);
