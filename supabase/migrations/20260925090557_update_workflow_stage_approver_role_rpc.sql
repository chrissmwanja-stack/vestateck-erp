-- Lets a platform admin edit a workflow stage's approver_role label from
-- the Company Detail "Approval thresholds" tab. This is a cosmetic label
-- only (see ApprovalsTab.tsx / get_my_approval_queue()) -- real approval
-- routing is entirely driven by approval_assignments (workflow_stage_id
-- -> user_id), which company admins manage themselves at
-- /admin/approval-workflow. This RPC does not touch approval_assignments.
create or replace function public.update_workflow_stage_approver_role(
  p_stage_id uuid,
  p_approver_role text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_stage workflow_stages%rowtype;
  v_new_role text;
begin
  perform require_platform_admin('Editing workflow stage approver labels');

  v_new_role := btrim(p_approver_role);
  if v_new_role is null or v_new_role = '' then
    raise exception 'approver_role must not be blank';
  end if;

  select * into v_stage
  from workflow_stages
  where id = p_stage_id;

  if not found then
    raise exception 'workflow stage not found';
  end if;

  if v_stage.approver_role = v_new_role then
    return;
  end if;

  update workflow_stages
  set approver_role = v_new_role
  where id = p_stage_id;

  perform log_platform_event(
    'workflow.approver_role.update', v_stage.tenant_id, 'workflow_stage', p_stage_id::text, null,
    jsonb_build_object('stage_name', v_stage.name, 'approver_role', v_stage.approver_role),
    jsonb_build_object('stage_name', v_stage.name, 'approver_role', v_new_role)
  );
end;
$$;
