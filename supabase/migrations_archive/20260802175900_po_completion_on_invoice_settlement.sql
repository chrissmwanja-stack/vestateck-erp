
-- "Completed" means the PO's supplier invoice is fully settled -- paid off
-- via cash/bank transactions and/or applied advance payments, whichever
-- combination clears the balance. Delivery is a precondition (you can't
-- settle an order that was never confirmed delivered).

create or replace function public.supplier_invoice_outstanding(p_invoice_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $$
  select si.amount_incl_vat
    - coalesce((select sum(cbt.amount) from cash_bank_transactions cbt
                where cbt.reference_type = 'supplier_invoice' and cbt.reference_id = si.id), 0)
    - coalesce((select sum(apa.applied_amount) from advance_payment_applications apa
                where apa.reference_type = 'supplier_invoice' and apa.reference_id = si.id), 0)
  from supplier_invoices si
  where si.id = p_invoice_id;
$$;

create or replace function public.try_complete_po(p_purchase_order_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_po      purchase_orders%rowtype;
  v_invoice supplier_invoices%rowtype;
  v_request requests%rowtype;
begin
  select * into v_po from purchase_orders where id = p_purchase_order_id;
  if not found or v_po.completed_at is not null or v_po.delivered_at is null then
    return; -- nothing to do: unknown PO, already settled, or not yet delivered
  end if;

  select * into v_invoice from supplier_invoices where purchase_order_id = p_purchase_order_id;
  if not found then
    return; -- no invoice recorded against this PO yet
  end if;

  if supplier_invoice_outstanding(v_invoice.id) > 0 then
    return; -- still owing
  end if;

  update purchase_orders set completed_at = now() where id = p_purchase_order_id;

  select * into v_request from requests where id = v_po.request_id;
  insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
  values (
    v_request.tenant_id,
    v_request.requester_id,
    'po_completed',
    'Purchase order settled',
    format('PO %s (%s) has been paid in full and is now complete.', v_po.po_number, v_po.vendor_name),
    v_request.id,
    v_po.id
  );
end;
$$;

-- Fire whenever a payment lands against a supplier invoice, from either path
create or replace function public.check_po_completion_on_cash_bank()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_po_id uuid;
begin
  if NEW.reference_type = 'supplier_invoice' then
    select purchase_order_id into v_po_id from supplier_invoices where id = NEW.reference_id;
    if v_po_id is not null then
      perform try_complete_po(v_po_id);
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_check_po_completion_on_cash_bank on public.cash_bank_transactions;
create trigger trg_check_po_completion_on_cash_bank
  after insert on public.cash_bank_transactions
  for each row execute function public.check_po_completion_on_cash_bank();

create or replace function public.check_po_completion_on_advance_application()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_po_id uuid;
begin
  if NEW.reference_type = 'supplier_invoice' then
    select purchase_order_id into v_po_id from supplier_invoices where id = NEW.reference_id;
    if v_po_id is not null then
      perform try_complete_po(v_po_id);
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_check_po_completion_on_advance_application on public.advance_payment_applications;
create trigger trg_check_po_completion_on_advance_application
  after insert on public.advance_payment_applications
  for each row execute function public.check_po_completion_on_advance_application();

-- Edge case: invoice was already fully paid (e.g. via advance) before
-- delivery gets confirmed -- check completion right when delivery lands too.
create or replace function public.confirm_po_delivered(p_purchase_order_id uuid)
 RETURNS purchase_orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_po purchase_orders%ROWTYPE;
  v_request requests%ROWTYPE;
BEGIN
  SELECT po.* INTO v_po
  FROM purchase_orders po
  JOIN requests r ON r.id = po.request_id
  WHERE po.id = p_purchase_order_id
    AND r.tenant_id = get_my_tenant_id()
  FOR UPDATE OF po;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'purchase order not found';
  END IF;

  IF NOT can_manage_po_handoff(p_purchase_order_id) THEN
    RAISE EXCEPTION 'not authorized to confirm delivery for this purchase order';
  END IF;

  IF NOT v_po.shared_with_supplier THEN
    RAISE EXCEPTION 'cannot confirm delivery before the PO has been shared with the supplier';
  END IF;

  IF v_po.delivered_at IS NOT NULL THEN
    RETURN v_po;
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_po.request_id;

  UPDATE purchase_orders
  SET delivered_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_po;

  INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
  VALUES (
    v_request.tenant_id,
    v_request.requester_id,
    'po_delivered',
    'Order delivered',
    format('PO %s (%s) has been marked as delivered.', v_po.po_number, v_po.vendor_name),
    v_request.id,
    v_po.id
  );

  PERFORM try_complete_po(p_purchase_order_id);

  RETURN v_po;
END;
$function$;

-- Manual safety valve for Finance (write-offs, cash paid outside the
-- system, etc.) -- audited via the existing po_edits table.
create or replace function public.complete_purchase_order_manually(p_purchase_order_id uuid, p_reason text)
returns purchase_orders
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_po purchase_orders%rowtype;
  v_request requests%rowtype;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'a reason is required to mark a purchase order settled manually';
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
    raise exception 'not authorized to manually settle purchase orders';
  end if;

  if v_po.delivered_at is null then
    raise exception 'cannot mark a purchase order settled before it has been delivered';
  end if;

  if v_po.completed_at is not null then
    return v_po;
  end if;

  update purchase_orders set completed_at = now() where id = p_purchase_order_id returning * into v_po;

  insert into po_edits (purchase_order_id, edited_by, reason, changes)
  values (p_purchase_order_id, auth.uid(), p_reason, jsonb_build_object('completed_at', v_po.completed_at));

  select * into v_request from requests where id = v_po.request_id;
  insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
  values (
    v_request.tenant_id,
    v_request.requester_id,
    'po_completed',
    'Purchase order settled',
    format('PO %s (%s) was manually marked settled: %s', v_po.po_number, v_po.vendor_name, p_reason),
    v_request.id,
    v_po.id
  );

  return v_po;
end;
$$;

grant execute on function public.complete_purchase_order_manually(uuid, text) to authenticated;
