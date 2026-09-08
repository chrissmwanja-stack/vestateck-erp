CREATE OR REPLACE FUNCTION public.notify_contract_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('active', 'terminated')
     AND NEW.created_by IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body)
    VALUES (
      NEW.tenant_id,
      NEW.created_by,
      'contract_' || NEW.status,
      'Contract ' || NEW.status || ': ' || NEW.contract_no,
      format('Contract "%s" (%s) is now %s.', NEW.title, NEW.contract_no, NEW.status)
    );
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_notify_contract_status_change
AFTER UPDATE ON public.law_contracts
FOR EACH ROW
EXECUTE FUNCTION public.notify_contract_status_change();
