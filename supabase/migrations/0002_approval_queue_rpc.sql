-- supabase/migrations/0002_sync_approval_queue_rpc.sql
--
-- Reconciles get_my_approval_queue() with the version actually running on
-- the live database, which drifted from 0002_approval_queue_rpc.sql:
--   - latest_offer now also carries submitted_by
--   - a new purchase_order jsonb column was added (left join on
--     purchase_orders), needed by PurchaseOrders.tsx
--
-- current_stage intentionally does NOT yet carry requires_offer_entry,
-- blocks_offer_submitter_approval, or is_finance_terminal_stage here --
-- those columns don't exist on workflow_stages until 0003, 0004, and
-- 20260731124853 respectively. Each of those migrations re-runs this same
-- create or replace to add its column once it exists, so the function
-- converges to the full shape by the end of the migration history without
-- this file forward-referencing columns that haven't been created yet.
--
-- This migration makes no behavioral change on the live DB (it's already
-- running the full final shape) -- it exists purely so migration history
-- replays cleanly (e.g. `supabase db pull` shadow-db, staging, disaster
-- recovery) and reaches the same end state.

create or replace function get_my_approval_queue()
returns table (
  id uuid,
  tenant_id uuid,
  requester_id uuid,
  department_id uuid,
  cost_center_id uuid,
  current_stage_id uuid,
  item_description text,
  quantity int,
  status text,
  created_at timestamptz,
  cost_center jsonb,
  department jsonb,
  requester jsonb,
  current_stage jsonb,
  acting_on_behalf_of jsonb,
  latest_offer jsonb,
  purchase_order jsonb
)
language sql
security definer
set search_path = public
as $$
  with my_tenant as (
    select tenant_id from app_users where id = auth.uid()
  ),
  -- Stages I can act on directly
  direct_stages as (
    select workflow_stage_id, null::uuid as delegator_user_id
    from approval_assignments
    where user_id = auth.uid()
  ),
  -- Stages I can act on via an active delegation
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
  -- Most recent offer per request, if any exist yet
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
      'threshold_amount', ws.threshold_amount
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
    end as latest_offer,
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
  left join ranked_offers off on off.request_id = r.id and off.rn = 1
  left join purchase_orders po on po.request_id = r.id
  where r.status = 'open'
    and r.tenant_id = (select tenant_id from my_tenant)
  order by r.created_at asc;
$$;

grant execute on function get_my_approval_queue() to authenticated;