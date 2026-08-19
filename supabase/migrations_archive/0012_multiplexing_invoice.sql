-- Migration: Multiplexing / Invoice Approval module
-- Reuses the existing approval framework (workflow_stages, approval_assignments,
-- approval_delegations) -- no hard-coded stage names.
--
-- This is the merged, final version of the invoice_requests setup:
--   1. Table creation (idempotent, as originally written)
--   2. RLS enabled
--   3. Defaulting trigger, FIXED to set tenant_id/requester_id server-side
--      (originally missing -- both are NOT NULL with no default, so inserts
--      from the client, which only send vendor_name/amount/description,
--      would fail on a NOT NULL violation before ever reaching RLS)
--   4. RLS policies for invoice_requests (originally missing entirely --
--      RLS was enabled with zero policies, which denies all access)
--   5. RLS policies for cost_centers (only had a SELECT policy; INSERT/UPDATE
--      were missing, so CostCodeAdmin's create/edit actions were failing)

-- ============================================================
-- 1. Table
-- ============================================================

CREATE TABLE IF NOT EXISTS public.invoice_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  requester_id uuid NOT NULL REFERENCES public.app_users(id) ON DELETE SET NULL,
  department_id uuid REFERENCES public.departments(id) ON DELETE SET NULL,
  cost_center_id uuid REFERENCES public.cost_centers(id) ON DELETE SET NULL,
  current_stage_id uuid REFERENCES public.workflow_stages(id),
  vendor_name text,
  description text,
  amount numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'rejected', 'closed')),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.invoice_requests ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 2. Defaulting trigger (fixed)
-- ============================================================
-- Mirrors set_request_defaults(): tenant_id and requester_id are always
-- derived from the authenticated session, never trusted from client input.
-- Also filters workflow_stages by is_active and raises clear errors instead
-- of silently leaving current_stage_id / department_id NULL.

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
  WHERE tenant_id = NEW.tenant_id AND is_active
  ORDER BY sequence_order ASC
  LIMIT 1;

  IF v_initial_stage_id IS NULL THEN
    RAISE EXCEPTION 'no active workflow stages configured for this tenant';
  END IF;

  NEW.current_stage_id := v_initial_stage_id;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS invoice_request_defaults ON public.invoice_requests;
CREATE TRIGGER invoice_request_defaults
BEFORE INSERT ON public.invoice_requests
FOR EACH ROW EXECUTE FUNCTION set_invoice_request_defaults();

-- ============================================================
-- 3. invoice_requests RLS policies
-- ============================================================

-- INSERT: requester must be submitting for themself, in their own tenant.
-- (Redundant with the trigger forcing these values -- defense in depth,
-- consistent with requests_insert_own.)
DROP POLICY IF EXISTS invoice_requests_insert_own ON public.invoice_requests;
CREATE POLICY invoice_requests_insert_own
ON public.invoice_requests
FOR INSERT
WITH CHECK (
  requester_id = auth.uid()
  AND tenant_id = get_my_tenant_id()
);

-- SELECT: same tenant, and either you submitted it or you can act on its
-- current stage (i.e. you're an approver/delegate for that stage).
DROP POLICY IF EXISTS invoice_requests_select_own_or_actionable ON public.invoice_requests;
CREATE POLICY invoice_requests_select_own_or_actionable
ON public.invoice_requests
FOR SELECT
USING (
  tenant_id = get_my_tenant_id()
  AND (
    requester_id = auth.uid()
    OR can_act_on_stage(current_stage_id)
  )
);

-- UPDATE: only someone who can act on the current stage may approve/reject,
-- and never the person who submitted it (submitter-block, mirroring the
-- offer-approval segregation-of-duties rule already enforced elsewhere).
DROP POLICY IF EXISTS invoice_requests_update_actionable ON public.invoice_requests;
CREATE POLICY invoice_requests_update_actionable
ON public.invoice_requests
FOR UPDATE
USING (
  tenant_id = get_my_tenant_id()
  AND can_act_on_stage(current_stage_id)
  AND requester_id <> auth.uid()
)
WITH CHECK (
  tenant_id = get_my_tenant_id()
  AND can_act_on_stage(current_stage_id)
  AND requester_id <> auth.uid()
);

-- ============================================================
-- 4. cost_centers RLS policies
-- ============================================================
-- NOTE: there's no dedicated admin/role-permission function in this schema
-- yet -- role_title on app_users is free text with no access-control tie-in.
-- has_po_access() (finance / terminal-stage approvers) is the closest
-- existing "elevated permission" concept, so it's used here as a stopgap.
-- Recommend introducing a proper is_admin()/roles table before this goes
-- much further, since "who can manage cost centers" is a distinct concern
-- from "who can approve terminal-stage purchase orders."

DROP POLICY IF EXISTS cost_centers_insert_finance ON public.cost_centers;
CREATE POLICY cost_centers_insert_finance
ON public.cost_centers
FOR INSERT
WITH CHECK (
  has_po_access()
  AND tenant_id = get_my_tenant_id()
);

DROP POLICY IF EXISTS cost_centers_update_finance ON public.cost_centers;
CREATE POLICY cost_centers_update_finance
ON public.cost_centers
FOR UPDATE
USING (
  has_po_access()
  AND tenant_id = get_my_tenant_id()
)
WITH CHECK (
  has_po_access()
  AND tenant_id = get_my_tenant_id()
);