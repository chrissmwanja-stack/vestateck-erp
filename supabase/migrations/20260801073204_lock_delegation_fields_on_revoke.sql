-- The RLS policy alone only checks the resulting row's delegator_user_id
-- and status -- it doesn't stop a delegator from also sneaking in a
-- change to ends_at, workflow_stage_id, delegate_user_id, etc. in the
-- same statement. Lock every field except status on direct client
-- updates, mirroring protect_po_immutable_fields's pattern for
-- purchase_orders.
CREATE OR REPLACE FUNCTION public.protect_delegation_immutable_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.tenant_id           IS DISTINCT FROM OLD.tenant_id
     OR NEW.delegator_user_id IS DISTINCT FROM OLD.delegator_user_id
     OR NEW.delegate_user_id  IS DISTINCT FROM OLD.delegate_user_id
     OR NEW.workflow_stage_id IS DISTINCT FROM OLD.workflow_stage_id
     OR NEW.starts_at         IS DISTINCT FROM OLD.starts_at
     OR NEW.ends_at           IS DISTINCT FROM OLD.ends_at
  THEN
    RAISE EXCEPTION 'only status can be changed on an existing delegation -- revoke it and create a new one instead';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER protect_delegation_immutable_fields
  BEFORE UPDATE ON public.approval_delegations
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_delegation_immutable_fields();
