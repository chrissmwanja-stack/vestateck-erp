-- Route-level guard for the finance/admin screens that currently sit under
-- <RequireAuth/> with no module check at all (any authenticated tenant user
-- can reach /financial-management/*, /finance/purchase-orders, /admin/accounts,
-- etc). Two independent, pre-existing access concepts already gate the
-- underlying data for these screens and neither alone covers all of them:
--
--   1. is_finance_team_member() -- membership in finance_team_members table.
--      Gates: supplier_invoices, cash_bank_transactions, receivable_invoices,
--      expenditure_slips, petty_cash_floats, accounts, account_categories,
--      material_receipt_assignments (via assign/revoke_receipt_access).
--
--   2. has_po_access() / am_i_finance() -- true if assigned as approver (or
--      active delegate) at the terminal "Finance" workflow stage, or platform
--      admin. Gates: purchase_orders (finance stage), cost_centers writes,
--      sap_payments, and is called directly client-side by
--      OrganizationsAdmin/WarehousesAdmin/MaterialLookupsAdmin/
--      AccountCategoriesAdmin/CostCodeListNew via rpc('am_i_finance').
--
-- can_access_finance() is the OR of both, so the new RequireFinanceTeam route
-- guard doesn't lock out either group. It intentionally does NOT replace
-- either underlying RLS check -- those stay as-is; this function exists only
-- to answer "should the nav/route even render" for the frontend guard.
create or replace function public.can_access_finance()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select public.has_po_access() or public.is_finance_team_member(NULL);
$function$;

grant execute on function public.can_access_finance() to authenticated, service_role;
revoke execute on function public.can_access_finance() from anon, public;