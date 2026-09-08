CREATE OR REPLACE FUNCTION public.approve_payroll_run(p_run_id uuid)
 RETURNS hr_payroll_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_payroll_approver() THEN
    RAISE EXCEPTION 'not authorized to approve payroll';
  END IF;

  UPDATE hr_payroll_runs
  SET status = 'approved', approved_by = auth.uid(), approved_at = now()
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'pending_approval'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not pending approval';
  END IF;

  IF v_row.prepared_by IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body)
    VALUES (
      v_row.tenant_id,
      v_row.prepared_by,
      'payroll_run_approved',
      'Payroll run approved: ' || v_row.period,
      format('The %s payroll run has been approved.', v_row.period)
    );
  END IF;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_payroll_run(p_run_id uuid, p_reason text)
 RETURNS hr_payroll_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_payroll_approver() THEN
    RAISE EXCEPTION 'not authorized to reject payroll';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a rejection reason is required';
  END IF;

  -- Sent back to draft (not a separate 'rejected' limbo) so HR can fix
  -- and resubmit through the same path -- rejected_* columns keep the
  -- audit trail of the fact it happened.
  UPDATE hr_payroll_runs
  SET status = 'draft', rejected_by = auth.uid(), rejected_at = now(), rejection_reason = p_reason,
      submitted_at = NULL
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'pending_approval'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not pending approval';
  END IF;

  IF v_row.prepared_by IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body)
    VALUES (
      v_row.tenant_id,
      v_row.prepared_by,
      'payroll_run_rejected',
      'Payroll run rejected: ' || v_row.period,
      format('The %s payroll run was rejected. Reason: %s', v_row.period, p_reason)
    );
  END IF;

  RETURN v_row;
END;
$function$;
