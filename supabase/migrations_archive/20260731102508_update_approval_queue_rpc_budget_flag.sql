DROP FUNCTION IF EXISTS public.get_my_approval_queue();
CREATE OR REPLACE FUNCTION public.get_my_approval_queue()
 RETURNS TABLE(id uuid, tenant_id uuid, requester_id uuid, department_id uuid, cost_center_id uuid, current_stage_id uuid, item_description text, quantity integer, status text, created_at timestamp with time zone, cost_center jsonb, department jsonb, requester jsonb, current_stage jsonb, acting_on_behalf_of jsonb, latest_offer jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with my_tenant as (
    select tenant_id from app_users where id = auth.uid()
  ),
  direct_stages as (
    select workflow_stage_id, null::uuid as delegator_user_id
    from approval_assignments
    where user_id = auth.uid()
  ),
  delegated_stages as (
    select coalesce(d.workflow_stage_id, aa.workflow_stage_id) as workflow_stage_id,
           d.delegator_user_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.delegate_user_id = auth.uid()
      and d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and (d.workflow_stage_id is null or d.workflow_stage_id = aa.workflow_stage_id)
  ),
  my_stages as (
    select * from direct_stages
    union all
    select * from delegated_stages
  ),
  ranked_offers as (
    select
      ro.*,
      row_number() over (partition by ro.request_id order by ro.submitted_at desc) as rn
    from request_offers ro
  )
  select
    r.id, r.tenant_id, r.requester_id, r.department_id, r.cost_center_id,
    r.current_stage_id, r.item_description, r.quantity, r.status, r.created_at,
    jsonb_build_object('id', cc.id, 'name', cc.name, 'project_code', cc.project_code) as cost_center,
    jsonb_build_object('id', dept.id, 'name', dept.name) as department,
    jsonb_build_object('id', req.id, 'name', req.name) as requester,
    jsonb_build_object(
      'id', ws.id,
      'name', ws.name,
      'approver_role', ws.approver_role,
      'requires_offer_entry', ws.requires_offer_entry,
      'blocks_offer_submitter_approval', ws.blocks_offer_submitter_approval
    ) as current_stage,
    case when ms.delegator_user_id is not null
      then jsonb_build_object('id', delegator.id, 'name', delegator.name)
      else null
    end as acting_on_behalf_of,
    case when off.id is not null
      then jsonb_build_object(
        'vendor_name', off.vendor_name,
        'quotation_amount', off.quotation_amount,
        'submitted_by', off.submitted_by
      )
      else null
    end as latest_offer
  from requests r
  join my_stages ms on ms.workflow_stage_id = r.current_stage_id
  join cost_centers cc on cc.id = r.cost_center_id
  join departments dept on dept.id = r.department_id
  join app_users req on req.id = r.requester_id
  join workflow_stages ws on ws.id = r.current_stage_id
  left join app_users delegator on delegator.id = ms.delegator_user_id
  left join ranked_offers off on off.request_id = r.id and off.rn = 1
  where r.status = 'open'
    and r.tenant_id = (select tenant_id from my_tenant)
  order by r.created_at asc;
$function$
