-- Enables a GiST exclusion constraint so overlapping active delegations
-- for the same (delegator, delegate, stage-scope) triple are impossible
-- at the DB level, regardless of code path -- same philosophy as the
-- request_offers unique constraint.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- NULL workflow_stage_id means "all stages I own". Collapse it to a
-- sentinel so two null-stage delegations for the same pair are treated
-- as the same scope for overlap purposes, matching what
-- resolve-delegation's original `.is('workflow_stage_id', null)` check
-- did (NULLs normally never equal each other, which would silently
-- defeat the exclusion constraint for exactly this case).
ALTER TABLE public.approval_delegations
  ADD CONSTRAINT approval_delegations_no_overlap
  EXCLUDE USING gist (
    delegator_user_id WITH =,
    delegate_user_id WITH =,
    coalesce(workflow_stage_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    tstzrange(starts_at, ends_at) WITH &&
  ) WHERE (status = 'active');

-- Tighten the raw-insert RLS policy: previously a null workflow_stage_id
-- ("all stages") was let through with NO check that the delegator holds
-- ANY assignment at all, and there was no self-delegation or
-- same-tenant-delegate check. grant_delegation() below does all of this
-- properly and is now the intended path, but this stays as a backstop
-- for any direct client insert.
DROP POLICY IF EXISTS approval_delegations_insert_own ON public.approval_delegations;

CREATE POLICY approval_delegations_insert_own
  ON public.approval_delegations
  FOR INSERT
  WITH CHECK (
    delegator_user_id = auth.uid()
    AND tenant_id = get_my_tenant_id()
    AND delegate_user_id IS DISTINCT FROM auth.uid()
    AND EXISTS (
      SELECT 1 FROM app_users au
      WHERE au.id = delegate_user_id AND au.tenant_id = get_my_tenant_id()
    )
    AND (
      (workflow_stage_id IS NULL
        AND EXISTS (SELECT 1 FROM approval_assignments aa WHERE aa.user_id = auth.uid()))
      OR
      (workflow_stage_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM approval_assignments aa
          WHERE aa.user_id = auth.uid() AND aa.workflow_stage_id = approval_delegations.workflow_stage_id
        ))
    )
  );

-- Replaces resolve-delegation's GRANT branch. Revoke needs no RPC --
-- approval_delegations_revoke_own (added previously) plus the
-- protect_delegation_immutable_fields trigger already cover it safely
-- via a direct client update.
CREATE OR REPLACE FUNCTION public.grant_delegation(
  p_delegate_user_id uuid,
  p_workflow_stage_id uuid DEFAULT NULL,
  p_starts_at timestamptz DEFAULT NULL,
  p_ends_at timestamptz DEFAULT NULL
)
RETURNS approval_delegations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_delegator_tenant uuid;
  v_delegate_tenant  uuid;
  v_starts_at        timestamptz := coalesce(p_starts_at, now());
  v_created          approval_delegations%ROWTYPE;
BEGIN
  IF p_delegate_user_id IS NULL OR p_ends_at IS NULL THEN
    RAISE EXCEPTION 'delegate_user_id and ends_at are required';
  END IF;
  IF p_delegate_user_id = auth.uid() THEN
    RAISE EXCEPTION 'you cannot delegate to yourself';
  END IF;
  IF p_ends_at <= v_starts_at THEN
    RAISE EXCEPTION 'ends_at must be after starts_at';
  END IF;

  SELECT tenant_id INTO v_delegator_tenant FROM app_users WHERE id = auth.uid();
  IF v_delegator_tenant IS NULL THEN
    RAISE EXCEPTION 'delegator profile not found';
  END IF;

  SELECT tenant_id INTO v_delegate_tenant FROM app_users WHERE id = p_delegate_user_id;
  IF v_delegate_tenant IS NULL THEN
    RAISE EXCEPTION 'delegate user not found';
  END IF;
  IF v_delegate_tenant != v_delegator_tenant THEN
    RAISE EXCEPTION 'delegate must belong to the same tenant';
  END IF;

  IF p_workflow_stage_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM approval_assignments
      WHERE user_id = auth.uid() AND workflow_stage_id = p_workflow_stage_id
    ) THEN
      RAISE EXCEPTION 'you do not hold approval authority for that stage, so you cannot delegate it';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM approval_assignments WHERE user_id = auth.uid()) THEN
      RAISE EXCEPTION 'you do not hold any approval assignments to delegate';
    END IF;
  END IF;

  BEGIN
    INSERT INTO approval_delegations (
      tenant_id, delegator_user_id, delegate_user_id, workflow_stage_id, starts_at, ends_at, status
    ) VALUES (
      v_delegator_tenant, auth.uid(), p_delegate_user_id, p_workflow_stage_id, v_starts_at, p_ends_at, 'active'
    ) RETURNING * INTO v_created;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'an overlapping active delegation already exists for this delegator, delegate, and stage';
  END;

  RETURN v_created;
END;
$function$;
