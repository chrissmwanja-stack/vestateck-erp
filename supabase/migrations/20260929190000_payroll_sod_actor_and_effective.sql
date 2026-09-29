-- Payroll separation of duties: compare the preparer against BOTH identities.
--
-- generate_payroll_run stores prepared_by = auth.uid() (the real actor), while
-- approve_payroll_run compared it only to effective_user_id() (the impersonated
-- user during View-as). That let one platform admin prepare a run while viewing
-- as an HR user and then approve it while viewing as a different approver, or
-- as the same user again: prepared_by (the admin) never equalled the effective
-- user. Decision 1 (the preparer must not approve their own run) now holds for
-- the real actor and for the effective user.
--
-- Decision 2 is unchanged: approved_by still records the actor, and
-- effective_user_id / impersonation_session_id still record the View-as context.
--
-- This is a new version rather than an edit to 20260929170000 so that it
-- applies even where 170000 is already recorded (an edited-after-recorded file
-- is what left production without the earlier fixes). It defines the final
-- approve_payroll_run; 170000 must run before it.

create or replace function public.approve_payroll_run(p_run_id uuid)
returns public.hr_payroll_runs
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row       hr_payroll_runs%rowtype;
  v_effective uuid := effective_user_id();
  v_session   uuid;
begin
  if not is_payroll_approver() then
    raise exception 'not authorized to approve payroll';
  end if;
  if exists (select 1 from hr_payroll_runs where id = p_run_id and tenant_id = get_my_tenant_id()
             and (prepared_by = v_effective or prepared_by = auth.uid())) then
    raise exception 'the preparer of a payroll run cannot approve it';
  end if;

  select id into v_session from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null and expires_at > now()
  order by started_at desc limit 1;

  update hr_payroll_runs
  set status = 'approved', approved_by = auth.uid(), approved_at = now(),
      effective_user_id = v_effective, impersonation_session_id = v_session
  where id = p_run_id and tenant_id = get_my_tenant_id() and status = 'pending_approval'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'payroll run not found, or not pending approval';
  end if;

  if v_row.prepared_by is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (v_row.tenant_id, v_row.prepared_by, 'payroll_run_approved', 'Payroll run approved: ' || v_row.period,
            format('The %s payroll run has been approved.', v_row.period));
  end if;

  return v_row;
end;
$function$;
