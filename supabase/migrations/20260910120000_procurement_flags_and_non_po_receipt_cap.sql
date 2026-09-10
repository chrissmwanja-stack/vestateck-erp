-- Two real (not just e2e-test) bugs found while chasing e2e failures.
--
-- 1. seed_tenant_defaults() still creates the ORIGINAL 0001 workflow shape
--    (old stage names, none of the behavior flags). Every tenant created
--    through the Company Create wizard therefore gets a procurement flow
--    that can never work: /offers/entry keys off requires_offer_entry,
--    the winner picker + record_approval_decision key off
--    requires_offer_selection, and PO generation keys off
--    is_finance_terminal_stage -- all false, so offer entry is always
--    empty, submit_offers_for_approval() always throws, and no PO is ever
--    generated. This brings the provisioned shape in line with the demo
--    tenant's already-fixed shape (see supabase/seed.sql, which owns that
--    tenant's own rows).
--
--    NOTE: stage ...033 keeps approver_role 'Procurement & Logistics
--    Chief' here, matching seed.sql and the in-repo e2e procurement flow.
--    User-level segregation of duty still holds via
--    blocks_offer_submitter_approval (the offer submitter is a different
--    user than the chief).
--
-- 2. supplier_invoice_receipt_cap() returned 0 for non-PO invoices
--    (purchase_order_id IS NULL matches no PO rows, so the ELSE branch
--    fires), which made check_payment_against_receipt block EVERY
--    cash/bank payment against them: 'payment blocked: only 0.00 of ...'.
--    Non-PO invoices (services, utilities, etc.) have no PO line items
--    that could ever be "received", so the 3-way match cannot apply -- the
--    full invoice amount is payable. Without this, the Supplier Invoice
--    (Non-PO) screen produces invoices that can never be settled.

