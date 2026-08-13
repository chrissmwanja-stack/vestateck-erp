-- Security fix: set an immutable search_path on the 6 document-number
-- trigger functions added since the Aug 8 batch fix
-- (fix_mutable_search_path_on_27_functions). Same pattern -- these are
-- plain trigger functions calling public.next_doc_number(), so pinning
-- search_path to 'public' is a pure hardening change with no behavior
-- difference.

ALTER FUNCTION public.generate_pmo_project_no() SET search_path = 'public';
ALTER FUNCTION public.generate_machine_no() SET search_path = 'public';
ALTER FUNCTION public.generate_bd_lead_no() SET search_path = 'public';
ALTER FUNCTION public.generate_bd_opportunity_no() SET search_path = 'public';
ALTER FUNCTION public.generate_bd_proposal_no() SET search_path = 'public';
ALTER FUNCTION public.generate_bd_tender_no() SET search_path = 'public';