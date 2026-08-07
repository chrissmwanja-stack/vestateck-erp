CREATE TABLE public.hr_job_applications (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tenant_id uuid NOT NULL,
  job_posting_id uuid REFERENCES public.hr_job_postings(id) ON DELETE SET NULL,
  candidate_name text NOT NULL,
  email text,
  phone text,
  stage text NOT NULL DEFAULT 'applied',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX hr_job_applications_tenant_id_idx ON public.hr_job_applications(tenant_id);
CREATE INDEX hr_job_applications_job_posting_id_idx ON public.hr_job_applications(job_posting_id);

ALTER TABLE public.hr_job_applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY hr_job_applications_select ON public.hr_job_applications
  FOR SELECT
  USING (tenant_id = get_my_tenant_id());

CREATE POLICY hr_job_applications_write ON public.hr_job_applications
  FOR ALL
  USING (tenant_id = get_my_tenant_id() AND has_module_role('hr', ARRAY['admin']))
  WITH CHECK (tenant_id = get_my_tenant_id() AND has_module_role('hr', ARRAY['admin']));
