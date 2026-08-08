-- Platform admins (e.g. a GM with no single department) can now submit
-- Procurement requests and Invoice requests with department_id left null,
-- instead of being hard-blocked by "your account has no department assigned".
-- Non-admin users still require a department, since that's how normal
-- requests get routed for departmental reporting.
--
-- get_my_approval_queue() and get_my_purchase_orders() used an INNER JOIN
-- on departments keyed off requests.department_id. Left as inner joins,
-- a null-department request would silently vanish from every approver's
-- queue -- stuck forever with no error -- and later from the PO list too.
-- Both are changed to LEFT JOIN so a null department just shows as no
-- department in the UI instead of hiding the row.

create or replace function public.set_request_defaults()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_initial_stage_id uuid;
  v_department_id     uuid;
  v_is_platform_admin boolean;
begin
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  select department_id, coalesce(is_platform_admin, false)
    into v_department_id, v_is_platform_admin
  from app_users
  where id = auth.uid();

  if v_department_id is null and not v_is_platform_admin then
    raise exception 'your account has no department assigned -- ask an admin to set one before submitting a request';
  end if;

  NEW.department_id := v_department_id;

  select id into v_initial_stage_id
  from workflow_stages
  where tenant_id = NEW.tenant_id and is_active and applies_to = 'requests'
  order by sequence_order asc
  limit 1;

  if v_initial_stage_id is null then
    raise exception 'no active workflow stages configured for this tenant';
  end if;

  NEW.current_stage_id := v_initial_stage_id;

  return NEW;
end;
$$;

create or replace function public.set_invoice_request_defaults()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_initial_stage_id uuid;
  v_department_id     uuid;
  v_is_platform_admin boolean;
begin
  NEW.tenant_id := get_my_tenant_id();
  NEW.requester_id := auth.uid();
  NEW.status := 'open';
  NEW.created_at := now();
  NEW.updated_at := now();

  select department_id, coalesce(is_platform_admin, false)
    into v_department_id, v_is_platform_admin
  from app_users
  where id = auth.uid();

  if v_department_id is null and not v_is_platform_admin then
    raise exception 'your account has no department assigned -- ask an admin to set one before submitting an invoice';
  end if;

  NEW.department_id := v_department_id;

  select id into v_initial_stage_id
  from workflow_stages
  where tenant_id = NEW.tenant_id and is_active and applies_to = 'invoices'
  order by sequence_order asc
  limit 1;

  if v_initial_stage_id is null then
    raise exception 'no active invoice workflow stages configured for this tenant';
  end if;

  NEW.current_stage_id := v_initial_stage_id;

  return NEW;
end;
$$;

create or replace function public.get_my_approval_queue()
returns table(id uuid, tenant_id uuid, requester_id uuid, department_id uuid, cost_center_id uuid, current_stage_id uuid, item_description text, quantity integer, status text, created_at timestamp with time zone, cost_center jsonb, department jsonb, requester jsonb, current_stage jsonb, acting_on_behalf_of jsonb, offers jsonb, selected_offer jsonb, purchase_order jsonb)
language sql
security definer
set search_path to 'public'
as $$
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
    and r.tenant_id = (select tenant_id from my_tenant)
  order by r.created_at asc;
$$;

create or replace function public.get_my_purchase_orders()
returns table(id uuid, request_id uuid, po_number text, initial_po_number text, vendor_name text, amount numeric, currency text, generated_by jsonb, generated_at timestamp with time zone, delivery_date date, shared_with_supplier boolean, delivered_at timestamp with time zone, completed_at timestamp with time zone, request jsonb, requester jsonb, department jsonb, cost_center jsonb, organization jsonb, mr_number text, project_sap_no text, payment_conditions text, terms_of_delivery text, edit_count integer, last_edited_at timestamp with time zone, last_edited_by jsonb)
language sql
security definer
set search_path to 'public'
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
    po.id, po.request_id, po.po_number, po.initial_po_number, po.vendor_name, po.amount, po.currency,
    jsonb_build_object('id', gen.id, 'name', gen.name) as generated_by,
    po.generated_at,
    r.delivery_date,
    coalesce(po.shared_with_supplier, false) as shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    jsonb_build_object('id', r.id, 'item_description', r.item_description, 'quantity', r.quantity, 'status', r.status) as request,
    jsonb_build_object('id', req.id, 'name', req.name) as requester,
    case when dept.id is not null
      then jsonb_build_object('id', dept.id, 'name', dept.name)
      else null
    end as department,
    jsonb_build_object('id', cc.id, 'name', cc.name, 'project_code', cc.project_code) as cost_center,
    case when org.id is not null
      then jsonb_build_object('id', org.id, 'company_code', org.company_code, 'site_name', org.site_name)
      else null
    end as organization,
    r.mr_number,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    coalesce(ec.cnt, 0)::int as edit_count,
    le.edited_at as last_edited_at,
    case when le.edited_by is not null
      then jsonb_build_object('id', editor.id, 'name', editor.name)
      else null
    end as last_edited_by
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users req on req.id = r.requester_id
  left join departments dept on dept.id = r.department_id
  join cost_centers cc on cc.id = r.cost_center_id
  join app_users gen on gen.id = po.generated_by
  left join organizations org on org.id = r.organization_id
  left join last_edit le on le.purchase_order_id = po.id and le.rn = 1
  left join app_users editor on editor.id = le.edited_by
  left join edit_counts ec on ec.purchase_order_id = po.id
  where has_po_access()
    and r.tenant_id = get_my_tenant_id()
  order by po.generated_at desc;
$$;
