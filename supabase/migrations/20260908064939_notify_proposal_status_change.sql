CREATE OR REPLACE FUNCTION public.notify_proposal_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('approved', 'rejected')
     AND NEW.created_by IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body)
    VALUES (
      NEW.tenant_id,
      NEW.created_by,
      'proposal_' || NEW.status,
      'Proposal ' || NEW.status || ': ' || COALESCE(NEW.proposal_no, NEW.title),
      format('Your proposal "%s" has been %s.', NEW.title, NEW.status)
    );
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_notify_proposal_status_change
AFTER UPDATE ON public.bd_proposals
FOR EACH ROW
EXECUTE FUNCTION public.notify_proposal_status_change();
