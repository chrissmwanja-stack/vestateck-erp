-- Migration: Invoice approval routing (own stage chain)
--
-- Context: invoice_requests currently shares the exact same workflow_stages
-- chain as material requests, picked via "first active stage by
-- sequence_order" with no type filter. That chain includes
-- "Procurement: Offer Entry" (requires_offer_entry=true) and a Budget
-- Controller threshold check that reads request_offers.quotation_amount --
-- neither applies to invoices, which already have a known vendor/amount at
-- submission time. This migration gives invoices their own dedicated stage
-- chain within the same workflow_stages table, and the RPCs to drive it.
--
-- Decision made with Chris: separate chain via a new `applies_to` column,
-- rather than auto-skipping stages or blocking on the shared chain.

-- ============================================================
-- 1. workflow_stages: add applies_to, backfill existing rows
-- ============================================================

ALTER TABLE public.workflow_stages
  ADD COLUMN IF NOT EXISTS applies_to text NOT NULL DEFAULT 'requests'
  CHECK (applies_to IN ('requests', 'invoices'));

-- Explicit backfill for clarity (the DEFAULT already covers this, but
-- being explicit protects against a future DEFAULT change).
UPDATE public.workflow_stages
SET applies_to = 'requests'
WHERE applies_to IS NULL OR applies_to = 'requests';

-- ============================================================
-- 2. Seed a dedicated invoice stage chain per tenant
-- ============================================================
-- Mirrors the existing request chain's roles/threshold, minus the
-- offer-entry step (invoices arrive with vendor + amount already known).
-- Chain: Cost Control Engineer -> Cost Control Manager -> Budget Controller
-- (threshold on invoice_requests.amount) -> Finance (terminal) directly if
-- under threshold, or Project Manager -> General Manager -> Finance if over.
--
-- NOTE: these roles/threshold are starting defaults mirrored from the
-- existing request chain -- adjust to taste, this isn't a fixed design.
-- Idempotent: skipped for any tenant that already has an invoice chain,
-- so this is safe to re-run and will auto-seed future tenants too.

DO $$
DECLARE
  t record;
  v_engineer_id uuid;
  v_manager_id uuid;
  v_budget_id uuid;
  v_finance_id uuid;
  v_pm_id uuid;
  v_gm_id uuid;
BEGIN
  FOR t IN SELECT id FROM tenants LOOP
    IF EXISTS (
      SELECT 1 FROM workflow_stages
      WHERE tenant_id = t.id AND applies_to = 'invoices'
    ) THEN
      CONTINUE;
    END IF;

    v_engineer_id := gen_random_uuid();
    v_manager_id  := gen_random_uuid();
    v_budget_id   := gen_random_uuid();
    v_finance_id  := gen_random_uuid();
    v_pm_id       := gen_random_uuid();
    v_gm_id       := gen_random_uuid();

    INSERT INTO workflow_stages
      (id, tenant_id, name, sequence_order, approver_role, threshold_amount,
       next_stage_low_id, next_stage_high_id, requires_offer_entry,
       blocks_offer_submitter_approval, is_finance_terminal_stage, is_active,
       applies_to)
    VALUES
      (v_engineer_id, t.id, 'Cost Control Engineer', 1, 'Cost Control Engineer',
       NULL, v_manager_id, NULL, false, false, false, true, 'invoices'),
      (v_manager_id, t.id, 'Cost Control Manager', 2, 'Cost Control Manager',
       NULL, v_budget_id, NULL, false, false, false, true, 'invoices'),
      (v_budget_id, t.id, 'Budget Controller', 3, 'Cost Control Manager',
       5000000.00, v_finance_id, v_pm_id, false, false, false, true, 'invoices'),
      (v_finance_id, t.id, 'Finance', 4, 'Finance Officer',
       NULL, NULL, NULL, false, false, true, true, 'invoices'),
      (v_pm_id, t.id, 'Project Manager', 5, 'Project Manager',
       NULL, v_gm_id, NULL, false, false, false, true, 'invoices'),
      (v_gm_id, t.id, 'General Manager', 6, 'Deputy General Manager',
       NULL, v_finance_id, NULL, false, false, false, true, 'invoices');
  END LOOP;
