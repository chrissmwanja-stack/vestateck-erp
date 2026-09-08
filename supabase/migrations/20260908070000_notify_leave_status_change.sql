-- Widen the notifications feature into HR: notify an employee when their
-- leave request is approved or rejected. Leave decisions are made via a
-- direct client-side update (hr_leave_requests.status), not a RPC, so this
-- is implemented as an AFTER UPDATE trigger rather than following the
-- insert-in-the-RPC pattern used by Procurement/IT Support/Finance.
--
-- Mirrors the existing insert-into-notifications shape used elsewhere
-- (tenant_id, recipient_id, type, title, body). SECURITY DEFINER is
-- required because the notifications table has no INSERT policy for
-- regular users -- all existing writers to this table are SECURITY
-- DEFINER functions for the same reason.

CREATE OR REPLACE FUNCTION public.notify_leave_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_recipient_id uuid;
  v_employee_name text;
begin
  if NEW.status = OLD.status then
    return NEW;
  end if;

  if NEW.status not in ('approved', 'rejected') then
    return NEW;
  end if;

  select user_id, (first_name || ' ' || last_name)
    into v_recipient_id, v_employee_name
  from hr_employees
  where id = NEW.employee_id;

  -- Employee may not have a linked portal account (user_id is nullable) --
  -- nothing to notify in that case.
  if v_recipient_id is null then
    return NEW;
  end if;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    NEW.tenant_id,
    v_recipient_id,
    'leave_' || NEW.status,
    case
      when NEW.status = 'approved' then 'Your leave request has been approved'
      else 'Your leave request has been rejected'
    end,
    format(
      'Leave request %s (%s to %s, %s day%s) was %s.',
      coalesce(NEW.leave_no, NEW.id::text),
      NEW.start_date,
      NEW.end_date,
      NEW.days,
      case when NEW.days = 1 then '' else 's' end,
      NEW.status
    )
  );

  return NEW;
end;
$function$;

DROP TRIGGER IF EXISTS trg_notify_leave_status_change ON public.hr_leave_requests;

CREATE TRIGGER trg_notify_leave_status_change
  AFTER UPDATE ON public.hr_leave_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_leave_status_change();