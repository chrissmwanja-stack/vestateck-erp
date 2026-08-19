-- am_i_finance() is the client-side UI gate called directly by 10 admin
-- screens (AccountCategoriesAdmin, OrganizationsAdmin, WarehousesAdmin,
-- MaterialLookupsAdmin, CostCodeListNew, DepartmentsAdmin,
-- ProcurementInfo, ProcurementTrack, MaterialRequestApproval,
-- MaterialQuantity) to decide whether to render finance-only forms.
--
-- It was defined as just has_po_access() -- true only for platform
-- admins and terminal-stage PO workflow approvers/delegates. It never
-- accounted for finance_team_members, even though that's exactly what
-- backs the RLS on account_categories/organizations/etc (see
-- 20260816133611_add_can_access_finance_route_guard_fn's comment, which
-- documented this split but only fixed the route-level guard via the
-- new can_access_finance(), not am_i_finance() itself).
--
-- Net effect of the bug: someone invited with finance_role='finance'
-- (finance_team_members) could pass every RLS check but still see
-- "managed by Finance" gate messages on these screens, because the
-- client-side am_i_finance() check didn't know finance_team_members
-- existed.
--
-- am_i_finance() is never referenced by any RLS policy or other
-- function -- only called directly from the frontend -- so widening it
-- to match can_access_finance()'s logic is safe and fixes all 10 call
-- sites without touching the frontend.
create or replace function public.am_i_finance()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select public.can_access_finance();
$function$;