END;
$$;

-- ============================================================
-- 3. Fix stage-selection triggers to respect applies_to
-- ============================================================
-- Both triggers previously picked "first active stage by sequence_order"
-- with no type filter -- now that the table holds two chains, both need
-- an explicit filter or they could cross into the wrong chain.

CREATE OR REPLACE FUNCTION public.set_invoice_request_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_initial_stage_id uuid;
  v_department_id     uuid;
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  SELECT department_id INTO v_department_id
  FROM app_users
  WHERE id = auth.uid();

  IF v_department_id IS NULL THEN
    RAISE EXCEPTION 'your account has no department assigned -- ask an admin to set one before submitting an invoice';
  END IF;

  NEW.department_id := v_department_id;

  SELECT id INTO v_initial_stage_id
  FROM workflow_stages
  WHERE tenant_id = NEW.tenant_id AND is_active AND applies_to = 'invoices'
  ORDER BY sequence_order ASC
  LIMIT 1;

  IF v_initial_stage_id IS NULL THEN
    RAISE EXCEPTION 'no active invoice workflow stages configured for this tenant';
  END IF;

  NEW.current_stage_id := v_initial_stage_id;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_request_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_initial_stage_id uuid;
  v_department_id     uuid;
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  SELECT department_id INTO v_department_id
  FROM app_users
  WHERE id = auth.uid();

  IF v_department_id IS NULL THEN
    RAISE EXCEPTION 'your account has no department assigned -- ask an admin to set one before submitting a request';
  END IF;

  NEW.department_id := v_department_id;

  SELECT id INTO v_initial_stage_id
  FROM workflow_stages
  WHERE tenant_id = NEW.tenant_id AND is_active AND applies_to = 'requests'
  ORDER BY sequence_order ASC
  LIMIT 1;

  IF v_initial_stage_id IS NULL THEN
    RAISE EXCEPTION 'no active workflow stages configured for this tenant';
  END IF;

  NEW.current_stage_id := v_initial_stage_id;

  RETURN NEW;
END;
$function$;

-- ============================================================
-- 4. approval_actions: support invoice-typed rows
-- ============================================================

ALTER TABLE public.approval_actions
  ALTER COLUMN request_id DROP NOT NULL;

ALTER TABLE public.approval_actions
  ADD COLUMN IF NOT EXISTS invoice_request_id uuid REFERENCES public.invoice_requests(id);

ALTER TABLE public.approval_actions
  DROP CONSTRAINT IF EXISTS approval_actions_exactly_one_target;

ALTER TABLE public.approval_actions
  ADD CONSTRAINT approval_actions_exactly_one_target CHECK (
    (request_id IS NOT NULL AND invoice_request_id IS NULL)
    OR (request_id IS NULL AND invoice_request_id IS NOT NULL)
  );

DROP POLICY IF EXISTS approval_actions_select_tenant ON public.approval_actions;
CREATE POLICY approval_actions_select_tenant
ON public.approval_actions
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM requests r
    WHERE r.id = approval_actions.request_id
      AND r.tenant_id = get_my_tenant_id()
  )
  OR EXISTS (
    SELECT 1 FROM invoice_requests ir
    WHERE ir.id = approval_actions.invoice_request_id
      AND ir.tenant_id = get_my_tenant_id()
  )
);

-- ============================================================
-- 5. notifications: support invoice-typed rows
-- ============================================================
-- request_id and purchase_order_id are already nullable/optional here, so
-- no CHECK constraint is added -- invoice_request_id simply joins the set
-- of optional references a notification can carry.

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS invoice_request_id uuid REFERENCES public.invoice_requests(id);

-- ============================================================
-- 5b. Close the audit-trail bypass on invoice_requests
-- ============================================================
-- The requests table intentionally has NO UPDATE policy -- all status/stage
-- changes go exclusively through record_approval_decision() (a SECURITY
-- DEFINER function, which bypasses RLS internally). The earlier
-- invoice_requests_update_actionable policy let anyone with stage access
-- flip status directly, with no approval_actions row written. Dropping it
-- so invoices follow the same rule: writes only via the audited RPC.

