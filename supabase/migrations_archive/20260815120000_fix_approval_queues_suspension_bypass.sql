-- Closes the exact gap flagged as a caveat in the suspension lockout
-- migration (20260815110000): get_my_approval_queue() and
-- get_my_invoice_approval_queue() both resolved the caller's tenant
-- via `select tenant_id from app_users where id = auth.uid()`
-- directly, instead of going through get_my_tenant_id(). That
-- bypassed the suspension check entirely -- a suspended tenant's
-- approvers could still see and act on their approval queues even
-- though every other tenant-scoped read/write was locked out.
--
-- Fix is mechanical: swap the inline app_users lookup for
-- get_my_tenant_id(), which now returns NULL for a suspended tenant's
-- regular members. No other logic changes.
create or replace function public.get_my_approval_queue()
 returns table(id uuid, tenant_id uuid, requester_id uuid, department_id uuid, cost_center_id uuid, current_stage_id uuid, item_description text, quantity integer, status text, created_at timestamp with time zone, cost_center jsonb, department jsonb, requester jsonb, current_stage jsonb, acting_on_behalf_of jsonb, offers jsonb, selected_offer jsonb, purchase_order jsonb)
 language sql
 security definer
 set search_path to 'public'
as $function$
  with direct_stages as (
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
    case when dept.id is not null
      then jsonb_build_object('id', dept.id, 'name', dept.name)
      else null
    end as department,
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
  left join departments dept on dept.id = r.department_id
  join app_users req on req.id = r.requester_id
  join workflow_stages ws on ws.id = r.current_stage_id
  left join app_users delegator on delegator.id = ms.delegator_user_id
  left join offers_by_request ofr on ofr.request_id = r.id
  left join purchase_orders po on po.request_id = r.id
  where r.status = 'open'
    and r.tenant_id = get_my_tenant_id()
  order by r.created_at asc;
$function$;

create or replace function public.get_my_invoice_approval_queue()
 returns table(id uuid, tenant_id uuid, requester_id uuid, department_id uuid, cost_center_id uuid, current_stage_id uuid, vendor_name text, description text, amount numeric, status text, created_at timestamp with time zone, department jsonb, requester jsonb, current_stage jsonb, acting_on_behalf_of jsonb)
 language sql
 security definer
 set search_path to 'public'
as $function$
  WITH direct_stages AS (
    SELECT workflow_stage_id, NULL::uuid AS delegator_user_id
    FROM approval_assignments
    WHERE user_id = auth.uid()
  ),
  delegated_stages AS (
    SELECT COALESCE(d.workflow_stage_id, aa.workflow_stage_id) AS workflow_stage_id,
           d.delegator_user_id
    FROM approval_delegations d
    JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
    WHERE d.delegate_user_id = auth.uid()
      AND d.status = 'active'
      AND now() BETWEEN d.starts_at AND d.ends_at
      AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = aa.workflow_stage_id)
  ),
  my_stages AS (
    SELECT * FROM direct_stages
    UNION ALL
    SELECT * FROM delegated_stages
  )
  SELECT
    ir.id, ir.tenant_id, ir.requester_id, ir.department_id, ir.cost_center_id,
    ir.current_stage_id, ir.vendor_name, ir.description, ir.amount, ir.status, ir.created_at,
    jsonb_build_object('id', dept.id, 'name', dept.name) AS department,
    jsonb_build_object('id', req.id, 'name', req.name) AS requester,
    jsonb_build_object(
      'id', ws.id,
      'name', ws.name,
      'approver_role', ws.approver_role,
      'threshold_amount', ws.threshold_amount,
      'is_finance_terminal_stage', ws.is_finance_terminal_stage
    ) AS current_stage,
    CASE WHEN ms.delegator_user_id IS NOT NULL
      THEN jsonb_build_object('id', delegator.id, 'name', delegator.name)
      ELSE NULL
    END AS acting_on_behalf_of
  FROM invoice_requests ir
  JOIN my_stages ms ON ms.workflow_stage_id = ir.current_stage_id
  LEFT JOIN departments dept ON dept.id = ir.department_id
  JOIN app_users req ON req.id = ir.requester_id
  JOIN workflow_stages ws ON ws.id = ir.current_stage_id
  LEFT JOIN app_users delegator ON delegator.id = ms.delegator_user_id
  WHERE ir.status = 'open'
    AND ir.tenant_id = get_my_tenant_id()
  ORDER BY ir.created_at ASC;
$function$;