-- ----------------------------------------------------------------------------
-- 1. Provisioned workflow stages carry the offer/terminal flags.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."seed_tenant_defaults"("p_tenant_id" "uuid", "p_industry_template" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_dept_cost_control uuid;
  v_dept_procurement uuid;
  v_dept_finance uuid;
  v_dept_pmo uuid;
  v_dept_it uuid;
  v_dept_hr uuid;
  v_dept_law uuid;
  v_dept_bd uuid;
  v_stage_cce uuid;
  v_stage_ccm uuid;
  v_stage_offer uuid;
  v_stage_chief uuid;
  v_stage_finance uuid;
  v_stage_pm uuid;
  v_stage_dgm uuid;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can seed tenant defaults';
  end if;

  if exists (select 1 from departments where tenant_id = p_tenant_id)
     or exists (select 1 from workflow_stages where tenant_id = p_tenant_id) then
    return;
  end if;

  insert into departments (tenant_id, name) values (p_tenant_id, 'Cost Control')
    returning id into v_dept_cost_control;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Procurement & Logistics')
    returning id into v_dept_procurement;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Finance & Financial Reporting')
    returning id into v_dept_finance;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Project Management Office')
    returning id into v_dept_pmo;
  insert into departments (tenant_id, name) values (p_tenant_id, 'IT Support')
    returning id into v_dept_it;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Human Resources')
    returning id into v_dept_hr;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Law & Compliance')
    returning id into v_dept_law;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Business Development')
    returning id into v_dept_bd;

  if p_industry_template = 'construction' then
    insert into departments (tenant_id, name) values (p_tenant_id, 'Machine Operations');
    insert into departments (tenant_id, name) values (p_tenant_id, 'Sustainability & Business Excellence');
  end if;

  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Engineer', 1, 'Cost Control Engineer')
    returning id into v_stage_cce;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Manager', 2, 'Cost Control Manager')
    returning id into v_stage_ccm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, requires_offer_entry)
    values (p_tenant_id, 'Procurement: Offer Entry', 3, 'Procurement/Logistics Expert', true)
    returning id into v_stage_offer;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount, requires_offer_selection, blocks_offer_submitter_approval)
    values (p_tenant_id, 'Budget Controller', 4, 'Procurement & Logistics Chief', 5000000.00, true, true)
    returning id into v_stage_chief;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, is_finance_terminal_stage)
    values (p_tenant_id, 'Finance', 5, 'Finance Officer', true)
    returning id into v_stage_finance;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Project Manager', 6, 'Project Manager')
    returning id into v_stage_pm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'General Manager', 7, 'Deputy General Manager')
    returning id into v_stage_dgm;

  update workflow_stages set next_stage_low_id = v_stage_ccm where id = v_stage_cce;
  update workflow_stages set next_stage_low_id = v_stage_offer where id = v_stage_ccm;
  update workflow_stages set next_stage_low_id = v_stage_chief where id = v_stage_offer;
  update workflow_stages
    set next_stage_low_id = v_stage_finance, next_stage_high_id = v_stage_pm
    where id = v_stage_chief;
  update workflow_stages set next_stage_low_id = v_stage_dgm where id = v_stage_pm;
  update workflow_stages set next_stage_low_id = v_stage_finance where id = v_stage_dgm;

  insert into tenant_modules (tenant_id, module, enabled_by)
  select p_tenant_id, m.module, auth.uid()
  from (values ('hr'), ('legal'), ('bd'), ('it'), ('pmo'), ('procurement')) as m(module);

  if p_industry_template = 'construction' then
    insert into tenant_modules (tenant_id, module, enabled_by)
    values
      (p_tenant_id, 'machine_operation', auth.uid()),
      (p_tenant_id, 'sustainability', auth.uid());
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. Non-PO invoices are fully payable (no goods receipt can exist for them).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."supplier_invoice_receipt_cap"("p_invoice_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_invoice supplier_invoices%ROWTYPE;
  v_ordered_value numeric;
  v_received_value numeric;
  v_ordered_qty numeric;
  v_received_qty numeric;
BEGIN
  SELECT * INTO v_invoice FROM supplier_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- Non-PO invoices (services, utilities, etc.) reference no purchase
  -- order, so there are no PO line items whose receipt could gate
  -- payment -- the 3-way match does not apply. The full invoice amount
  -- is payable. (Previously this fell through to the ELSE branch below
  -- and returned 0, which made check_payment_against_receipt reject
  -- every settlement attempt against a non-PO invoice.)
  IF v_invoice.purchase_order_id IS NULL THEN
    RETURN v_invoice.amount_incl_vat;
  END IF;

  SELECT
    COALESCE(SUM(rli.quantity * rli.unit_price), 0),
    COALESCE(SUM(LEAST(rec.received_qty, rli.quantity) * rli.unit_price), 0),
    COALESCE(SUM(rli.quantity), 0),
    COALESCE(SUM(LEAST(rec.received_qty, rli.quantity)), 0)
  INTO v_ordered_value, v_received_value, v_ordered_qty, v_received_qty
  FROM request_line_items rli
  JOIN requests r ON r.id = rli.request_id
  LEFT JOIN (
    SELECT line_item_id, SUM(received_qty) AS received_qty
    FROM line_item_receipts GROUP BY line_item_id
  ) rec ON rec.line_item_id = rli.id
  JOIN purchase_orders po ON po.request_id = r.id
  WHERE po.id = v_invoice.purchase_order_id;

  IF v_ordered_value > 0 THEN
    RETURN LEAST(v_invoice.amount_incl_vat, v_invoice.amount_incl_vat * (v_received_value / v_ordered_value));
  ELSIF v_ordered_qty > 0 THEN
    RETURN LEAST(v_invoice.amount_incl_vat, v_invoice.amount_incl_vat * (v_received_qty / v_ordered_qty));
  ELSE
    RETURN 0; -- no line items / nothing ordered -- nothing payable yet
  END IF;
END;
$$;