-- Schema-driven "Finance access" — anyone directly assigned, or actively
-- delegated, to a terminal workflow stage (no next_stage_low_id or
-- next_stage_high_id). Terminal stages are where a PO gets generated, so
-- this captures "Finance" today without hardcoding that name/role, and
-- keeps working if a tenant reconfigures who sits at the end of the chain.
create or replace function public.has_po_access()
returns boolean
language sql
stable security definer
set search_path = 'public'
as $$
  select exists (
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
$$;

-- Replace the existing purchase_orders SELECT policy — the current one
-- (purchase_orders_select_via_request) also lets the requester see it,
-- which doesn't match "Finance role only".
drop policy if exists purchase_orders_select_via_request on purchase_orders;

create policy purchase_orders_select_finance
  on purchase_orders for select
  using (
    has_po_access()
    and exists (
      select 1 from requests r
      where r.id = purchase_orders.request_id
        and r.tenant_id = get_my_tenant_id()
    )
  );

-- No insert/update/delete policy on purchase_orders — writes stay through
-- the update-purchase-order Edge Function on the service-role key, same
-- as every other write path in this project.

-- Full audit trail for PO edits
create table po_edits (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references purchase_orders(id) on delete cascade,
  edited_by uuid not null references app_users(id),
  edited_at timestamptz not null default now(),
  reason text not null,
  changes jsonb not null
);

alter table po_edits enable row level security;

create policy po_edits_select_finance
  on po_edits for select
  using (
    has_po_access()
    and exists (
      select 1
      from purchase_orders po
      join requests r on r.id = po.request_id
      where po.id = po_edits.purchase_order_id
        and r.tenant_id = get_my_tenant_id()
    )
  );

-- No insert/update/delete policy on po_edits either — only the Edge
-- Function (service role) writes audit rows.

-- List view for Finance: all POs they have access to, joined for display
create or replace function public.get_my_purchase_orders()
returns table(
  id uuid,
  request_id uuid,
  po_number text,
  vendor_name text,
  amount numeric,
  generated_by jsonb,
  generated_at timestamptz,
  request jsonb,
  requester jsonb,
  department jsonb,
  cost_center jsonb,
  edit_count integer,
  last_edited_at timestamptz,
  last_edited_by jsonb
)
language sql
security definer
set search_path = 'public'
as $$
  with last_edit as (
    select
      pe.purchase_order_id,
      pe.edited_at,
      pe.edited_by,
      row_number() over (partition by pe.purchase_order_id order by pe.edited_at desc) as rn
    from po_edits pe
  ),
  edit_counts as (
    select purchase_order_id, count(*) as cnt
    from po_edits
    group by purchase_order_id
  )
  select
    po.id, po.request_id, po.po_number, po.vendor_name, po.amount,
    jsonb_build_object('id', gen.id, 'name', gen.name) as generated_by,
    po.generated_at,
    jsonb_build_object('id', r.id, 'item_description', r.item_description, 'quantity', r.quantity, 'status', r.status) as request,
    jsonb_build_object('id', req.id, 'name', req.name) as requester,
    jsonb_build_object('id', dept.id, 'name', dept.name) as department,
    jsonb_build_object('id', cc.id, 'name', cc.name, 'project_code', cc.project_code) as cost_center,
    coalesce(ec.cnt, 0)::int as edit_count,
    le.edited_at as last_edited_at,
    case when le.edited_by is not null
      then jsonb_build_object('id', editor.id, 'name', editor.name)
      else null
    end as last_edited_by
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users req on req.id = r.requester_id
  join departments dept on dept.id = r.department_id
  join cost_centers cc on cc.id = r.cost_center_id
  join app_users gen on gen.id = po.generated_by
  left join last_edit le on le.purchase_order_id = po.id and le.rn = 1
  left join app_users editor on editor.id = le.edited_by
  left join edit_counts ec on ec.purchase_order_id = po.id
  where has_po_access()
    and r.tenant_id = get_my_tenant_id()
  order by po.generated_at desc;
$$;

-- Full audit history for one PO
create or replace function public.get_po_edit_history(po_id uuid)
returns table(
  id uuid,
  edited_at timestamptz,
  reason text,
  changes jsonb,
  editor jsonb
)
language sql
security definer
set search_path = 'public'
as $$
  select
    pe.id, pe.edited_at, pe.reason, pe.changes,
    jsonb_build_object('id', au.id, 'name', au.name) as editor
  from po_edits pe
  join app_users au on au.id = pe.edited_by
  join purchase_orders po on po.id = pe.purchase_order_id
  join requests r on r.id = po.request_id
  where pe.purchase_order_id = po_id
    and has_po_access()
    and r.tenant_id = get_my_tenant_id()
  order by pe.edited_at desc;
$$;