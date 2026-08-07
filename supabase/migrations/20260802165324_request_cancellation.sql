-- Migration: request_cancellation
-- Depends on: 20260801120200_request_department_and_po_edit
--
-- Adds a cancellation path for open requests (MR not fulfilled / no
-- longer needed) -- deliberately scoped to status = 'open' only, since
-- 'closed' requests already have a live purchase_order (per
-- record_approval_decision) and voiding an issued PO is a heavier,
-- separate flow, not in scope here. Authorized callers: the original
-- requester, or whoever can currently act on the request's stage
-- (approval_assignments / active delegation, same authority
-- record_approval_decision already uses via can_act_on_stage()).

-- ---------------------------------------------------------------------
-- 1. New terminal status
-- ---------------------------------------------------------------------
ALTER TABLE requests DROP CONSTRAINT requests_status_check;
ALTER TABLE requests ADD CONSTRAINT requests_status_check
  CHECK (status = ANY (ARRAY['open'::text, 'rejected'::text, 'closed'::text, 'cancelled'::text]));

-- ---------------------------------------------------------------------
-- 2. Cancel RPC
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_request(
  p_request_id uuid,
  p_reason text
)
RETURNS TABLE (out_request_id uuid, out_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_request      requests%ROWTYPE;
  v_is_requester boolean;
  v_can_act      boolean;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a reason is required to cancel a request';
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'request not found';
  END IF;
  IF v_request.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this request';
  END IF;
  IF v_request.status != 'open' THEN
    RAISE EXCEPTION 'only open requests can be cancelled (status: %)', v_request.status;
  END IF;

  v_is_requester := v_request.requester_id = auth.uid();
  v_can_act := v_request.current_stage_id IS NOT NULL AND can_act_on_stage(v_request.current_stage_id);

  IF NOT (v_is_requester OR v_can_act) THEN
    RAISE EXCEPTION 'not authorized to cancel this request';
  END IF;

  -- Audit trail, reusing approval_actions rather than a new table --
  -- same shape as an approve/reject decision, just a different
  -- decision value.
  INSERT INTO approval_actions
    (request_id, workflow_stage_id, approver_id, decision, comment)
  VALUES
    (p_request_id, v_request.current_stage_id, auth.uid(), 'cancelled', p_reason);

  UPDATE requests
  SET status = 'cancelled', current_stage_id = NULL, updated_at = now()
  WHERE id = p_request_id;

  IF v_is_requester THEN
    -- Requester withdrew it -- notify whoever currently held it.
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    SELECT DISTINCT
      v_request.tenant_id,
      recipient_id,
      'request_cancelled',
      'Request withdrawn',
      format('Request "%s" was withdrawn by the requester: %s', v_request.item_description, p_reason),
      p_request_id
    FROM (
      SELECT aa.user_id AS recipient_id
      FROM approval_assignments aa
      WHERE aa.workflow_stage_id = v_request.current_stage_id

      UNION

      SELECT d.delegate_user_id AS recipient_id
      FROM approval_delegations d
      JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
      WHERE d.status = 'active'
        AND now() BETWEEN d.starts_at AND d.ends_at
        AND aa.workflow_stage_id = v_request.current_stage_id
        AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = v_request.current_stage_id)
    ) recipients;
  ELSE
    -- An approver/assignee cancelled it -- notify the requester.
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    VALUES (
      v_request.tenant_id,
      v_request.requester_id,
      'request_cancelled',
      'Request cancelled',
      format('Your request "%s" was cancelled: %s', v_request.item_description, p_reason),
      p_request_id
    );
  END IF;

  RETURN QUERY SELECT p_request_id, 'cancelled'::text;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_request(uuid, text) TO authenticated;
