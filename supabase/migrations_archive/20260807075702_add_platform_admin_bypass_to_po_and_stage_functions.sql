CREATE OR REPLACE FUNCTION public.has_po_access()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    is_platform_admin()
    or exists (
      select 1
      from approval_assignments aa
      join workflow_stages ws on ws.id = aa.workflow_stage_id
      where aa.user_id = auth.uid()
        and ws.next_stage_low_id is null
        and ws.next_stage_high_id is null
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      join workflow_stages ws on ws.id = aa.workflow_stage_id
      where d.delegate_user_id = auth.uid()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and ws.next_stage_low_id is null
        and ws.next_stage_high_id is null
        and (d.workflow_stage_id is null or d.workflow_stage_id = ws.id)
    );
$function$;

CREATE OR REPLACE FUNCTION public.can_act_on_stage(check_stage_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    is_platform_admin()
    or exists (
      select 1 from approval_assignments aa
      where aa.user_id = auth.uid()
        and aa.workflow_stage_id = check_stage_id
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      where d.delegate_user_id = auth.uid()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and aa.workflow_stage_id = check_stage_id
        and (d.workflow_stage_id is null or d.workflow_stage_id = check_stage_id)
    );
$function$;
