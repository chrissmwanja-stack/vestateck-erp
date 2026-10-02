-- Authorization review follow-ups (2026-10-02).
--
-- 1. get_posting_account(uuid, text) and supplier_invoice_outstanding /
--    supplier_invoice_payable_now / supplier_invoice_receipt_cap are
--    SECURITY DEFINER, were executable by `authenticated`, and take a tenant id
--    or invoice id with no tenant check -- a cross-tenant read by id. They are
--    internal helpers: only SECURITY DEFINER trigger functions call them
--    (trg_post_*, check_payment_against_receipt, machine maintenance posting),
--    and the web app never calls them (ChartOfAccountsAdmin.tsx only mentions
--    get_posting_account in a comment). Triggers run as the function owner, so
--    revoking EXECUTE from API roles does not affect them.
--
-- 2. record_employee_compensation() accepted any hr_team_members row. Setting
--    salaries now also requires the HR module `manager` role
--    (platform-admin bypass preserved via has_module_role).
--
-- 3. grant_payroll_approver() / set_payroll_approver_active(): an HR admin could
--    make themselves a payroll approver. They can no longer grant or activate
--    approver status for their own user; someone else must do it. Platform-admin
--    bypass (not impersonating) is unchanged.

-- ---------------------------------------------------------------------
-- 1. Internal helpers: no direct API access
-- ---------------------------------------------------------------------
revoke execute on function public.get_posting_account(uuid, text)        from public, anon, authenticated;
revoke execute on function public.supplier_invoice_outstanding(uuid)     from public, anon, authenticated;
revoke execute on function public.supplier_invoice_payable_now(uuid)     from public, anon, authenticated;
revoke execute on function public.supplier_invoice_receipt_cap(uuid)     from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Salaries: HR team member AND HR manager
-- ---------------------------------------------------------------------
create or replace function public.record_employee_compensation(
  p_employee_id uuid,
  p_basic_salary numeric,
  p_effective_date date,
  p_contract_reference text default null,
  p_note text default null
)
returns public.hr_employee_compensation
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row hr_employee_compensation%rowtype;
  v_tenant_id uuid;
begin
  if not (is_hr_team_member() and has_module_role('hr', array['manager'])) then
    raise exception 'not authorized to record compensation';
  end if;

  select tenant_id into v_tenant_id from hr_employees where id = p_employee_id;
  if v_tenant_id is null or v_tenant_id != get_my_tenant_id() then
    raise exception 'employee not found';
  end if;

  insert into hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, contract_reference, note, created_by)
  values (v_tenant_id, p_employee_id, p_basic_salary, p_effective_date, p_contract_reference, p_note, auth.uid())
  returning * into v_row;

  return v_row;
end;
$function$;

-- ---------------------------------------------------------------------
-- 3. Payroll approvers: no self-grant
-- ---------------------------------------------------------------------
create or replace function public.grant_payroll_approver(p_user_id uuid)
returns public.payroll_approvers
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;
  if p_user_id = effective_user_id() and not platform_admin_bypass() then
    raise exception 'not authorized: you cannot grant payroll approver access to yourself';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into payroll_approvers (tenant_id, user_id, role, is_active)
  values (get_my_tenant_id(), p_user_id, 'approver', true)
  on conflict (tenant_id, user_id) do update set is_active = true
  returning * into v_row;

  return v_row;
end;
$function$;

create or replace function public.set_payroll_approver_active(p_user_id uuid, p_is_active boolean)
returns public.payroll_approvers
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;
  if p_is_active and p_user_id = effective_user_id() and not platform_admin_bypass() then
    raise exception 'not authorized: you cannot activate payroll approver access for yourself';
  end if;

  update payroll_approvers
  set is_active = p_is_active
  where user_id = p_user_id and tenant_id = get_my_tenant_id()
  returning * into v_row;

  if not found then
    raise exception 'payroll approver not found';
  end if;

  return v_row;
end;
$function$;

-- CREATE OR REPLACE keeps existing grants; restate them so the file is
-- self-describing and cannot drift if the functions were ever dropped.
revoke execute on function public.record_employee_compensation(uuid, numeric, date, text, text) from public, anon;
grant  execute on function public.record_employee_compensation(uuid, numeric, date, text, text) to authenticated;
revoke execute on function public.grant_payroll_approver(uuid)                 from public, anon;
grant  execute on function public.grant_payroll_approver(uuid)                 to authenticated;
revoke execute on function public.set_payroll_approver_active(uuid, boolean)   from public, anon;
grant  execute on function public.set_payroll_approver_active(uuid, boolean)   to authenticated;
