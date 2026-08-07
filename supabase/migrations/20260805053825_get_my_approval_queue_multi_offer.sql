drop function public.get_my_approval_queue();

create or replace function public.get_my_approval_queue()
returns table(
  id uuid, tenant_id uuid, requester_id uuid, department_id uuid, cost_center_id uuid,
  current_stage_id uuid, item_description text, quantity integer, status text, created_at timestamptz,
  cost_center jsonb, department jsonb, requester jsonb, current_stage jsonb,
  acting_on_behalf_of jsonb, offers jsonb, selected_offer jsonb, purchase_order jsonb
)
language sql
security definer
set search_path to 'public'
as $function$
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
  -- All offers per request (was: only the single latest one), oldest
  -- first so the UI lists them in the order they came in.
  offers_by_request as (
    select
      ro.request_id,
      jsonb_agg(
        jsonb_build_object(
          'id', ro.id,
          'vendor_name', ro.vendor_name,
          'quotation_amount', ro.quotation_amount,
          'quantity', ro.quantity,
          'submitted_by', ro.submitted_by,
          'submitted_at', ro.submitted_at,
          'is_selected', ro.is_selected
        ) order by ro.submitted_at asc
      ) as offers,
      jsonb_agg(
        jsonb_build_object(
          'id', ro.id,
          'vendor_name', ro.vendor_name,
          'quotation_amount', ro.quotation_amount,
          'quantity', ro.quantity,
          'submitted_by', ro.submitted_by,
          'submitted_at', ro.submitted_at,
          'is_selected', ro.is_selected
        )
      ) filter (where ro.is_selected) as selected_offer_arr
    from request_offers ro
    group by ro.request_id
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
      'threshold_amount', ws.threshold_amount,
      'requires_offer_entry', ws.requires_offer_entry,
      'requires_offer_selection', ws.requires_offer_selection,
      'blocks_offer_submitter_approval', ws.blocks_offer_submitter_approval,
      'is_finance_terminal_stage', ws.is_finance_terminal_stage
    ) as current_stage,
    case when ms.delegator_user_id is not null
      then jsonb_build_object('id', delegator.id, 'name', delegator.name)
      else null
    end as acting_on_behalf_of,
    coalesce(ofr.offers, '[]'::jsonb) as offers,
    (ofr.selected_offer_arr -> 0) as selected_offer,
    case when po.id is not null
      then jsonb_build_object(
        'id', po.id,
        'po_number', po.po_number,
        'vendor_name', po.vendor_name,
        'amount', po.amount,
        'shared_with_supplier', po.shared_with_supplier
      )
      else null
    end as purchase_order
  from requests r
  join my_stages ms on ms.workflow_stage_id = r.current_stage_id
  join cost_centers cc on cc.id = r.cost_center_id
  join departments dept on dept.id = r.department_id
  join app_users req on req.id = r.requester_id
  join workflow_stages ws on ws.id = r.current_stage_id
  left join app_users delegator on delegator.id = ms.delegator_user_id
  left join offers_by_request ofr on ofr.request_id = r.id
  left join purchase_orders po on po.request_id = r.id
  where r.status = 'open'
    and r.tenant_id = (select tenant_id from my_tenant)
  order by r.created_at asc;
$function$;
