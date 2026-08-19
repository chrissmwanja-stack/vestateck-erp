-- Adds project_sap_no / payment_conditions / terms_of_delivery to the
-- 7-arg edit_purchase_order() overload as trailing optional params.
-- Postgres allows CREATE OR REPLACE to add new defaulted parameters at
-- the end without changing the function's identity, so existing callers
-- (PurchaseOrders.tsx today, passing only the first 4-7 named params)
-- keep working unmodified.
--
-- Note: protect_po_immutable_fields() doesn't guard these 3 columns (it
-- only blocks po_number/vendor_name/amount/request_id/generated_by), so
-- a direct .update() would technically succeed against RLS -- but they
-- go through this RPC anyway so every PO field change is logged the same
-- way in po_edits, not just the financially-sensitive ones.
create or replace function public.edit_purchase_order(
  p_purchase_order_id uuid,
  p_vendor_name text,
  p_amount numeric,
  p_reason text,
  p_initial_po_number text default null::text,
  p_currency text default null::text,
  p_delivery_date date default null::date,
  p_project_sap_no text default null::text,
  p_payment_conditions text default null::text,
  p_terms_of_delivery text default null::text
)
returns po_edits
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_po      purchase_orders%rowtype;
  v_request requests%rowtype;
  v_changes jsonb := '{}'::jsonb;
  v_edit    po_edits%rowtype;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required for every PO edit';
  end if;
  if p_vendor_name is null or btrim(p_vendor_name) = '' then
    raise exception 'vendor name cannot be empty';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be greater than zero';
  end if;

  select po.* into v_po
  from purchase_orders po
  join requests r on r.id = po.request_id
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id()
  for update of po;

  if not found then
    raise exception 'purchase order not found';
  end if;
  if not has_po_access() then
    raise exception 'not authorized to edit purchase orders';
  end if;

  select * into v_request from requests where id = v_po.request_id;

  if p_vendor_name is distinct from v_po.vendor_name then
    v_changes := v_changes || jsonb_build_object(
      'vendor_name', jsonb_build_object('old', v_po.vendor_name, 'new', p_vendor_name)
    );
  end if;
  if p_amount is distinct from v_po.amount then
    v_changes := v_changes || jsonb_build_object(
      'amount', jsonb_build_object('old', v_po.amount, 'new', p_amount)
    );
  end if;
  if p_initial_po_number is not null and p_initial_po_number is distinct from v_po.initial_po_number then
    v_changes := v_changes || jsonb_build_object(
      'initial_po_number', jsonb_build_object('old', v_po.initial_po_number, 'new', p_initial_po_number)
    );
  end if;
  if p_currency is not null and p_currency is distinct from v_po.currency then
    v_changes := v_changes || jsonb_build_object(
      'currency', jsonb_build_object('old', v_po.currency, 'new', p_currency)
    );
  end if;
  if p_delivery_date is not null and p_delivery_date is distinct from v_request.delivery_date then
    v_changes := v_changes || jsonb_build_object(
      'delivery_date', jsonb_build_object('old', v_request.delivery_date, 'new', p_delivery_date)
    );
  end if;
  if p_project_sap_no is not null and p_project_sap_no is distinct from v_po.project_sap_no then
    v_changes := v_changes || jsonb_build_object(
      'project_sap_no', jsonb_build_object('old', v_po.project_sap_no, 'new', p_project_sap_no)
    );
  end if;
  if p_payment_conditions is not null and p_payment_conditions is distinct from v_po.payment_conditions then
    v_changes := v_changes || jsonb_build_object(
      'payment_conditions', jsonb_build_object('old', v_po.payment_conditions, 'new', p_payment_conditions)
    );
  end if;
  if p_terms_of_delivery is not null and p_terms_of_delivery is distinct from v_po.terms_of_delivery then
    v_changes := v_changes || jsonb_build_object(
      'terms_of_delivery', jsonb_build_object('old', v_po.terms_of_delivery, 'new', p_terms_of_delivery)
    );
  end if;

  if v_changes = '{}'::jsonb then
    raise exception 'nothing has changed -- update a field, or cancel';
  end if;

  insert into po_edits (purchase_order_id, edited_by, reason, changes)
  values (p_purchase_order_id, auth.uid(), p_reason, v_changes)
  returning * into v_edit;

  -- Open the narrow escape hatch just for this statement, then update.
  perform set_config('vestateck.allow_po_financial_edit', 'on', true);
  update purchase_orders
  set
    vendor_name = p_vendor_name,
    amount = p_amount,
    initial_po_number = coalesce(p_initial_po_number, initial_po_number),
    currency = coalesce(p_currency, currency),
    project_sap_no = coalesce(p_project_sap_no, project_sap_no),
    payment_conditions = coalesce(p_payment_conditions, payment_conditions),
    terms_of_delivery = coalesce(p_terms_of_delivery, terms_of_delivery)
  where id = p_purchase_order_id;
  perform set_config('vestateck.allow_po_financial_edit', 'off', true);

  if p_delivery_date is not null then
    update requests set delivery_date = p_delivery_date, updated_at = now() where id = v_po.request_id;
  end if;

  return v_edit;
end;
$function$;

grant execute on function public.edit_purchase_order(uuid, text, numeric, text, text, text, date, text, text, text) to authenticated;
