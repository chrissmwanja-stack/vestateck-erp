-- Security fix: lock down search_path on all functions the advisor flagged as mutable.
-- Setting to 'public, pg_temp' closes the schema-injection vector (an attacker-controlled
-- schema earlier in a caller's search_path could otherwise shadow object references)
-- while preserving existing unqualified references to public-schema tables, so no
-- function body needs to change.

-- SECURITY DEFINER functions (highest priority: privilege-escalation vector)
ALTER FUNCTION public.get_my_procurement_orders() SET search_path = public, pg_temp;
ALTER FUNCTION public.is_finance_team_member(p_role text) SET search_path = public, pg_temp;
ALTER FUNCTION public.is_platform_admin() SET search_path = public, pg_temp;

-- Trigger / helper functions
ALTER FUNCTION public.generate_hr_employee_no() SET search_path = public, pg_temp;
ALTER FUNCTION public.generate_hr_leave_no() SET search_path = public, pg_temp;
ALTER FUNCTION public.generate_law_case_no() SET search_path = public, pg_temp;
ALTER FUNCTION public.generate_law_compliance_no() SET search_path = public, pg_temp;
ALTER FUNCTION public.generate_law_contract_no() SET search_path = public, pg_temp;
ALTER FUNCTION public.handle_updated_at_generic() SET search_path = public, pg_temp;
ALTER FUNCTION public.prevent_invoice_organization_change() SET search_path = public, pg_temp;
ALTER FUNCTION public.protect_delegation_immutable_fields() SET search_path = public, pg_temp;
ALTER FUNCTION public.protect_po_immutable_fields() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_account_category_defaults() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_asset_tag() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_cost_center_defaults() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_department_defaults() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_material_lookup_defaults() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_material_request_batch_defaults() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_material_request_item_defaults() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_organization_defaults() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_problem_number() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_proposal_number() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_request_mr_number() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_tender_number() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_ticket_number() SET search_path = public, pg_temp;
ALTER FUNCTION public.submit_request_with_line_items(
  p_item_description text, p_quantity integer, p_cost_center_id uuid,
  p_delivery_date date, p_subcontractor text, p_line_items jsonb
) SET search_path = public, pg_temp;
ALTER FUNCTION public.touch_updated_at() SET search_path = public, pg_temp;