DROP POLICY IF EXISTS invoice_requests_update_actionable ON public.invoice_requests;

-- ============================================================
-- 6. record_invoice_approval_decision RPC
-- ============================================================
-- Mirrors record_approval_decision(), simplified for invoices: no offer
-- lookup (uses invoice_requests.amount directly for threshold branching),
-- no purchase order generation on the terminal stage.

CREATE OR REPLACE FUNCTION public.record_invoice_approval_decision(
  p_invoice_request_id uuid,
  p_decision text,
  p_comment text DEFAULT NULL,
  p_acting_on_behalf_of uuid DEFAULT NULL
)
RETURNS TABLE(out_invoice_request_id uuid, out_status text, out_stage_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_invoice       invoice_requests%rowtype;
  v_stage         workflow_stages%rowtype;
  v_next_stage    workflow_stages%rowtype;
  v_next_stage_id uuid;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid decision: %', p_decision;
  END IF;

  SELECT * INTO v_invoice FROM invoice_requests WHERE id = p_invoice_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invoice request not found';
  END IF;
  IF v_invoice.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this invoice request';
  END IF;
  IF v_invoice.status != 'open' THEN
    RAISE EXCEPTION 'invoice request is not open (status: %)', v_invoice.status;
  END IF;
  IF v_invoice.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'invoice request has no current stage';
  END IF;
  IF NOT can_act_on_stage(v_invoice.current_stage_id) THEN
    RAISE EXCEPTION 'not authorized to act on this stage';
  END IF;

  -- Submitter-block: the person who submitted the invoice may never
  -- approve/reject it themself, at any stage (belt-and-suspenders with the
  -- equivalent RLS policy, since this SECURITY DEFINER function does not
  -- go through RLS on its own).
  IF v_invoice.requester_id = auth.uid() THEN
    RAISE EXCEPTION 'you submitted this invoice -- a different reviewer must act on it';
  END IF;

  SELECT * INTO v_stage FROM workflow_stages WHERE id = v_invoice.current_stage_id;

  INSERT INTO approval_actions
    (invoice_request_id, workflow_stage_id, approver_id, acted_on_behalf_of, decision, comment)
  VALUES
    (p_invoice_request_id, v_stage.id, auth.uid(), p_acting_on_behalf_of, p_decision, p_comment);

  IF p_decision = 'rejected' THEN
    UPDATE invoice_requests SET status = 'rejected', updated_at = now() WHERE id = p_invoice_request_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    VALUES (
      v_invoice.tenant_id,
      v_invoice.requester_id,
      'invoice_rejected',
      'Invoice rejected',
      format('Your invoice for "%s" (%s) was rejected at the %s stage.', v_invoice.vendor_name, v_invoice.amount, v_stage.name),
      p_invoice_request_id
    );

    RETURN QUERY SELECT p_invoice_request_id, 'rejected'::text, v_stage.id;
    RETURN;
  END IF;

  IF v_stage.is_finance_terminal_stage THEN
    UPDATE invoice_requests
    SET status = 'closed', current_stage_id = NULL, updated_at = now()
    WHERE id = p_invoice_request_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    VALUES (
      v_invoice.tenant_id,
      v_invoice.requester_id,
      'invoice_closed',
      'Invoice closed',
      format('Your invoice for "%s" (%s) has been fully approved and closed.', v_invoice.vendor_name, v_invoice.amount),
      p_invoice_request_id
    );

    RETURN QUERY SELECT p_invoice_request_id, 'closed'::text, NULL::uuid;
    RETURN;
  END IF;

  IF v_stage.threshold_amount IS NOT NULL THEN
    IF v_invoice.amount <= v_stage.threshold_amount THEN
      v_next_stage_id := v_stage.next_stage_low_id;
    ELSE
      v_next_stage_id := v_stage.next_stage_high_id;
    END IF;
  ELSE
    v_next_stage_id := v_stage.next_stage_low_id;
  END IF;

  IF v_next_stage_id IS NULL THEN
    RAISE EXCEPTION 'stage % has no next stage configured', v_stage.name;
  END IF;

  SELECT * INTO v_next_stage FROM workflow_stages WHERE id = v_next_stage_id;

  IF v_next_stage.applies_to != 'invoices' THEN
    RAISE EXCEPTION 'stage % is not configured for the invoice workflow -- check workflow_stages config', v_next_stage.name;
  END IF;

  UPDATE invoice_requests
  SET current_stage_id = v_next_stage_id, updated_at = now()
  WHERE id = p_invoice_request_id;

  INSERT INTO notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
  SELECT DISTINCT
    v_invoice.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('An invoice for "%s" (%s) is awaiting your approval at the %s stage.', v_invoice.vendor_name, v_invoice.amount, v_next_stage.name),
    p_invoice_request_id
  FROM (
    SELECT aa.user_id AS recipient_id
    FROM approval_assignments aa
    WHERE aa.workflow_stage_id = v_next_stage_id

    UNION

    SELECT d.delegate_user_id AS recipient_id
    FROM approval_delegations d
    JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
    WHERE d.status = 'active'
      AND now() BETWEEN d.starts_at AND d.ends_at
      AND aa.workflow_stage_id = v_next_stage_id
      AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  RETURN QUERY SELECT p_invoice_request_id, 'open'::text, v_next_stage_id;
END;
$function$;

-- ============================================================
-- 7. get_my_invoice_approval_queue RPC
-- ============================================================
-- Parallel to get_my_approval_queue(), purpose-built for invoices rather
-- than forced into the requests function's mismatched column shape
-- (item_description/quantity/latest_offer/purchase_order don't apply here).

CREATE OR REPLACE FUNCTION public.get_my_invoice_approval_queue()
RETURNS TABLE(
  id uuid, tenant_id uuid, requester_id uuid, department_id uuid,
  cost_center_id uuid, current_stage_id uuid, vendor_name text,
  description text, amount numeric, status text, created_at timestamptz,
  department jsonb, requester jsonb, current_stage jsonb,
  acting_on_behalf_of jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH my_tenant AS (
    SELECT tenant_id FROM app_users WHERE id = auth.uid()
  ),
  direct_stages AS (
    SELECT workflow_stage_id, NULL::uuid AS delegator_user_id
    FROM approval_assignments
    WHERE user_id = auth.uid()
  ),
  delegated_stages AS (
    SELECT COALESCE(d.workflow_stage_id, aa.workflow_stage_id) AS workflow_stage_id,
           d.delegator_user_id
    FROM approval_delegations d
    JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
    WHERE d.delegate_user_id = auth.uid()
      AND d.status = 'active'
      AND now() BETWEEN d.starts_at AND d.ends_at
      AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = aa.workflow_stage_id)
  ),
  my_stages AS (
    SELECT * FROM direct_stages
    UNION ALL
    SELECT * FROM delegated_stages
  )
  SELECT
    ir.id, ir.tenant_id, ir.requester_id, ir.department_id, ir.cost_center_id,
    ir.current_stage_id, ir.vendor_name, ir.description, ir.amount, ir.status, ir.created_at,
    jsonb_build_object('id', dept.id, 'name', dept.name) AS department,
    jsonb_build_object('id', req.id, 'name', req.name) AS requester,
    jsonb_build_object(
      'id', ws.id,
      'name', ws.name,
      'approver_role', ws.approver_role,
      'threshold_amount', ws.threshold_amount,
      'is_finance_terminal_stage', ws.is_finance_terminal_stage
    ) AS current_stage,
    CASE WHEN ms.delegator_user_id IS NOT NULL
      THEN jsonb_build_object('id', delegator.id, 'name', delegator.name)
      ELSE NULL
    END AS acting_on_behalf_of
  FROM invoice_requests ir
  JOIN my_stages ms ON ms.workflow_stage_id = ir.current_stage_id
  LEFT JOIN departments dept ON dept.id = ir.department_id
  JOIN app_users req ON req.id = ir.requester_id
  JOIN workflow_stages ws ON ws.id = ir.current_stage_id
  LEFT JOIN app_users delegator ON delegator.id = ms.delegator_user_id
  WHERE ir.status = 'open'
    AND ir.tenant_id = (SELECT tenant_id FROM my_tenant)
  ORDER BY ir.created_at ASC;
$function$;