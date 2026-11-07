-- Fix: company_accounting_settings_legal_review_guard() (20261107235901) was
-- created without a pinned search_path; test_production_invariants.sql requires
-- every public function to pin one. It is a BEFORE INSERT/UPDATE trigger
-- function and already schema-qualifies its references, so pinning is safe.
-- Also drop the default PUBLIC EXECUTE: triggers do not need it at fire time.
alter function public.company_accounting_settings_legal_review_guard()
  set search_path = public, pg_temp;
revoke all on function public.company_accounting_settings_legal_review_guard()
  from public, anon, authenticated, service_role;