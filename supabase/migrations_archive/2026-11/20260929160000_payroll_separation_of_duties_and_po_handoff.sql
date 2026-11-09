create or replace function public.approve_payroll_run(p_run_id uuid)
 returns public.hr_payroll_runs language plpgsql security definer set search_path to 'public' as $function$
declare v_row hr_payroll_runs%rowtype;
begin
  if not is_payroll_approver() then raise exception 'not authorized to approve payroll'; end if;
  if exists (select 1 from hr_payroll_runs where id = p_run_id and tenant_id = get_my_tenant_id()
             and prepared_by = effective_user_id()) then
    raise exception 'the preparer of a payroll run cannot approve it';
  end if;
  update hr_payroll_runs set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'pending_approval' returning * into v_row;
  if v_row.id is null then raise exception 'payroll run not found, or not pending approval'; end if;
  if v_row.prepared_by is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (v_row.tenant_id, v_row.prepared_by, 'payroll_run_approved', 'Payroll run approved: ' || v_row.period,
            format('The %s payroll run has been approved.', v_row.period));
  end if;
  return v_row;
end; $function$;

create or replace function public.can_manage_po_handoff(p_purchase_order_id uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_request_id uuid; v_sub uuid; v_me uuid := public.effective_user_id();
begin
  select request_id into v_request_id from purchase_orders where id = p_purchase_order_id;
  if v_request_id is null then return false; end if;
  select submitted_by into v_sub from request_offers where request_id = v_request_id and is_selected limit 1;
  if v_sub = v_me then return true; end if;
  return has_po_access();
end; $$;