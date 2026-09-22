-- reject_payroll_run() has sent a rejected run straight back to 'draft'
-- since the Aug 19 baseline ("Sent back to draft (not a separate
-- 'rejected' limbo) so HR can fix and resubmit through the same path").
-- That decision was never reflected outside the RPC's own comment:
--   * hr_payroll_runs_status_check already allows 'rejected' as a value
--     (squashed_baseline.sql) -- the schema was built to support it
--   * PayrollList.tsx's statusColor map still carries a
--     rejected: "error" entry that was, until now, unreachable dead code
--   * apps/web/e2e/payroll-approval-reject.spec.ts (added today,
--     b45e4f1) asserts a distinct "rejected" chip appears for HR after
--     an approver rejects a run -- which the 'draft' bounce can never
--     produce
--
-- This migration makes rejection a real, visible status instead of an
-- invisible bounce back to draft:
--   1. reject_payroll_run() now sets status = 'rejected' (keeping
--      rejected_by/rejected_at/rejection_reason as before) instead of
--      silently returning the run to 'draft'.
--   2. New revise_payroll_run(p_run_id) -- HR-only -- moves a rejected
--      run back to 'draft' so it can be edited and resubmitted, clearing
--      the rejected_by/rejected_at/rejection_reason fields since they
--      describe a decision HR is now revising away from.
--
-- apps/web/src/modules/portals/hr/pages/payroll/PayrollList.tsx needs a
-- matching change: an explicit "Revise" action (calling
-- revise_payroll_run) shown on rejected runs for HR, since editing/
-- submit are still gated on status === 'draft'.

CREATE OR REPLACE FUNCTION public.reject_payroll_run(p_run_id uuid, p_reason text)
 RETURNS public.hr_payroll_runs
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

  UPDATE hr_payroll_runs
  SET status = 'rejected', rejected_by = auth.uid(), rejected_at = now(), rejection_reason = p_reason
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

-- HR-only: move a rejected run back to draft so it can be edited and
-- resubmitted. Clears the rejection fields -- they describe a decision
-- that's now being revised, not a fact about the fresh draft.
CREATE OR REPLACE FUNCTION public.revise_payroll_run(p_run_id uuid)
 RETURNS public.hr_payroll_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized: HR team membership required';
  END IF;

  UPDATE hr_payroll_runs
  SET status = 'draft', rejected_by = NULL, rejected_at = NULL, rejection_reason = NULL
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'rejected'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not in rejected status';
  END IF;

  RETURN v_row;
END;
$function$;

ALTER FUNCTION public.revise_payroll_run(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.revise_payroll_run(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revise_payroll_run(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.revise_payroll_run(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revise_payroll_run(uuid) TO service_role;

COMMENT ON FUNCTION public.revise_payroll_run(uuid) IS
  'Moves a rejected payroll run back to draft for editing/resubmission. HR team members only; same-tenant only.';