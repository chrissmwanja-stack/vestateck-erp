-- Closes the remaining gaps in the same class of bug fixed for the
-- approval queues in 20260815120000: grant_delegation() and
-- revoke_invitation() both resolved the caller's tenant via a direct
-- `select ... from app_users where id = auth.uid()` lookup instead of
-- get_my_tenant_id(), so a suspended tenant's users could still grant
-- approval delegations or revoke pending invites while every other
-- tenant-scoped action was locked out.
--
-- Fix is mechanical, same as before: swap the inline app_users lookup
-- for get_my_tenant_id() / is_platform_admin(), which now return
-- NULL / false respectively for a suspended tenant's regular members.
-- No other logic changes.

create or replace function public.grant_delegation(p_delegate_user_id uuid, p_workflow_stage_id uuid DEFAULT NULL::uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 returns approval_delegations
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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

  v_delegator_tenant := get_my_tenant_id();
  IF v_delegator_tenant IS NULL THEN
    RAISE EXCEPTION 'delegator profile not found or company access is suspended';
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

create or replace function public.revoke_invitation(p_invitation_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_invitation invitations%rowtype;
  v_caller_is_platform_admin boolean;
  v_caller_tenant_id uuid;
begin
  select * into v_invitation
  from invitations
  where id = p_invitation_id;

  if not found then
    raise exception 'Invitation not found';
  end if;

  v_caller_is_platform_admin := is_platform_admin();
  v_caller_tenant_id := get_my_tenant_id();

  if not (
    v_caller_is_platform_admin
    or (
      v_invitation.role_bundle = 'member'
      and v_invitation.tenant_id = v_caller_tenant_id
      and exists (
        select 1 from staff_roles
        where user_id = auth.uid()
          and tenant_id = v_invitation.tenant_id
          and role = 'admin'
      )
    )
  ) then
    raise exception 'Not authorized to revoke this invitation';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Only pending invitations can be revoked (this one is %)', v_invitation.status;
  end if;

  update invitations set status = 'revoked' where id = p_invitation_id;
end;
$function$;