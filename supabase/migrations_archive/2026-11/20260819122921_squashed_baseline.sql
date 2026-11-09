


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "extensions";

CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."add_group_member"("p_group_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage group membership';
  end if;
  if not exists (select 1 from user_groups where id = p_group_id and tenant_id = get_my_tenant_id()) then
    raise exception 'group not found';
  end if;
  insert into user_group_members (group_id, user_id)
  values (p_group_id, p_user_id)
  on conflict do nothing;
end;
$$;


ALTER FUNCTION "public"."add_group_member"("p_group_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage team membership';
  end if;
  if not exists (select 1 from support_teams where id = p_team_id and tenant_id = get_my_tenant_id()) then
    raise exception 'team not found';
  end if;
  insert into support_team_members (team_id, user_id) values (p_team_id, p_user_id)
  on conflict do nothing;
end;
$$;


ALTER FUNCTION "public"."add_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."am_i_finance"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.can_access_finance();
$$;


ALTER FUNCTION "public"."am_i_finance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_stock_movement"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_delta numeric := CASE WHEN NEW.movement_type = 'in' THEN NEW.quantity ELSE -NEW.quantity END;
BEGIN
  INSERT INTO stock_balances (tenant_id, warehouse_id, material_catalog_id, material_name, unit, quantity_on_hand, updated_at)
  VALUES (NEW.tenant_id, NEW.warehouse_id, NEW.material_catalog_id, NEW.material_name, NEW.unit, v_delta, now())
  ON CONFLICT (warehouse_id, stock_key) DO UPDATE
    SET quantity_on_hand = stock_balances.quantity_on_hand + v_delta,
        updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."apply_stock_movement"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."material_catalog" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "code" "text",
    "unit" "text" DEFAULT 'Unit'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "material_type_id" "uuid",
    "material_group_id" "uuid",
    "external_material_group_id" "uuid",
    "description_tr" "text",
    "description_en" "text",
    "description_fr" "text",
    "old_material_code" "text",
    "is_active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."material_catalog" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_all_material_request_items"("p_batch_id" "uuid") RETURNS SETOF "public"."material_catalog"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_item_id uuid;
begin
  for v_item_id in
    select id from material_request_items
    where batch_id = p_batch_id and tenant_id = get_my_tenant_id() and status = 'pending'
  loop
    return next approve_material_request_item(v_item_id);
  end loop;
end;
$$;


ALTER FUNCTION "public"."approve_all_material_request_items"("p_batch_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."line_item_receipts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "line_item_id" "uuid" NOT NULL,
    "received_qty" numeric NOT NULL,
    "received_by" "uuid" NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "note" "text",
    "warehouse_id" "uuid",
    "voucher_no" "text",
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    CONSTRAINT "line_item_receipts_received_qty_check" CHECK (("received_qty" > (0)::numeric))
);


ALTER TABLE "public"."line_item_receipts" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_line_item_receipt"("p_receipt_id" "uuid") RETURNS "public"."line_item_receipts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row line_item_receipts%ROWTYPE;
BEGIN
  IF NOT is_finance_team_member(NULL) THEN
    RAISE EXCEPTION 'not authorized to approve a goods receipt';
  END IF;

  UPDATE line_item_receipts
  SET approved_by = auth.uid(), approved_at = now()
  WHERE id = p_receipt_id
    AND EXISTS (
      SELECT 1 FROM request_line_items rli JOIN requests r ON r.id = rli.request_id
      WHERE rli.id = line_item_receipts.line_item_id AND r.tenant_id = get_my_tenant_id()
    )
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'receipt not found';
  END IF;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."approve_line_item_receipt"("p_receipt_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_material_request_item"("p_item_id" "uuid") RETURNS "public"."material_catalog"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_item material_request_items%rowtype;
  v_batch material_request_batches%rowtype;
  v_catalog material_catalog%rowtype;
begin
  if not has_po_access() then
    raise exception 'not authorized to approve material requests';
  end if;

  select * into v_item from material_request_items
  where id = p_item_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'material request item not found';
  end if;

  if v_item.status <> 'pending' then
    raise exception 'this item has already been decided';
  end if;

  insert into material_catalog (
    tenant_id, name, code, unit, material_type_id, material_group_id,
    external_material_group_id, description_tr, description_en, description_fr,
    old_material_code, is_active
  )
  values (
    v_item.tenant_id, v_item.name, next_material_catalog_code(v_item.tenant_id), v_item.unit,
    v_item.material_type_id, v_item.material_group_id, v_item.external_material_group_id,
    v_item.description_tr, v_item.description_en, v_item.description_fr,
    v_item.old_material_code, true
  )
  returning * into v_catalog;

  update material_request_items
  set status = 'approved', material_catalog_id = v_catalog.id, decided_by = auth.uid(), decided_at = now()
  where id = p_item_id;

  select * into v_batch from material_request_batches where id = v_item.batch_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_item.tenant_id, v_batch.requester_id, 'material_request_approved',
    'Material request approved',
    format('"%s" was approved and added to the material catalog as %s.', v_item.name, v_catalog.code)
  );

  return v_catalog;
end;
$$;


ALTER FUNCTION "public"."approve_material_request_item"("p_item_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_payroll_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "period" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "prepared_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "rejected_by" "uuid",
    "rejected_at" timestamp with time zone,
    "rejection_reason" "text",
    "amount_disbursed" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_payroll_runs_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'pending_approval'::"text", 'approved'::"text", 'rejected'::"text", 'disbursed'::"text"])))
);


ALTER TABLE "public"."hr_payroll_runs" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_payroll_run"("p_run_id" "uuid") RETURNS "public"."hr_payroll_runs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_payroll_approver() THEN
    RAISE EXCEPTION 'not authorized to approve payroll';
  END IF;

  UPDATE hr_payroll_runs
  SET status = 'approved', approved_by = auth.uid(), approved_at = now()
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'pending_approval'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not pending approval';
  END IF;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."approve_payroll_run"("p_run_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."asset_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "assigned_to" "uuid" NOT NULL,
    "assigned_by" "uuid",
    "assigned_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "returned_at" timestamp with time zone,
    "notes" "text"
);


ALTER TABLE "public"."asset_assignments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_asset"("p_asset_id" "uuid", "p_assigned_to" "uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."asset_assignments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_asset public.assets%rowtype;
  v_assignment public.asset_assignments%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to assign assets';
  end if;
  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.status != 'in_stock' then
    raise exception 'asset is not available (status: %)', v_asset.status;
  end if;

  insert into asset_assignments (tenant_id, asset_id, assigned_to, assigned_by, notes)
  values (v_asset.tenant_id, p_asset_id, p_assigned_to, auth.uid(), p_notes)
  returning * into v_assignment;

  update assets set status = 'assigned', updated_at = now() where id = p_asset_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_asset.tenant_id,
    p_assigned_to,
    'asset_assigned',
    'Asset assigned: ' || v_asset.asset_tag,
    format('"%s" (%s) has been assigned to you.', v_asset.name, v_asset.asset_tag)
  );

  return v_assignment;
end;
$$;


ALTER FUNCTION "public"."assign_asset"("p_asset_id" "uuid", "p_assigned_to" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_receipt_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "assigned_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."material_receipt_assignments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_receipt_access"("p_user_id" "uuid") RETURNS "public"."material_receipt_assignments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row material_receipt_assignments%ROWTYPE;
BEGIN
  IF NOT is_finance_team_member('finance') THEN
    RAISE EXCEPTION 'not authorized to assign material receipt access';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_user_id AND tenant_id = get_my_tenant_id()) THEN
    RAISE EXCEPTION 'user not found in this tenant';
  END IF;

  INSERT INTO material_receipt_assignments (tenant_id, user_id, assigned_by)
  VALUES (get_my_tenant_id(), p_user_id, auth.uid())
  ON CONFLICT (tenant_id, user_id) DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'this user already has material receipt access';
  END IF;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."assign_receipt_access"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_receivable_invoice_oif"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_company_code text;
  v_next_number integer;
begin
  select company_code into v_company_code
  from public.organizations
  where id = new.organization_id;

  if v_company_code is null then
    raise exception 'organization % has no company_code', new.organization_id;
  end if;

  insert into public.oif_sequences (organization_id, invoice_type, last_number)
  values (new.organization_id, 'receivable', 1)
  on conflict (organization_id, invoice_type)
  do update set last_number = public.oif_sequences.last_number + 1
  returning last_number into v_next_number;

  new.prf_oif_number := v_company_code || '-UG-' || lpad(v_next_number::text, 6, '0');
  return new;
end;
$$;


ALTER FUNCTION "public"."assign_receivable_invoice_oif"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_supplier_invoice_oif"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_company_code text;
  v_next_number integer;
begin
  select company_code into v_company_code
  from public.organizations
  where id = new.organization_id;

  if v_company_code is null then
    raise exception 'organization % has no company_code', new.organization_id;
  end if;

  insert into public.oif_sequences (organization_id, invoice_type, last_number)
  values (new.organization_id, 'supplier', 1)
  on conflict (organization_id, invoice_type)
  do update set last_number = public.oif_sequences.last_number + 1
  returning last_number into v_next_number;

  new.prf_oif_number := v_company_code || '-UG-' || lpad(v_next_number::text, 6, '0');
  return new;
end;
$$;


ALTER FUNCTION "public"."assign_supplier_invoice_oif"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."it_tickets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "ticket_number" "text" NOT NULL,
    "requester_id" "uuid" NOT NULL,
    "assignee_id" "uuid",
    "department_id" "uuid" NOT NULL,
    "subject" "text" NOT NULL,
    "description" "text" NOT NULL,
    "category" "text" NOT NULL,
    "priority" "text" DEFAULT 'medium'::"text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "resolution_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "closed_at" timestamp with time zone,
    "requires_approval" boolean DEFAULT false NOT NULL,
    "approval_status" "text" DEFAULT 'not_required'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "approval_notes" "text",
    CONSTRAINT "it_tickets_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['not_required'::"text", 'pending'::"text", 'approved'::"text", 'rejected'::"text"]))),
    CONSTRAINT "it_tickets_category_check" CHECK (("category" = ANY (ARRAY['Hardware'::"text", 'Software'::"text", 'Network'::"text", 'Access'::"text", 'Other'::"text"]))),
    CONSTRAINT "it_tickets_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'medium'::"text", 'high'::"text", 'urgent'::"text"]))),
    CONSTRAINT "it_tickets_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'in_progress'::"text", 'resolved'::"text", 'closed'::"text"])))
);


ALTER TABLE "public"."it_tickets" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_ticket"("p_ticket_id" "uuid", "p_assignee_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."it_tickets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to assign tickets';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status = 'pending' then
    raise exception 'ticket is awaiting approval and cannot be assigned yet';
  end if;

  if p_assignee_id is not null and not exists (
    select 1 from app_users u
    where u.id = p_assignee_id
      and (
        coalesce(u.is_platform_admin, false)
        or exists (
          select 1 from departments d
          where d.id = u.department_id and d.name = 'IT Support'
        )
      )
  ) then
    raise exception 'assignee must be IT Support staff';
  end if;

  update it_tickets
  set assignee_id = p_assignee_id,
      status = case when status = 'open' and p_assignee_id is not null then 'in_progress' else status end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  if p_assignee_id is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (
      v_ticket.tenant_id,
      p_assignee_id,
      'ticket_assigned',
      'Ticket ' || v_ticket.ticket_number || ' assigned to you',
      format('"%s" has been assigned to you.', v_ticket.subject)
    );
  end if;

  return v_ticket;
end;
$$;


ALTER FUNCTION "public"."assign_ticket"("p_ticket_id" "uuid", "p_assignee_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_access_finance"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.has_po_access() or public.is_finance_team_member(NULL);
$$;


ALTER FUNCTION "public"."can_access_finance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_act_on_stage"("check_stage_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    is_platform_admin()
    or exists (
      select 1 from approval_assignments aa
      where aa.user_id = auth.uid()
        and aa.workflow_stage_id = check_stage_id
    )
    or exists (
      select 1
      from approval_delegations d
      join approval_assignments aa on aa.user_id = d.delegator_user_id
      where d.delegate_user_id = auth.uid()
        and d.status = 'active'
        and now() between d.starts_at and d.ends_at
        and aa.workflow_stage_id = check_stage_id
        and (d.workflow_stage_id is null or d.workflow_stage_id = check_stage_id)
    );
$$;


ALTER FUNCTION "public"."can_act_on_stage"("check_stage_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_manage_po_handoff"("p_purchase_order_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_request_id uuid;
  v_selected_offer_submitter uuid;
BEGIN
  SELECT request_id INTO v_request_id
  FROM purchase_orders
  WHERE id = p_purchase_order_id;

  IF v_request_id IS NULL THEN
    RETURN false;
  END IF;

  -- 1. Offer submitter (procurement) -- the winning offer now, not
  --    whichever was entered last (there can be several competing
  --    quotes on a request).
  SELECT submitted_by INTO v_selected_offer_submitter
  FROM request_offers
  WHERE request_id = v_request_id AND is_selected
  LIMIT 1;

  IF v_selected_offer_submitter = auth.uid() THEN
    RETURN true;
  END IF;

  -- 2. Anyone in the approval trail for this request.
  IF EXISTS (
    SELECT 1 FROM approval_actions
    WHERE request_id = v_request_id AND approver_id = auth.uid()
  ) THEN
    RETURN true;
  END IF;

  -- 3. Finance / terminal-stage access.
  RETURN has_po_access();
END;
$$;


ALTER FUNCTION "public"."can_manage_po_handoff"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_request"("p_request_id" "uuid", "p_reason" "text") RETURNS TABLE("out_request_id" "uuid", "out_status" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_request      requests%ROWTYPE;
  v_is_requester boolean;
  v_can_act      boolean;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a reason is required to cancel a request';
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'request not found';
  END IF;
  IF v_request.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this request';
  END IF;
  IF v_request.status != 'open' THEN
    RAISE EXCEPTION 'only open requests can be cancelled (status: %)', v_request.status;
  END IF;

  v_is_requester := v_request.requester_id = auth.uid();
  v_can_act := v_request.current_stage_id IS NOT NULL AND can_act_on_stage(v_request.current_stage_id);

  IF NOT (v_is_requester OR v_can_act) THEN
    RAISE EXCEPTION 'not authorized to cancel this request';
  END IF;

  -- Audit trail, reusing approval_actions rather than a new table --
  -- same shape as an approve/reject decision, just a different
  -- decision value.
  INSERT INTO approval_actions
    (request_id, workflow_stage_id, approver_id, decision, comment)
  VALUES
    (p_request_id, v_request.current_stage_id, auth.uid(), 'cancelled', p_reason);

  UPDATE requests
  SET status = 'cancelled', current_stage_id = NULL, updated_at = now()
  WHERE id = p_request_id;

  IF v_is_requester THEN
    -- Requester withdrew it -- notify whoever currently held it.
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    SELECT DISTINCT
      v_request.tenant_id,
      recipient_id,
      'request_cancelled',
      'Request withdrawn',
      format('Request "%s" was withdrawn by the requester: %s', v_request.item_description, p_reason),
      p_request_id
    FROM (
      SELECT aa.user_id AS recipient_id
      FROM approval_assignments aa
      WHERE aa.workflow_stage_id = v_request.current_stage_id

      UNION

      SELECT d.delegate_user_id AS recipient_id
      FROM approval_delegations d
      JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
      WHERE d.status = 'active'
        AND now() BETWEEN d.starts_at AND d.ends_at
        AND aa.workflow_stage_id = v_request.current_stage_id
        AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = v_request.current_stage_id)
    ) recipients;
  ELSE
    -- An approver/assignee cancelled it -- notify the requester.
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id)
    VALUES (
      v_request.tenant_id,
      v_request.requester_id,
      'request_cancelled',
      'Request cancelled',
      format('Your request "%s" was cancelled: %s', v_request.item_description, p_reason),
      p_request_id
    );
  END IF;

  RETURN QUERY SELECT p_request_id, 'cancelled'::text;
END;
$$;


ALTER FUNCTION "public"."cancel_request"("p_request_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_payment_against_receipt"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_cap numeric;
  v_already_paid numeric;
  v_invoice supplier_invoices%ROWTYPE;
BEGIN
  IF NEW.reference_type != 'supplier_invoice' OR NEW.transaction_type != 'payment' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_invoice FROM supplier_invoices WHERE id = NEW.reference_id;
  IF NOT FOUND THEN
    RETURN NEW; -- unrelated reference_id / bad data -- not this trigger's job to police
  END IF;

  v_cap := supplier_invoice_receipt_cap(v_invoice.id);
  v_already_paid := v_invoice.amount_incl_vat - supplier_invoice_outstanding(v_invoice.id);

  IF v_already_paid + NEW.amount > v_cap + 0.01 THEN -- small epsilon for rounding
    RAISE EXCEPTION
      'payment blocked: only % of % has been confirmed received for this invoice (already paid %, this payment %)',
      round(v_cap, 2), v_invoice.amount_incl_vat, round(v_already_paid, 2), NEW.amount;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_payment_against_receipt"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_payroll_disbursement"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_run hr_payroll_runs%ROWTYPE;
  v_total_net numeric;
BEGIN
  IF NEW.reference_type != 'payroll_run' OR NEW.transaction_type != 'payment' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_run FROM hr_payroll_runs WHERE id = NEW.reference_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_run.status NOT IN ('approved', 'disbursed') THEN
    RAISE EXCEPTION 'payroll run must be approved before it can be disbursed';
  END IF;

  SELECT COALESCE(SUM(net_pay), 0) INTO v_total_net FROM hr_payroll_items WHERE payroll_run_id = v_run.id;

  IF v_run.amount_disbursed + NEW.amount > v_total_net + 0.01 THEN
    RAISE EXCEPTION
      'payment blocked: run total is %, already disbursed %, this payment %',
      round(v_total_net, 2), round(v_run.amount_disbursed, 2), NEW.amount;
  END IF;

  UPDATE hr_payroll_runs
  SET amount_disbursed = amount_disbursed + NEW.amount,
      status = CASE WHEN amount_disbursed + NEW.amount >= v_total_net - 0.01 THEN 'disbursed' ELSE 'approved' END
  WHERE id = v_run.id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_payroll_disbursement"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_po_completion_on_advance_application"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."check_po_completion_on_advance_application"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_po_completion_on_cash_bank"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."check_po_completion_on_cash_bank"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchase_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "po_number" "text" NOT NULL,
    "vendor_name" "text" NOT NULL,
    "amount" numeric(14,2) NOT NULL,
    "generated_by" "uuid" NOT NULL,
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "shared_with_supplier" boolean DEFAULT false NOT NULL,
    "delivered_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "vendor_account_id" "uuid",
    "initial_po_number" "text",
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "pdf_storage_path" "text",
    "pdf_generated_at" timestamp with time zone,
    "project_sap_no" "text",
    "payment_conditions" "text",
    "terms_of_delivery" "text"
);


ALTER TABLE "public"."purchase_orders" OWNER TO "postgres";


COMMENT ON COLUMN "public"."purchase_orders"."project_sap_no" IS 'Reference-form "PROJECT SAP NO" field. Not yet editable anywhere in the UI.';



COMMENT ON COLUMN "public"."purchase_orders"."payment_conditions" IS 'Reference-form "Payment Conditions" field (e.g. "C.H.", "10 Gun Vadeli"). Not yet editable anywhere in the UI.';



COMMENT ON COLUMN "public"."purchase_orders"."terms_of_delivery" IS 'Reference-form "Terms of Delivery" field. Not yet editable anywhere in the UI.';



CREATE OR REPLACE FUNCTION "public"."complete_purchase_order_manually"("p_purchase_order_id" "uuid", "p_reason" "text") RETURNS "public"."purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."complete_purchase_order_manually"("p_purchase_order_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."confirm_po_delivered"("p_purchase_order_id" "uuid") RETURNS "public"."purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."confirm_po_delivered"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."access_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "resource" "text" NOT NULL,
    "access_level" "text",
    "justification" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "decided_by" "uuid",
    "decided_at" timestamp with time zone,
    "decision_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "access_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."access_requests" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_access_request"("p_resource" "text", "p_access_level" "text" DEFAULT NULL::"text", "p_justification" "text" DEFAULT NULL::"text") RETURNS "public"."access_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_request public.access_requests%rowtype;
begin
  if p_resource is null or trim(p_resource) = '' then
    raise exception 'resource/system is required';
  end if;

  insert into access_requests (tenant_id, requested_by, resource, access_level, justification)
  values (get_my_tenant_id(), auth.uid(), p_resource, p_access_level, p_justification)
  returning * into v_request;

  return v_request;
end;
$$;


ALTER FUNCTION "public"."create_access_request"("p_resource" "text", "p_access_level" "text", "p_justification" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "asset_tag" "text",
    "type" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "serial_number" "text",
    "vendor" "text",
    "purchase_date" "date",
    "purchase_cost" numeric,
    "status" "text" DEFAULT 'in_stock'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "assets_status_check" CHECK (("status" = ANY (ARRAY['in_stock'::"text", 'assigned'::"text", 'maintenance'::"text", 'retired'::"text"]))),
    CONSTRAINT "assets_type_check" CHECK (("type" = ANY (ARRAY['hardware'::"text", 'software'::"text"])))
);


ALTER TABLE "public"."assets" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_asset"("p_type" "text", "p_name" "text", "p_category" "text" DEFAULT NULL::"text", "p_serial_number" "text" DEFAULT NULL::"text", "p_vendor" "text" DEFAULT NULL::"text", "p_purchase_date" "date" DEFAULT NULL::"date", "p_purchase_cost" numeric DEFAULT NULL::numeric, "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."assets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create assets';
  end if;
  if p_type not in ('hardware','software') then
    raise exception 'invalid type: %', p_type;
  end if;

  insert into assets (tenant_id, type, name, category, serial_number, vendor, purchase_date, purchase_cost, notes)
  values (get_my_tenant_id(), p_type, p_name, p_category, p_serial_number, p_vendor, p_purchase_date, p_purchase_cost, p_notes)
  returning * into v_asset;

  return v_asset;
end;
$$;


ALTER FUNCTION "public"."create_asset"("p_type" "text", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_date" "date", "p_purchase_cost" numeric, "p_notes" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."asset_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "asset_type" "text" NOT NULL,
    "item_description" "text" NOT NULL,
    "justification" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "decided_by" "uuid",
    "decided_at" timestamp with time zone,
    "decision_notes" "text",
    "fulfilled_asset_id" "uuid",
    "fulfilled_assignment_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "asset_requests_asset_type_check" CHECK (("asset_type" = ANY (ARRAY['hardware'::"text", 'software'::"text"]))),
    CONSTRAINT "asset_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'fulfilled'::"text"])))
);


ALTER TABLE "public"."asset_requests" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_asset_request"("p_asset_type" "text", "p_item_description" "text", "p_justification" "text" DEFAULT NULL::"text") RETURNS "public"."asset_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_request public.asset_requests%rowtype;
begin
  if p_asset_type not in ('hardware','software') then
    raise exception 'invalid asset type: %', p_asset_type;
  end if;
  if p_item_description is null or trim(p_item_description) = '' then
    raise exception 'item description is required';
  end if;

  insert into asset_requests (tenant_id, requested_by, asset_type, item_description, justification)
  values (get_my_tenant_id(), auth.uid(), p_asset_type, p_item_description, p_justification)
  returning * into v_request;

  return v_request;
end;
$$;


ALTER FUNCTION "public"."create_asset_request"("p_asset_type" "text", "p_item_description" "text", "p_justification" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."faqs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "question" "text" NOT NULL,
    "answer" "text" NOT NULL,
    "category" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_published" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."faqs" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_faq"("p_question" "text", "p_answer" "text", "p_category" "text" DEFAULT NULL::"text", "p_sort_order" integer DEFAULT 0, "p_is_published" boolean DEFAULT true) RETURNS "public"."faqs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_faq public.faqs%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create FAQ entries';
  end if;
  insert into faqs (tenant_id, question, answer, category, sort_order, is_published)
  values (get_my_tenant_id(), p_question, p_answer, p_category, p_sort_order, p_is_published)
  returning * into v_faq;
  return v_faq;
end;
$$;


ALTER FUNCTION "public"."create_faq"("p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_groups" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_group"("p_name" "text", "p_description" "text" DEFAULT NULL::"text") RETURNS "public"."user_groups"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_group public.user_groups%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create groups';
  end if;
  insert into user_groups (tenant_id, name, description)
  values (get_my_tenant_id(), p_name, p_description)
  returning * into v_group;
  return v_group;
end;
$$;


ALTER FUNCTION "public"."create_group"("p_name" "text", "p_description" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kb_articles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "category" "text",
    "content" "text" NOT NULL,
    "is_published" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."kb_articles" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_kb_article"("p_title" "text", "p_content" "text", "p_category" "text" DEFAULT NULL::"text", "p_is_published" boolean DEFAULT true) RETURNS "public"."kb_articles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_article public.kb_articles%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create knowledge base articles';
  end if;
  insert into kb_articles (tenant_id, title, content, category, is_published, created_by)
  values (get_my_tenant_id(), p_title, p_content, p_category, p_is_published, auth.uid())
  returning * into v_article;
  return v_article;
end;
$$;


ALTER FUNCTION "public"."create_kb_article"("p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."licenses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "license_key" "text",
    "seats_total" integer DEFAULT 1 NOT NULL,
    "vendor" "text",
    "expiry_date" "date",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."licenses" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_license"("p_asset_id" "uuid", "p_seats_total" integer DEFAULT 1, "p_license_key" "text" DEFAULT NULL::"text", "p_vendor" "text" DEFAULT NULL::"text", "p_expiry_date" "date" DEFAULT NULL::"date", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."licenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_asset public.assets%rowtype;
  v_license public.licenses%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create licenses';
  end if;
  select * into v_asset from assets where id = p_asset_id;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.type != 'software' then
    raise exception 'licenses can only be linked to software assets';
  end if;

  insert into licenses (tenant_id, asset_id, license_key, seats_total, vendor, expiry_date, notes)
  values (v_asset.tenant_id, p_asset_id, p_license_key, p_seats_total, p_vendor, p_expiry_date, p_notes)
  returning * into v_license;

  return v_license;
end;
$$;


ALTER FUNCTION "public"."create_license"("p_asset_id" "uuid", "p_seats_total" integer, "p_license_key" "text", "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_payroll_run"("p_period" "text") RETURNS "public"."hr_payroll_runs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_run hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to prepare payroll';
  END IF;

  INSERT INTO hr_payroll_runs (tenant_id, period, prepared_by)
  VALUES (get_my_tenant_id(), p_period, auth.uid())
  RETURNING * INTO v_run;

  RETURN v_run;
END;
$$;


ALTER FUNCTION "public"."create_payroll_run"("p_period" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."problems" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "problem_number" "text",
    "title" "text" NOT NULL,
    "description" "text",
    "root_cause" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "category" "text",
    "priority" "text" DEFAULT 'medium'::"text" NOT NULL,
    "created_by" "uuid",
    "assigned_to" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "closed_at" timestamp with time zone,
    CONSTRAINT "problems_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'medium'::"text", 'high'::"text", 'urgent'::"text"]))),
    CONSTRAINT "problems_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'investigating'::"text", 'resolved'::"text", 'closed'::"text"])))
);


ALTER TABLE "public"."problems" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_problem"("p_title" "text", "p_description" "text" DEFAULT NULL::"text", "p_category" "text" DEFAULT NULL::"text", "p_priority" "text" DEFAULT 'medium'::"text") RETURNS "public"."problems"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_problem public.problems%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create problems';
  end if;
  if p_priority not in ('low','medium','high','urgent') then
    raise exception 'invalid priority: %', p_priority;
  end if;

  insert into problems (tenant_id, title, description, category, priority, created_by)
  values (get_my_tenant_id(), p_title, p_description, p_category, p_priority, auth.uid())
  returning * into v_problem;
  return v_problem;
end;
$$;


ALTER FUNCTION "public"."create_problem"("p_title" "text", "p_description" "text", "p_category" "text", "p_priority" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."support_teams" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."support_teams" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_support_team"("p_name" "text", "p_description" "text" DEFAULT NULL::"text") RETURNS "public"."support_teams"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage support teams';
  end if;
  insert into support_teams (tenant_id, name, description)
  values (get_my_tenant_id(), p_name, p_description)
  returning * into v_row;
  return v_row;
end;
$$;


ALTER FUNCTION "public"."create_support_team"("p_name" "text", "p_description" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ticket_categories" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_ticket_category"("p_code" "text", "p_name" "text") RETURNS "public"."ticket_categories"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  insert into ticket_categories (tenant_id, code, name)
  values (get_my_tenant_id(), p_code, p_name)
  returning * into v_row;
  return v_row;
end;
$$;


ALTER FUNCTION "public"."create_ticket_category"("p_code" "text", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decide_access_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."access_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_request public.access_requests%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to decide access requests';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from access_requests where id = p_request_id for update;
  if not found or v_request.tenant_id != get_my_tenant_id() then
    raise exception 'request not found';
  end if;
  if v_request.status != 'pending' then
    raise exception 'request is not pending (status: %)', v_request.status;
  end if;

  update access_requests
  set status = p_decision, decided_by = auth.uid(), decided_at = now(),
      decision_notes = p_notes, updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_request.tenant_id, v_request.requested_by, 'access_request_' || p_decision,
    'Access request ' || p_decision || ': ' || v_request.resource,
    coalesce(p_notes, 'Your access request has been ' || p_decision || '.')
  );

  return v_request;
end;
$$;


ALTER FUNCTION "public"."decide_access_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decide_asset_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."asset_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_request public.asset_requests%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to decide asset requests';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from asset_requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'pending' then
    raise exception 'request is not pending (status: %)', v_request.status;
  end if;

  update asset_requests
  set status = p_decision,
      decided_by = auth.uid(),
      decided_at = now(),
      decision_notes = p_notes,
      updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_request.tenant_id,
    v_request.requested_by,
    'asset_request_' || p_decision,
    'Asset request ' || p_decision || ': ' || v_request.item_description,
    coalesce(p_notes, 'Your asset request has been ' || p_decision || '.')
  );

  return v_request;
end;
$$;


ALTER FUNCTION "public"."decide_asset_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."po_edits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "purchase_order_id" "uuid" NOT NULL,
    "edited_by" "uuid" NOT NULL,
    "edited_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reason" "text" NOT NULL,
    "changes" "jsonb" NOT NULL
);


ALTER TABLE "public"."po_edits" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."edit_purchase_order"("p_purchase_order_id" "uuid", "p_vendor_name" "text", "p_amount" numeric, "p_reason" "text", "p_initial_po_number" "text" DEFAULT NULL::"text", "p_currency" "text" DEFAULT NULL::"text", "p_delivery_date" "date" DEFAULT NULL::"date", "p_project_sap_no" "text" DEFAULT NULL::"text", "p_payment_conditions" "text" DEFAULT NULL::"text", "p_terms_of_delivery" "text" DEFAULT NULL::"text") RETURNS "public"."po_edits"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."edit_purchase_order"("p_purchase_order_id" "uuid", "p_vendor_name" "text", "p_amount" numeric, "p_reason" "text", "p_initial_po_number" "text", "p_currency" "text", "p_delivery_date" "date", "p_project_sap_no" "text", "p_payment_conditions" "text", "p_terms_of_delivery" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."end_impersonation"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id
  from impersonation_sessions
  where platform_admin_id = auth.uid() and ended_at is null
  limit 1;

  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), v_tenant_id, 'end');
end;
$$;


ALTER FUNCTION "public"."end_impersonation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fulfill_asset_request"("p_request_id" "uuid", "p_asset_id" "uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."asset_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_request public.asset_requests%rowtype;
  v_asset public.assets%rowtype;
  v_assignment public.asset_assignments%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to fulfill asset requests';
  end if;

  select * into v_request from asset_requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'approved' then
    raise exception 'request must be approved before fulfillment (status: %)', v_request.status;
  end if;

  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  if v_asset.type != v_request.asset_type then
    raise exception 'asset type (%) does not match requested type (%)', v_asset.type, v_request.asset_type;
  end if;
  if v_asset.status != 'in_stock' then
    raise exception 'asset is not available (status: %)', v_asset.status;
  end if;

  insert into asset_assignments (tenant_id, asset_id, assigned_to, assigned_by, notes)
  values (v_asset.tenant_id, p_asset_id, v_request.requested_by, auth.uid(), p_notes)
  returning * into v_assignment;

  update assets set status = 'assigned', updated_at = now() where id = p_asset_id;

  update asset_requests
  set status = 'fulfilled',
      fulfilled_asset_id = p_asset_id,
      fulfilled_assignment_id = v_assignment.id,
      updated_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_asset.tenant_id,
    v_request.requested_by,
    'asset_request_fulfilled',
    'Asset request fulfilled: ' || v_asset.asset_tag,
    format('"%s" (%s) has been assigned to you.', v_asset.name, v_asset.asset_tag)
  );

  return v_request;
end;
$$;


ALTER FUNCTION "public"."fulfill_asset_request"("p_request_id" "uuid", "p_asset_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_bd_lead_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if NEW.lead_no is null then
    NEW.lead_no := public.next_doc_number(NEW.tenant_id, 'bd_lead', 'BD-L');
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_bd_lead_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_bd_opportunity_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if NEW.opportunity_no is null then
    NEW.opportunity_no := public.next_doc_number(NEW.tenant_id, 'bd_opportunity', 'BD-O');
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_bd_opportunity_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_bd_proposal_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if NEW.proposal_no is null then
    NEW.proposal_no := public.next_doc_number(NEW.tenant_id, 'bd_proposal', 'BD-P');
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_bd_proposal_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_bd_tender_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if NEW.tender_no is null then
    NEW.tender_no := public.next_doc_number(NEW.tenant_id, 'bd_tender', 'BD-T');
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_bd_tender_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_hr_employee_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.employee_no := public.next_doc_number(NEW.tenant_id, 'hr_employee', 'HR-EMP');
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_hr_employee_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_hr_leave_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.leave_no := public.next_doc_number(NEW.tenant_id, 'hr_leave', 'HR-LV');
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_hr_leave_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_law_case_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.case_no := public.next_doc_number(NEW.tenant_id, 'law_case', 'LAW-CASE');
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_law_case_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_law_compliance_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.item_no := public.next_doc_number(NEW.tenant_id, 'law_compliance', 'LAW-COMP');
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_law_compliance_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_law_contract_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.contract_no := public.next_doc_number(NEW.tenant_id, 'law_contract', 'LAW-C');
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_law_contract_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_machine_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  NEW.machine_no := public.next_doc_number(NEW.tenant_id, 'machine', 'MCH');
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_machine_no"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_payroll_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payroll_run_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "basic_salary" numeric NOT NULL,
    "allowances" numeric DEFAULT 0 NOT NULL,
    "deductions" numeric DEFAULT 0 NOT NULL,
    "net_pay" numeric GENERATED ALWAYS AS ((("basic_salary" + "allowances") - "deductions")) STORED,
    "note" "text",
    CONSTRAINT "hr_payroll_items_allowances_check" CHECK (("allowances" >= (0)::numeric)),
    CONSTRAINT "hr_payroll_items_basic_salary_check" CHECK (("basic_salary" >= (0)::numeric)),
    CONSTRAINT "hr_payroll_items_deductions_check" CHECK (("deductions" >= (0)::numeric))
);


ALTER TABLE "public"."hr_payroll_items" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_payroll_items"("p_run_id" "uuid") RETURNS SETOF "public"."hr_payroll_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_run hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to prepare payroll';
  END IF;

  SELECT * INTO v_run FROM hr_payroll_runs WHERE id = p_run_id AND tenant_id = get_my_tenant_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'payroll run not found';
  END IF;
  IF v_run.status != 'draft' THEN
    RAISE EXCEPTION 'can only generate items while the run is in draft';
  END IF;

  RETURN QUERY
  INSERT INTO hr_payroll_items (payroll_run_id, employee_id, basic_salary)
  SELECT p_run_id, e.id, cc.basic_salary
  FROM hr_employees e
  JOIN hr_employee_current_compensation cc ON cc.employee_id = e.id
  WHERE e.tenant_id = get_my_tenant_id()
    AND e.is_active
    AND NOT EXISTS (SELECT 1 FROM hr_payroll_items i WHERE i.payroll_run_id = p_run_id AND i.employee_id = e.id)
  ON CONFLICT (payroll_run_id, employee_id) DO NOTHING
  RETURNING *;
END;
$$;


ALTER FUNCTION "public"."generate_payroll_items"("p_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_pmo_project_no"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  NEW.project_no := public.next_doc_number(NEW.tenant_id, 'pmo_project', 'PMO-P');
  return NEW;
end;
$$;


ALTER FUNCTION "public"."generate_pmo_project_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_access_requests"("p_status" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "requested_by" "uuid", "requester_name" "text", "resource" "text", "access_level" "text", "justification" "text", "status" "text", "decided_by" "uuid", "decided_at" timestamp with time zone, "decision_notes" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view access requests';
  end if;

  return query
  select r.id, r.requested_by, u.name, r.resource, r.access_level, r.justification,
         r.status, r.decided_by, r.decided_at, r.decision_notes, r.created_at
  from access_requests r
  join app_users u on u.id = r.requested_by
  where r.tenant_id = get_my_tenant_id()
    and (p_status is null or r.status = p_status)
  order by r.created_at desc;
end;
$$;


ALTER FUNCTION "public"."get_access_requests"("p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_active_impersonation"() RETURNS TABLE("tenant_id" "uuid", "tenant_name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select t.id, t.name
  from impersonation_sessions s
  join tenants t on t.id = s.tenant_id
  where s.platform_admin_id = auth.uid() and s.ended_at is null
  limit 1;
$$;


ALTER FUNCTION "public"."get_active_impersonation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_tickets"() RETURNS SETOF "public"."it_tickets"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and is_it_support()
  order by
    case status when 'open' then 0 when 'in_progress' then 1 when 'resolved' then 2 else 3 end,
    created_at desc;
$$;


ALTER FUNCTION "public"."get_all_tickets"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_asset_assignments"("p_active_only" boolean DEFAULT true) RETURNS TABLE("id" "uuid", "asset_id" "uuid", "asset_tag" "text", "asset_name" "text", "asset_type" "text", "assigned_to" "uuid", "assigned_to_name" "text", "assigned_by" "uuid", "assigned_at" timestamp with time zone, "returned_at" timestamp with time zone, "notes" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    aa.id, aa.asset_id, a.asset_tag, a.name as asset_name, a.type as asset_type,
    aa.assigned_to, u.name as assigned_to_name, aa.assigned_by, aa.assigned_at, aa.returned_at, aa.notes
  from asset_assignments aa
  join assets a on a.id = aa.asset_id
  join app_users u on u.id = aa.assigned_to
  where aa.tenant_id = get_my_tenant_id() and is_it_support()
    and (not p_active_only or aa.returned_at is null)
  order by aa.assigned_at desc;
$$;


ALTER FUNCTION "public"."get_asset_assignments"("p_active_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_asset_requests"("p_status" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "requested_by" "uuid", "requester_name" "text", "asset_type" "text", "item_description" "text", "justification" "text", "status" "text", "decided_by" "uuid", "decided_at" timestamp with time zone, "decision_notes" "text", "fulfilled_asset_id" "uuid", "fulfilled_asset_tag" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view asset requests';
  end if;

  return query
  select
    r.id, r.requested_by, u.name, r.asset_type, r.item_description, r.justification,
    r.status, r.decided_by, r.decided_at, r.decision_notes,
    r.fulfilled_asset_id, a.asset_tag, r.created_at
  from asset_requests r
  join app_users u on u.id = r.requested_by
  left join assets a on a.id = r.fulfilled_asset_id
  where r.tenant_id = get_my_tenant_id()
    and (p_status is null or r.status = p_status)
  order by r.created_at desc;
end;
$$;


ALTER FUNCTION "public"."get_asset_requests"("p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_assets"("p_type" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."assets"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from assets
  where tenant_id = get_my_tenant_id() and is_it_support()
    and (p_type is null or type = p_type)
  order by created_at desc;
$$;


ALTER FUNCTION "public"."get_assets"("p_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_companies_overview"() RETURNS TABLE("tenant_id" "uuid", "name" "text", "status" "text", "created_at" timestamp with time zone, "member_count" bigint, "module_count" bigint, "request_count_30d" bigint, "pending_request_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    t.id,
    t.name,
    t.status,
    t.created_at,
    (select count(*) from app_users u where u.tenant_id = t.id),
    (select count(*) from tenant_modules tm where tm.tenant_id = t.id),
    (select count(*) from requests r where r.tenant_id = t.id and r.created_at >= now() - interval '30 days'),
    (select count(*) from requests r where r.tenant_id = t.id and r.status = 'pending')
  from tenants t
  where is_platform_admin()
  order by t.created_at desc;
$$;


ALTER FUNCTION "public"."get_companies_overview"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_company_analytics"("p_tenant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view company analytics';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  select jsonb_build_object(
    'requests_by_status', (
      select coalesce(jsonb_agg(jsonb_build_object('status', status, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select status, count(*) as cnt
        from requests
        where tenant_id = p_tenant_id
        group by status
      ) s
    ),
    'requests_by_month', (
      select coalesce(jsonb_agg(jsonb_build_object('month', month, 'count', cnt) order by month), '[]'::jsonb)
      from (
        select to_char(date_trunc('month', created_at), 'YYYY-MM') as month, count(*) as cnt
        from requests
        where tenant_id = p_tenant_id
          and created_at >= date_trunc('month', now()) - interval '5 months'
        group by 1
      ) m
    ),
    'purchase_orders', (
      select jsonb_build_object(
        'count', count(*),
        'total_value', coalesce(sum(po.amount), 0)
      )
      from purchase_orders po
      join requests r on r.id = po.request_id
      where r.tenant_id = p_tenant_id
    ),
    'members_by_department', (
      select coalesce(jsonb_agg(jsonb_build_object('department', dept, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select coalesce(d.name, 'Unassigned') as dept, count(*) as cnt
        from app_users u
        left join departments d on d.id = u.department_id
        where u.tenant_id = p_tenant_id
        group by 1
      ) dm
    ),
    'top_requesters', (
      select coalesce(jsonb_agg(jsonb_build_object('name', uname, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select u.name as uname, count(*) as cnt
        from requests r
        join app_users u on u.id = r.requester_id
        where r.tenant_id = p_tenant_id
        group by u.name
        order by count(*) desc
        limit 5
      ) tr
    )
  )
  into v_result;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."get_company_analytics"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_faqs"("p_category" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."faqs"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from faqs
  where tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
    and (p_category is null or category = p_category)
  order by sort_order, created_at;
$$;


ALTER FUNCTION "public"."get_faqs"("p_category" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_group_members"("p_group_id" "uuid") RETURNS TABLE("user_id" "uuid", "name" "text", "email" "text", "added_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view group members';
  end if;
  return query
  select u.id, u.name, u.email, m.added_at
  from user_group_members m
  join app_users u on u.id = m.user_id
  join user_groups g on g.id = m.group_id
  where m.group_id = p_group_id and g.tenant_id = get_my_tenant_id()
  order by u.name;
end;
$$;


ALTER FUNCTION "public"."get_group_members"("p_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_groups"() RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "member_count" bigint, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view groups';
  end if;
  return query
  select g.id, g.name, g.description, count(m.user_id), g.created_at
  from user_groups g
  left join user_group_members m on m.group_id = g.id
  where g.tenant_id = get_my_tenant_id()
  group by g.id
  order by g.name;
end;
$$;


ALTER FUNCTION "public"."get_groups"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_kb_articles"("p_category" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."kb_articles"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from kb_articles
  where tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
    and (p_category is null or category = p_category)
  order by updated_at desc;
$$;


ALTER FUNCTION "public"."get_kb_articles"("p_category" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_licenses"() RETURNS TABLE("id" "uuid", "asset_id" "uuid", "asset_tag" "text", "asset_name" "text", "license_key" "text", "seats_total" integer, "seats_used" bigint, "vendor" "text", "expiry_date" "date", "notes" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    l.id, l.asset_id, a.asset_tag, a.name as asset_name, l.license_key, l.seats_total,
    (select count(*) from asset_assignments aa where aa.asset_id = l.asset_id and aa.returned_at is null) as seats_used,
    l.vendor, l.expiry_date, l.notes
  from licenses l
  join assets a on a.id = l.asset_id
  where l.tenant_id = get_my_tenant_id() and is_it_support()
  order by l.expiry_date nulls last, l.created_at desc;
$$;


ALTER FUNCTION "public"."get_licenses"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_access_requests"() RETURNS SETOF "public"."access_requests"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from access_requests where requested_by = auth.uid() order by created_at desc;
$$;


ALTER FUNCTION "public"."get_my_access_requests"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_approval_queue"() RETURNS TABLE("id" "uuid", "tenant_id" "uuid", "requester_id" "uuid", "department_id" "uuid", "cost_center_id" "uuid", "current_stage_id" "uuid", "item_description" "text", "quantity" integer, "status" "text", "created_at" timestamp with time zone, "cost_center" "jsonb", "department" "jsonb", "requester" "jsonb", "current_stage" "jsonb", "acting_on_behalf_of" "jsonb", "offers" "jsonb", "selected_offer" "jsonb", "purchase_order" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_my_approval_queue"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_asset_requests"() RETURNS TABLE("id" "uuid", "asset_type" "text", "item_description" "text", "justification" "text", "status" "text", "decision_notes" "text", "decided_at" timestamp with time zone, "fulfilled_asset_id" "uuid", "fulfilled_asset_tag" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    r.id, r.asset_type, r.item_description, r.justification, r.status,
    r.decision_notes, r.decided_at, r.fulfilled_asset_id, a.asset_tag, r.created_at
  from asset_requests r
  left join assets a on a.id = r.fulfilled_asset_id
  where r.requested_by = auth.uid()
  order by r.created_at desc;
$$;


ALTER FUNCTION "public"."get_my_asset_requests"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_invoice_approval_queue"() RETURNS TABLE("id" "uuid", "tenant_id" "uuid", "requester_id" "uuid", "department_id" "uuid", "cost_center_id" "uuid", "current_stage_id" "uuid", "vendor_name" "text", "description" "text", "amount" numeric, "status" "text", "created_at" timestamp with time zone, "department" "jsonb", "requester" "jsonb", "current_stage" "jsonb", "acting_on_behalf_of" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_my_invoice_approval_queue"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_procurement_orders"() RETURNS TABLE("id" "uuid", "po_number" "text", "item_description" "text", "vendor_name" "text", "amount" numeric, "request_id" "uuid", "shared_with_supplier" boolean, "delivered_at" timestamp with time zone, "completed_at" timestamp with time zone, "request_status" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    po.id,
    po.po_number,
    req.item_description,
    po.vendor_name,
    po.amount,
    po.request_id,
    COALESCE(po.shared_with_supplier, false)::boolean AS shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    req.status AS request_status
  FROM public.purchase_orders po
  INNER JOIN public.requests req ON req.id = po.request_id
  INNER JOIN public.request_offers ro ON ro.request_id = req.id
  WHERE ro.submitted_by = auth.uid()
    AND req.status = 'closed'
  ORDER BY po.generated_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_my_procurement_orders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_purchase_orders"() RETURNS TABLE("id" "uuid", "request_id" "uuid", "po_number" "text", "initial_po_number" "text", "vendor_name" "text", "amount" numeric, "currency" "text", "generated_by" "jsonb", "generated_at" timestamp with time zone, "delivery_date" "date", "shared_with_supplier" boolean, "delivered_at" timestamp with time zone, "completed_at" timestamp with time zone, "request" "jsonb", "requester" "jsonb", "department" "jsonb", "cost_center" "jsonb", "organization" "jsonb", "mr_number" "text", "project_sap_no" "text", "payment_conditions" "text", "terms_of_delivery" "text", "edit_count" integer, "last_edited_at" timestamp with time zone, "last_edited_by" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_my_purchase_orders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_tenant_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select tenant_id from impersonation_sessions
     where platform_admin_id = auth.uid()
       and ended_at is null
       and started_at > now() - interval '2 hours'
     limit 1),
    (select u.tenant_id
     from app_users u
     join tenants t on t.id = u.tenant_id
     where u.id = auth.uid()
       and t.status != 'suspended')
  );
$$;


ALTER FUNCTION "public"."get_my_tenant_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_tenant_status"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select t.status
  from app_users u
  join tenants t on t.id = u.tenant_id
  where u.id = auth.uid();
$$;


ALTER FUNCTION "public"."get_my_tenant_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_tickets"() RETURNS SETOF "public"."it_tickets"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and requester_id = auth.uid()
  order by created_at desc;
$$;


ALTER FUNCTION "public"."get_my_tickets"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_offer_detail"("p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object(
    'request', (
      select jsonb_build_object(
        'mr_number', r.mr_number,
        'item_description', r.item_description,
        'requester_name', ru.name,
        'created_at', r.created_at
      )
      from requests r
      join app_users ru on ru.id = r.requester_id
      where r.id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    ),
    'offers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ro.id,
        'vendor_name', ro.vendor_name,
        'quotation_amount', ro.quotation_amount,
        'quantity', ro.quantity,
        'submitted_at', ro.submitted_at,
        'submitted_by_name', su.name,
        'is_selected', ro.is_selected
      ) order by ro.submitted_at asc), '[]'::jsonb)
      from request_offers ro
      join requests r on r.id = ro.request_id
      left join app_users su on su.id = ro.submitted_by
      where ro.request_id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    ),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', rli.id,
        'material_service', rli.material_service,
        'cost_code', rli.cost_code,
        'group_code', rli.group_code,
        'place_of_use', rli.place_of_use,
        'quantity', rli.quantity,
        'unit_price', rli.unit_price,
        'total', rli.total,
        'currency', rli.currency
      ) order by rli.created_at), '[]'::jsonb)
      from request_line_items rli
      join requests r on r.id = rli.request_id
      where rli.request_id = p_request_id
        and r.tenant_id = get_my_tenant_id()
    )
  );
$$;


ALTER FUNCTION "public"."get_offer_detail"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pending_material_request_batches"() RETURNS TABLE("batch_id" "uuid", "requester_id" "uuid", "requester_name" "text", "requested_at" timestamp with time zone, "pending_item_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select b.id, b.requester_id, u.name, b.created_at, count(i.id)
  from material_request_batches b
  join app_users u on u.id = b.requester_id
  join material_request_items i on i.batch_id = b.id and i.status = 'pending'
  where b.tenant_id = get_my_tenant_id() and has_po_access()
  group by b.id, b.requester_id, u.name, b.created_at
  order by b.created_at;
$$;


ALTER FUNCTION "public"."get_pending_material_request_batches"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pending_ticket_approvals"() RETURNS SETOF "public"."it_tickets"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and is_it_support() and approval_status = 'pending'
  order by created_at asc;
$$;


ALTER FUNCTION "public"."get_pending_ticket_approvals"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_platform_dashboard_stats"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view platform dashboard stats';
  end if;

  select jsonb_build_object(
    'totals', jsonb_build_object(
      'total_companies', (select count(*) from tenants),
      'active_companies', (select count(*) from tenants where status = 'active'),
      'pending_companies', (select count(*) from tenants where status = 'pending'),
      'suspended_companies', (select count(*) from tenants where status = 'suspended'),
      'total_members', (select count(*) from app_users),
      'total_pos', (select count(*) from purchase_orders),
      'total_po_value', coalesce((select sum(amount) from purchase_orders), 0),
      'total_requests', (select count(*) from requests),
      'requests_30d', (select count(*) from requests where created_at >= now() - interval '30 days'),
      'pending_requests', (select count(*) from requests where status = 'open'),
      'pending_invites', (select count(*) from invitations where status = 'pending' and role_bundle = 'company_admin')
    ),
    'by_status', (
      select coalesce(jsonb_agg(jsonb_build_object('status', status, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (select status, count(*) as cnt from tenants group by status) s
    ),
    'companies_by_month', (
      select coalesce(jsonb_agg(jsonb_build_object('month', month, 'count', cnt) order by month), '[]'::jsonb)
      from (
        select to_char(date_trunc('month', created_at), 'YYYY-MM') as month, count(*) as cnt
        from tenants
        where created_at >= date_trunc('month', now()) - interval '5 months'
        group by 1
      ) m
    ),
    'requests_by_month', (
      select coalesce(jsonb_agg(jsonb_build_object('month', month, 'count', cnt) order by month), '[]'::jsonb)
      from (
        select to_char(date_trunc('month', created_at), 'YYYY-MM') as month, count(*) as cnt
        from requests
        where created_at >= date_trunc('month', now()) - interval '5 months'
        group by 1
      ) m
    ),
    'module_adoption', (
      select coalesce(jsonb_agg(jsonb_build_object('module', module, 'count', cnt) order by cnt desc), '[]'::jsonb)
      from (
        select module, count(distinct tenant_id) as cnt
        from tenant_modules
        group by module
      ) ma
    ),
    'recent_companies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'status', status, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
      from (select id, name, status, created_at from tenants order by created_at desc limit 5) rc
    ),
    'top_companies_by_requests', (
      select coalesce(jsonb_agg(jsonb_build_object('name', name, 'count', cnt, 'tenant_id', tenant_id) order by cnt desc), '[]'::jsonb)
      from (
        select t.name, r.tenant_id, count(*) as cnt
        from requests r join tenants t on t.id = r.tenant_id
        group by t.name, r.tenant_id
        order by cnt desc
        limit 5
      ) tr
    ),
    'pending_invites_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'email', email, 'tenant_id', tenant_id, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
      from (select id, email, tenant_id, created_at from invitations where status = 'pending' and role_bundle = 'company_admin' order by created_at desc limit 10) pi
    ),
    'pending_companies_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at) order by created_at asc), '[]'::jsonb)
      from (select id, name, created_at from tenants where status = 'pending' order by created_at asc limit 25) pc
    ),
    'suspended_companies_list', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at) order by created_at asc), '[]'::jsonb)
      from (select id, name, created_at from tenants where status = 'suspended' order by created_at asc limit 25) sc
    )
  ) into v_result;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."get_platform_dashboard_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_po_detail"("p_purchase_order_id" "uuid") RETURNS TABLE("purchase_order_id" "uuid", "request_id" "uuid", "po_number" "text", "initial_po_number" "text", "vendor_name" "text", "po_amount" numeric, "currency" "text", "generated_at" timestamp with time zone, "generated_by_name" "text", "shared_with_supplier" boolean, "delivered_at" timestamp with time zone, "completed_at" timestamp with time zone, "mr_number" "text", "mr_title" "text", "mr_date" "date", "requester_name" "text", "delivery_date" "date", "project_sap_no" "text", "payment_conditions" "text", "terms_of_delivery" "text", "offer_quotation_amount" numeric, "offer_quantity" integer, "offer_submitted_by_name" "text", "offer_submitted_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    po.id as purchase_order_id,
    po.request_id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name,
    po.amount as po_amount,
    po.currency,
    po.generated_at,
    generator.name as generated_by_name,
    po.shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    r.mr_number,
    r.item_description as mr_title,
    r.created_at::date as mr_date,
    requester.name as requester_name,
    r.delivery_date,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    ro.quotation_amount as offer_quotation_amount,
    ro.quantity as offer_quantity,
    submitter.name as offer_submitted_by_name,
    ro.submitted_at as offer_submitted_at
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  join app_users generator on generator.id = po.generated_by
  left join request_offers ro
    on ro.request_id = po.request_id
    and ro.vendor_name = po.vendor_name
  left join app_users submitter on submitter.id = ro.submitted_by
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id()
  order by ro.submitted_at desc
  limit 1;
$$;


ALTER FUNCTION "public"."get_po_detail"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_po_edit_history"("po_id" "uuid") RETURNS TABLE("id" "uuid", "edited_at" timestamp with time zone, "reason" "text", "changes" "jsonb", "editor" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_po_edit_history"("po_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_po_pdf_data"("p_purchase_order_id" "uuid") RETURNS TABLE("purchase_order_id" "uuid", "po_number" "text", "initial_po_number" "text", "company" "text", "po_total" numeric, "currency" "text", "po_date" "date", "mr_number" "text", "mr_title" "text", "requester_name" "text", "purchaser_name" "text", "delivery_date" "date", "organization_name" "text", "project_sap_no" "text", "payment_conditions" "text", "terms_of_delivery" "text", "primary_cost_code" "text", "line_items" "jsonb", "approvals" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    po.id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name,
    po.amount,
    po.currency,
    po.generated_at::date,
    r.mr_number,
    r.item_description,
    requester.name,
    purchaser.name,
    r.delivery_date,
    o.site_name,
    po.project_sap_no,
    po.payment_conditions,
    po.terms_of_delivery,
    (
      select rli.cost_code
      from request_line_items rli
      where rli.request_id = r.id
      order by rli.created_at
      limit 1
    ),
    coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'material_service', rli.material_service,
          'cost_code', rli.cost_code,
          'place_of_use', rli.place_of_use,
          'quantity', rli.quantity,
          'unit_price', rli.unit_price,
          'total', rli.total,
          'currency', rli.currency
        ) order by rli.created_at)
        from request_line_items rli
        where rli.request_id = r.id
      ),
      '[]'::jsonb
    ),
    coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'stage_name', ws.name,
          'approver_role', ws.approver_role,
          'approver_name', au.name,
          'sequence_order', ws.sequence_order,
          'acted_at', aa.acted_at
        ) order by ws.sequence_order, aa.acted_at)
        from approval_actions aa
        join workflow_stages ws on ws.id = aa.workflow_stage_id
        join app_users au on au.id = aa.approver_id
        where aa.request_id = r.id
          and aa.decision = 'approved'
          and aa.acted_at = (
            select max(aa2.acted_at)
            from approval_actions aa2
            where aa2.request_id = aa.request_id
              and aa2.workflow_stage_id = aa.workflow_stage_id
              and aa2.decision = 'approved'
          )
      ),
      '[]'::jsonb
    )
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join organizations o on o.id = r.organization_id
  left join request_offers ro on ro.request_id = r.id
  left join app_users purchaser on purchaser.id = ro.submitted_by
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id();
$$;


ALTER FUNCTION "public"."get_po_pdf_data"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."priority_levels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "label" "text" NOT NULL,
    "color" "text" DEFAULT '#757575'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "priority_levels_code_check" CHECK (("code" = ANY (ARRAY['low'::"text", 'medium'::"text", 'high'::"text", 'urgent'::"text"])))
);


ALTER TABLE "public"."priority_levels" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_priority_levels"() RETURNS SETOF "public"."priority_levels"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from priority_levels where tenant_id = get_my_tenant_id() order by sort_order;
$$;


ALTER FUNCTION "public"."get_priority_levels"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_problem_tickets"("p_problem_id" "uuid") RETURNS SETOF "public"."it_tickets"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select t.* from it_tickets t
  join problem_tickets pt on pt.ticket_id = t.id
  where pt.problem_id = p_problem_id and t.tenant_id = get_my_tenant_id() and is_it_support()
  order by t.created_at desc;
$$;


ALTER FUNCTION "public"."get_problem_tickets"("p_problem_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_problems"() RETURNS SETOF "public"."problems"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from problems
  where tenant_id = get_my_tenant_id() and is_it_support()
  order by
    case status when 'open' then 0 when 'investigating' then 1 when 'resolved' then 2 else 3 end,
    created_at desc;
$$;


ALTER FUNCTION "public"."get_problems"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_procurement_info"("p_organization_id" "uuid" DEFAULT NULL::"uuid", "p_initial_po_number" "text" DEFAULT NULL::"text", "p_company" "text" DEFAULT NULL::"text", "p_purchaser" "text" DEFAULT NULL::"text", "p_mr_number" "text" DEFAULT NULL::"text", "p_po_number" "text" DEFAULT NULL::"text", "p_po_status" "text" DEFAULT NULL::"text") RETURNS TABLE("request_id" "uuid", "purchase_order_id" "uuid", "initial_po_number" "text", "po_number" "text", "po_total" numeric, "currency" "text", "company" "text", "requester_name" "text", "mr_originator_name" "text", "mr_title" "text", "mr_number" "text", "mr_created_at" timestamp with time zone, "po_date" "date", "delivery_date" "date", "shared_with_supplier" boolean, "delivered_at" timestamp with time zone, "completed_at" timestamp with time zone, "po_status" "text", "pdf_storage_path" "text", "pdf_generated_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    r.id as request_id,
    po.id as purchase_order_id,
    po.initial_po_number,
    po.po_number,
    po.amount as po_total,
    po.currency,
    po.vendor_name as company,
    requester.name as requester_name,
    purchaser.name as mr_originator_name,
    r.item_description as mr_title,
    r.mr_number,
    r.created_at as mr_created_at,
    po.generated_at::date as po_date,
    r.delivery_date,
    po.shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    case
      when po.completed_at is not null then 'completed'
      when po.delivered_at is not null then 'delivered'
      when po.shared_with_supplier then 'shared'
      else 'pending'
    end as po_status,
    po.pdf_storage_path,
    po.pdf_generated_at
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join request_offers ro on ro.request_id = r.id
  left join app_users purchaser on purchaser.id = ro.submitted_by
  where r.tenant_id = get_my_tenant_id()
    and (p_organization_id is null or r.organization_id = p_organization_id)
    and (p_initial_po_number is null or po.initial_po_number ilike '%' || p_initial_po_number || '%')
    and (p_company is null or po.vendor_name ilike '%' || p_company || '%')
    and (p_purchaser is null or purchaser.name ilike '%' || p_purchaser || '%')
    and (p_mr_number is null or r.mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po.po_number ilike '%' || p_po_number || '%')
    and (
      p_po_status is null or p_po_status = 'All' or
      (case
        when po.completed_at is not null then 'completed'
        when po.delivered_at is not null then 'delivered'
        when po.shared_with_supplier then 'shared'
        else 'pending'
      end) = p_po_status
    )
  order by po.generated_at desc;
$$;


ALTER FUNCTION "public"."get_procurement_info"("p_organization_id" "uuid", "p_initial_po_number" "text", "p_company" "text", "p_purchaser" "text", "p_mr_number" "text", "p_po_number" "text", "p_po_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_request_tracking"("p_organization_id" "uuid" DEFAULT NULL::"uuid", "p_mr_number" "text" DEFAULT NULL::"text", "p_po_number" "text" DEFAULT NULL::"text", "p_company" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_subcontractor" "text" DEFAULT NULL::"text", "p_mr_originator" "text" DEFAULT NULL::"text", "p_pending_authority" "text" DEFAULT NULL::"text", "p_status" "text" DEFAULT NULL::"text", "p_cost_code" "text" DEFAULT NULL::"text", "p_place_of_use" "text" DEFAULT NULL::"text", "p_mr_date_from" "date" DEFAULT NULL::"date", "p_mr_date_to" "date" DEFAULT NULL::"date", "p_po_date_from" "date" DEFAULT NULL::"date", "p_po_date_to" "date" DEFAULT NULL::"date", "p_delivery_date_from" "date" DEFAULT NULL::"date", "p_delivery_date_to" "date" DEFAULT NULL::"date", "p_market_offer_date_from" "date" DEFAULT NULL::"date", "p_market_offer_date_to" "date" DEFAULT NULL::"date", "p_closing_date_from" "date" DEFAULT NULL::"date", "p_closing_date_to" "date" DEFAULT NULL::"date") RETURNS TABLE("request_id" "uuid", "purchase_order_id" "uuid", "mr_number" "text", "mr_date" "date", "mr_created_at" timestamp with time zone, "mr_title" "text", "subcontractor" "text", "requester_name" "text", "order_placer_name" "text", "initial_po_number" "text", "po_number" "text", "po_date" "date", "delivery_date" "date", "market_offer_date" "date", "company" "text", "po_total" numeric, "currency" "text", "closing_date" "date", "status" "text", "lifecycle_status" "text", "pending_authority" "text", "cost_code" "text", "place_of_use" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with base as (
    select
      r.id as request_id,
      po.id as purchase_order_id,
      r.mr_number,
      r.created_at::date as mr_date,
      r.created_at as mr_created_at,
      r.item_description as mr_title,
      r.subcontractor,
      requester.name as requester_name,
      submitter.name as order_placer_name,
      po.initial_po_number,
      po.po_number,
      po.generated_at::date as po_date,
      r.delivery_date,
      ro.submitted_at::date as market_offer_date,
      coalesce(po.vendor_name, ro.vendor_name) as company,
      po.amount as po_total,
      po.currency,
      po.completed_at::date as closing_date,
      r.status,
      case
        when r.status = 'rejected' then 'rejected'
        when r.status = 'cancelled' then 'cancelled'
        when po.completed_at is not null then 'closed_order'
        when po.id is not null then 'open_order'
        when ro.id is not null then 'pending_po'
        when ws.requires_offer_entry then 'pending_bid_entry'
        else 'pending_mr'
      end as lifecycle_status,
      ws.name as pending_authority,
      rli.cost_code,
      rli.place_of_use
    from requests r
    join app_users requester on requester.id = r.requester_id
    left join organizations o on o.id = r.organization_id
    left join purchase_orders po on po.request_id = r.id
    left join request_offers ro on ro.request_id = r.id
    left join app_users submitter on submitter.id = ro.submitted_by
    left join workflow_stages ws on ws.id = r.current_stage_id
    left join lateral (
      select cost_code, place_of_use
      from request_line_items rli
      where rli.request_id = r.id
      order by rli.created_at
      limit 1
    ) rli on true
    where r.tenant_id = get_my_tenant_id()
      and (p_organization_id is null or r.organization_id = p_organization_id)
  )
  select *
  from base
  where (p_mr_number is null or mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po_number ilike '%' || p_po_number || '%')
    and (p_company is null or company ilike '%' || p_company || '%')
    and (p_description is null or mr_title ilike '%' || p_description || '%')
    and (p_subcontractor is null or subcontractor ilike '%' || p_subcontractor || '%')
    and (p_mr_originator is null or requester_name ilike '%' || p_mr_originator || '%')
    and (p_pending_authority is null or pending_authority ilike '%' || p_pending_authority || '%')
    and (p_cost_code is null or cost_code ilike '%' || p_cost_code || '%')
    and (p_place_of_use is null or place_of_use ilike '%' || p_place_of_use || '%')
    and (p_mr_date_from is null or mr_date >= p_mr_date_from)
    and (p_mr_date_to is null or mr_date <= p_mr_date_to)
    and (p_po_date_from is null or po_date >= p_po_date_from)
    and (p_po_date_to is null or po_date <= p_po_date_to)
    and (p_delivery_date_from is null or delivery_date >= p_delivery_date_from)
    and (p_delivery_date_to is null or delivery_date <= p_delivery_date_to)
    and (p_market_offer_date_from is null or market_offer_date >= p_market_offer_date_from)
    and (p_market_offer_date_to is null or market_offer_date <= p_market_offer_date_to)
    and (p_closing_date_from is null or closing_date >= p_closing_date_from)
    and (p_closing_date_to is null or closing_date <= p_closing_date_to)
    and (
      p_status is null or p_status = 'All' or
      (p_status = 'pending_all' and lifecycle_status in ('pending_mr', 'pending_bid_entry', 'pending_po')) or
      (p_status <> 'pending_all' and lifecycle_status = p_status)
    )
  order by mr_date desc;
$$;


ALTER FUNCTION "public"."get_request_tracking"("p_organization_id" "uuid", "p_mr_number" "text", "p_po_number" "text", "p_company" "text", "p_description" "text", "p_subcontractor" "text", "p_mr_originator" "text", "p_pending_authority" "text", "p_status" "text", "p_cost_code" "text", "p_place_of_use" "text", "p_mr_date_from" "date", "p_mr_date_to" "date", "p_po_date_from" "date", "p_po_date_to" "date", "p_delivery_date_from" "date", "p_delivery_date_to" "date", "p_market_offer_date_from" "date", "p_market_offer_date_to" "date", "p_closing_date_from" "date", "p_closing_date_to" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sla_policies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "priority" "text" NOT NULL,
    "target_hours" integer NOT NULL,
    "description" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sla_policies_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'medium'::"text", 'high'::"text", 'urgent'::"text"]))),
    CONSTRAINT "sla_policies_target_hours_check" CHECK (("target_hours" > 0))
);


ALTER TABLE "public"."sla_policies" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sla_policies"() RETURNS SETOF "public"."sla_policies"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from sla_policies where tenant_id = get_my_tenant_id()
  order by case priority when 'urgent' then 0 when 'high' then 1 when 'medium' then 2 else 3 end;
$$;


ALTER FUNCTION "public"."get_sla_policies"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_support_team_members"("p_team_id" "uuid") RETURNS TABLE("user_id" "uuid", "name" "text", "email" "text", "added_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to view team members';
  end if;
  return query
  select u.id, u.name, u.email, m.added_at
  from support_team_members m
  join app_users u on u.id = m.user_id
  join support_teams st on st.id = m.team_id
  where m.team_id = p_team_id and st.tenant_id = get_my_tenant_id()
  order by u.name;
end;
$$;


ALTER FUNCTION "public"."get_support_team_members"("p_team_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_support_teams"() RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "is_active" boolean, "member_count" bigint, "created_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select st.id, st.name, st.description, st.is_active, count(m.user_id), st.created_at
  from support_teams st
  left join support_team_members m on m.team_id = st.id
  where st.tenant_id = get_my_tenant_id()
  group by st.id
  order by st.name;
$$;


ALTER FUNCTION "public"."get_support_teams"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_tenant_modules"("p_tenant_id" "uuid") RETURNS SETOF "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select module from public.tenant_modules
  where tenant_id = p_tenant_id and public.is_platform_admin()
  order by module;
$$;


ALTER FUNCTION "public"."get_tenant_modules"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_tenant_workflow_stages"("p_tenant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view workflow stage thresholds';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ws.id,
      'name', ws.name,
      'sequence_order', ws.sequence_order,
      'approver_role', ws.approver_role,
      'threshold_amount', ws.threshold_amount,
      'applies_to', ws.applies_to
    )
    order by ws.applies_to, ws.sequence_order
  ), '[]'::jsonb)
  into v_result
  from workflow_stages ws
  where ws.tenant_id = p_tenant_id;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."get_tenant_workflow_stages"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_ticket_categories"() RETURNS SETOF "public"."ticket_categories"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from ticket_categories where tenant_id = get_my_tenant_id() order by name;
$$;


ALTER FUNCTION "public"."get_ticket_categories"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_vendor_evaluation"() RETURNS TABLE("vendor_account_id" "uuid", "account_code" "text", "vendor_name" "text", "contact_name" "text", "contact_phone" "text", "contact_email" "text", "is_active" boolean, "total_pos" bigint, "total_po_value" numeric, "delivered_pos" bigint, "avg_days_to_deliver" numeric, "on_time_delivery_pct" numeric, "fulfillment_accuracy_pct" numeric, "over_delivery_pct" numeric, "under_delivery_pct" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not (is_finance_team_member(null) or has_po_access()) then
    raise exception 'not authorized to view vendor evaluation data';
  end if;

  return query
  select
    v.vendor_account_id, v.account_code, v.vendor_name, v.contact_name,
    v.contact_phone, v.contact_email, v.is_active, v.total_pos, v.total_po_value,
    v.delivered_pos, v.avg_days_to_deliver, v.on_time_delivery_pct,
    v.fulfillment_accuracy_pct, v.over_delivery_pct, v.under_delivery_pct
  from v_vendor_evaluation v
  where v.tenant_id = get_my_tenant_id()
  order by v.total_pos desc nulls last, v.vendor_name;
end;
$$;


ALTER FUNCTION "public"."get_vendor_evaluation"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."approval_delegations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "delegator_user_id" "uuid" NOT NULL,
    "delegate_user_id" "uuid" NOT NULL,
    "workflow_stage_id" "uuid",
    "starts_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "approval_delegations_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'expired'::"text", 'revoked'::"text"]))),
    CONSTRAINT "chk_delegation_window" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."approval_delegations" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grant_delegation"("p_delegate_user_id" "uuid", "p_workflow_stage_id" "uuid" DEFAULT NULL::"uuid", "p_starts_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_ends_at" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS "public"."approval_delegations"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_delegator_tenant uuid;
  v_delegate_tenant  uuid;
  v_starts_at        timestamptz := coalesce(p_starts_at, now());
  v_created          approval_delegations%ROWTYPE;
BEGIN
  IF p_delegate_user_id IS NULL OR p_ends_at IS NULL THEN
    RAISE EXCEPTION 'delegate_user_id and ends_at are required';
  END IF;
  IF p_delegate_user_id = auth.uid() THEN
    RAISE EXCEPTION 'you cannot delegate to yourself';
  END IF;
  IF p_ends_at <= v_starts_at THEN
    RAISE EXCEPTION 'ends_at must be after starts_at';
  END IF;

  v_delegator_tenant := get_my_tenant_id();
  IF v_delegator_tenant IS NULL THEN
    RAISE EXCEPTION 'delegator profile not found or company access is suspended';
  END IF;

  SELECT tenant_id INTO v_delegate_tenant FROM app_users WHERE id = p_delegate_user_id;
  IF v_delegate_tenant IS NULL THEN
    RAISE EXCEPTION 'delegate user not found';
  END IF;
  IF v_delegate_tenant != v_delegator_tenant THEN
    RAISE EXCEPTION 'delegate must belong to the same tenant';
  END IF;

  IF p_workflow_stage_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM approval_assignments
      WHERE user_id = auth.uid() AND workflow_stage_id = p_workflow_stage_id
    ) THEN
      RAISE EXCEPTION 'you do not hold approval authority for that stage, so you cannot delegate it';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM approval_assignments WHERE user_id = auth.uid()) THEN
      RAISE EXCEPTION 'you do not hold any approval assignments to delegate';
    END IF;
  END IF;

  BEGIN
    INSERT INTO approval_delegations (
      tenant_id, delegator_user_id, delegate_user_id, workflow_stage_id, starts_at, ends_at, status
    ) VALUES (
      v_delegator_tenant, auth.uid(), p_delegate_user_id, p_workflow_stage_id, v_starts_at, p_ends_at, 'active'
    ) RETURNING * INTO v_created;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'an overlapping active delegation already exists for this delegator, delegate, and stage';
  END;

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."grant_delegation"("p_delegate_user_id" "uuid", "p_workflow_stage_id" "uuid", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_updated_at_generic"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.updated_at = now();
  return NEW;
end;
$$;


ALTER FUNCTION "public"."handle_updated_at_generic"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_module_role"("p_module" "text", "p_roles" "text"[]) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    exists (
      select 1 from public.app_users
      where id = auth.uid() and is_platform_admin
    )
    or (
      exists (
        select 1 from public.tenant_modules
        where tenant_id = public.get_my_tenant_id()
          and module = p_module
      )
      and exists (
        select 1 from public.staff_roles
        where user_id = auth.uid()
          and module = p_module
          and role = any(p_roles)
          and tenant_id = public.get_my_tenant_id()
      )
    );
$$;


ALTER FUNCTION "public"."has_module_role"("p_module" "text", "p_roles" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_po_access"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    is_platform_admin()
    or exists (
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


ALTER FUNCTION "public"."has_po_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_receipt_access"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM material_receipt_assignments
    WHERE user_id = auth.uid() AND tenant_id = get_my_tenant_id()
  );
$$;


ALTER FUNCTION "public"."has_receipt_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_any_module_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    exists (
      select 1 from public.app_users
      where id = auth.uid() and is_platform_admin
    )
    or exists (
      select 1 from public.staff_roles
      where user_id = auth.uid()
        and role = 'admin'
        and tenant_id = public.get_my_tenant_id()
    );
$$;


ALTER FUNCTION "public"."is_any_module_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_business_dev"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.has_module_role('bd', array['admin','manager','member']);
$$;


ALTER FUNCTION "public"."is_business_dev"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_finance_team_member"("p_role" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM finance_team_members
      WHERE user_id = auth.uid()
        AND tenant_id = get_my_tenant_id()
        AND (p_role IS NULL OR role = p_role)
    );
$$;


ALTER FUNCTION "public"."is_finance_team_member"("p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_hr_team_member"("p_role" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM hr_team_members
      WHERE user_id = auth.uid()
        AND tenant_id = get_my_tenant_id()
        AND (p_role IS NULL OR role = p_role)
    );
$$;


ALTER FUNCTION "public"."is_hr_team_member"("p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_it_support"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.has_module_role('it', array['admin','manager','member']);
$$;


ALTER FUNCTION "public"."is_it_support"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_payroll_approver"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM payroll_approvers
      WHERE user_id = auth.uid()
        AND tenant_id = get_my_tenant_id()
        AND is_active
    );
$$;


ALTER FUNCTION "public"."is_payroll_approver"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_platform_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT COALESCE((SELECT is_platform_admin FROM app_users WHERE id = auth.uid()), false);
$$;


ALTER FUNCTION "public"."is_platform_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."link_ticket_to_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant uuid := get_my_tenant_id();
begin
  if not is_it_support() then
    raise exception 'not authorized to link tickets to problems';
  end if;
  if not exists (select 1 from problems where id = p_problem_id and tenant_id = v_tenant) then
    raise exception 'problem not found';
  end if;
  if not exists (select 1 from it_tickets where id = p_ticket_id and tenant_id = v_tenant) then
    raise exception 'ticket not found';
  end if;

  insert into problem_tickets (problem_id, ticket_id, tenant_id)
  values (p_problem_id, p_ticket_id, v_tenant)
  on conflict do nothing;
end;
$$;


ALTER FUNCTION "public"."link_ticket_to_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."link_vendor_account_on_offer"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant_id uuid;
begin
  if NEW.vendor_account_id is null then
    select tenant_id into v_tenant_id from requests where id = NEW.request_id;
    NEW.vendor_account_id := resolve_or_create_vendor_account(v_tenant_id, NEW.vendor_name);
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."link_vendor_account_on_offer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_receipt_assignees"() RETURNS TABLE("id" "uuid", "user_id" "uuid", "user_name" "text", "assigned_by_name" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT mra.id, mra.user_id, u.name, ab.name, mra.created_at
  FROM material_receipt_assignments mra
  JOIN app_users u ON u.id = mra.user_id
  JOIN app_users ab ON ab.id = mra.assigned_by
  WHERE mra.tenant_id = get_my_tenant_id()
  ORDER BY mra.created_at DESC;
$$;


ALTER FUNCTION "public"."list_receipt_assignees"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_asset_tag"("p_tenant_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(asset_tag, '^AST-', ''), asset_tag)::int), 0) + 1
  into v_next_num
  from assets
  where tenant_id = p_tenant_id and asset_tag like 'AST-%';

  return 'AST-' || lpad(v_next_num::text, 5, '0');
end;
$$;


ALTER FUNCTION "public"."next_asset_tag"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_doc_number"("p_tenant_id" "uuid", "p_doc_type" "text", "p_prefix" "text", "p_pad" integer DEFAULT 4) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  yr text := to_char(now(), 'YYYY');
  n int;
begin
  insert into public.doc_sequences (tenant_id, doc_type, year, last_number)
  values (p_tenant_id, p_doc_type, yr, 1)
  on conflict (tenant_id, doc_type, year)
  do update set last_number = public.doc_sequences.last_number + 1
  returning last_number into n;

  return p_prefix || '-' || yr || '-' || lpad(n::text, p_pad, '0');
end;
$$;


ALTER FUNCTION "public"."next_doc_number"("p_tenant_id" "uuid", "p_doc_type" "text", "p_prefix" "text", "p_pad" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_material_catalog_code"("p_tenant_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(code, '^MAT-', ''), code)::int), 0) + 1
  into v_next_num
  from material_catalog
  where tenant_id = p_tenant_id and code like 'MAT-%';

  return 'MAT-' || lpad(v_next_num::text, 5, '0');
end;
$$;


ALTER FUNCTION "public"."next_material_catalog_code"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_mr_number"("p_tenant_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(mr_number, '^MR-', ''), mr_number)::int), 0) + 1
  into v_next_num
  from requests
  where tenant_id = p_tenant_id and mr_number like 'MR-%';

  return 'MR-' || lpad(v_next_num::text, 5, '0');
end;
$$;


ALTER FUNCTION "public"."next_mr_number"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_problem_number"("p_tenant_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(problem_number, '^PRB-', ''), problem_number)::int), 0) + 1
  into v_next_num
  from problems
  where tenant_id = p_tenant_id and problem_number like 'PRB-%';

  return 'PRB-' || lpad(v_next_num::text, 5, '0');
end;
$$;


ALTER FUNCTION "public"."next_problem_number"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_ticket_number"("p_tenant_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(ticket_number, '^TCK-', ''), ticket_number)::int), 0) + 1
  into v_next_num
  from it_tickets
  where tenant_id = p_tenant_id and ticket_number like 'TCK-%';

  return 'TCK-' || lpad(v_next_num::text, 5, '0');
end;
$$;


ALTER FUNCTION "public"."next_ticket_number"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."platform_has_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from app_users where is_platform_admin = true);
$$;


ALTER FUNCTION "public"."platform_has_admin"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."platform_has_admin"() IS 'Returns true once any platform admin exists. Used to gate the /bootstrap-admin claim flow.';



CREATE OR REPLACE FUNCTION "public"."post_issue_items_to_stock"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_issue goods_issues%ROWTYPE;
BEGIN
  SELECT * INTO v_issue FROM goods_issues WHERE id = NEW.goods_issue_id;

  INSERT INTO stock_movements (tenant_id, warehouse_id, material_catalog_id, material_name, unit, movement_type, quantity, reference_type, reference_id, recorded_by)
  VALUES (v_issue.tenant_id, v_issue.warehouse_id, NEW.material_catalog_id, NEW.material_description, NEW.unit, 'out', NEW.delivered_qty, 'goods_issue', NEW.id, v_issue.warehouse_officer_id);

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."post_issue_items_to_stock"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."post_receipt_to_stock"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_line request_line_items%ROWTYPE;
  v_tenant_id uuid;
BEGIN
  IF NEW.warehouse_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_line FROM request_line_items WHERE id = NEW.line_item_id;
  SELECT r.tenant_id INTO v_tenant_id FROM requests r WHERE r.id = v_line.request_id;

  INSERT INTO stock_movements (tenant_id, warehouse_id, material_name, unit, movement_type, quantity, reference_type, reference_id, recorded_by)
  VALUES (v_tenant_id, NEW.warehouse_id, v_line.material_service, NULL, 'in', NEW.received_qty, 'goods_receipt', NEW.id, NEW.received_by);

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."post_receipt_to_stock"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_invoice_organization_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization cannot be changed on an existing invoice (was %, attempted %) -- void and re-enter under the correct organization instead', old.organization_id, new.organization_id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."prevent_invoice_organization_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."protect_delegation_immutable_fields"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF NEW.tenant_id           IS DISTINCT FROM OLD.tenant_id
     OR NEW.delegator_user_id IS DISTINCT FROM OLD.delegator_user_id
     OR NEW.delegate_user_id  IS DISTINCT FROM OLD.delegate_user_id
     OR NEW.workflow_stage_id IS DISTINCT FROM OLD.workflow_stage_id
     OR NEW.starts_at         IS DISTINCT FROM OLD.starts_at
     OR NEW.ends_at           IS DISTINCT FROM OLD.ends_at
  THEN
    RAISE EXCEPTION 'only status can be changed on an existing delegation -- revoke it and create a new one instead';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."protect_delegation_immutable_fields"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."protect_po_immutable_fields"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF current_setting('vestateck.allow_po_financial_edit', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF NEW.po_number   IS DISTINCT FROM OLD.po_number
     OR NEW.vendor_name IS DISTINCT FROM OLD.vendor_name
     OR NEW.amount      IS DISTINCT FROM OLD.amount
     OR NEW.request_id  IS DISTINCT FROM OLD.request_id
     OR NEW.generated_by IS DISTINCT FROM OLD.generated_by
  THEN
    RAISE EXCEPTION 'these fields can only be changed via a logged PO edit, not a direct update';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."protect_po_immutable_fields"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_approval_decision"("p_request_id" "uuid", "p_decision" "text", "p_comment" "text" DEFAULT NULL::"text", "p_acting_on_behalf_of" "uuid" DEFAULT NULL::"uuid", "p_selected_offer_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("out_request_id" "uuid", "out_status" "text", "out_stage_id" "uuid", "out_purchase_order_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_request       requests%rowtype;
  v_stage         workflow_stages%rowtype;
  v_next_stage    workflow_stages%rowtype;
  v_next_stage_id uuid;
  v_offer         request_offers%rowtype;
  v_po_id         uuid;
  v_po_number     text;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select * into v_request from requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'open' then
    raise exception 'request is not open (status: %)', v_request.status;
  end if;
  if v_request.current_stage_id is null then
    raise exception 'request has no current stage';
  end if;
  if not can_act_on_stage(v_request.current_stage_id) then
    raise exception 'not authorized to act on this stage';
  end if;

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;

  -- Anti-collusion guard: if this stage blocks the offer submitter from
  -- approving their own request, check ALL offers on the request now
  -- that there can be several -- not just "the latest one" as before.
  if v_stage.blocks_offer_submitter_approval then
    if exists (
      select 1 from request_offers
      where request_id = p_request_id and submitted_by = auth.uid()
    ) then
      raise exception 'you submitted an offer on this request -- a different reviewer must act on it at this stage';
    end if;
  end if;

  insert into approval_actions
    (request_id, workflow_stage_id, approver_id, acted_on_behalf_of, decision, comment)
  values
    (p_request_id, v_stage.id, auth.uid(), p_acting_on_behalf_of, p_decision, p_comment);

  if p_decision = 'rejected' then
    update requests set status = 'rejected', updated_at = now() where id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_rejected',
      'Request rejected',
      format('Your request "%s" was rejected at the %s stage.', v_request.item_description, v_stage.name),
      p_request_id
    );

    return query select p_request_id, 'rejected'::text, v_stage.id, null::uuid;
    return;
  end if;

  if v_stage.is_finance_terminal_stage then
    update requests
    set status = 'closed', current_stage_id = null, updated_at = now()
    where id = p_request_id;

    select id into v_po_id from purchase_orders where request_id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_closed',
      'Request closed',
      format('Your request "%s" has been closed. The purchase order is ready for procurement.', v_request.item_description),
      p_request_id,
      v_po_id
    );

    return query select p_request_id, 'closed'::text, null::uuid, v_po_id;
    return;
  end if;

  -- Selection happens exactly once, at the stage flagged
  -- requires_offer_selection (Budget Controller). Every other stage --
  -- before offers exist, or after a winner has already been picked --
  -- just reads whichever offer is currently marked selected.
  if v_stage.requires_offer_selection then
    if p_selected_offer_id is null then
      raise exception 'select a winning offer before approving';
    end if;
    if not exists (
      select 1 from request_offers
      where id = p_selected_offer_id and request_id = p_request_id
    ) then
      raise exception 'selected offer does not belong to this request';
    end if;

    update request_offers
    set is_selected = (id = p_selected_offer_id)
    where request_id = p_request_id;

    select * into v_offer from request_offers where id = p_selected_offer_id;
  else
    select * into v_offer from request_offers
    where request_id = p_request_id and is_selected
    limit 1;
  end if;

  if v_stage.threshold_amount is not null then
    if not found and v_offer.id is null then
      raise exception 'no offer on file to evaluate threshold';
    end if;
    if v_offer.quotation_amount <= v_stage.threshold_amount then
      v_next_stage_id := v_stage.next_stage_low_id;
    else
      v_next_stage_id := v_stage.next_stage_high_id;
    end if;
  else
    v_next_stage_id := v_stage.next_stage_low_id;
  end if;

  if v_next_stage_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  select * into v_next_stage from workflow_stages where id = v_next_stage_id;

  if v_next_stage.is_finance_terminal_stage then
    if v_offer.id is null then
      raise exception 'no offer on file to generate a purchase order';
    end if;
    if exists (select 1 from purchase_orders where request_id = p_request_id) then
      raise exception 'a purchase order already exists for this request';
    end if;

    v_po_number := 'PO-' || to_char(now(), 'YYYY') || '-'
                   || lpad(nextval('public.po_number_seq')::text, 5, '0');

    insert into purchase_orders (request_id, po_number, vendor_name, vendor_account_id, amount, generated_by)
    values (p_request_id, v_po_number, v_offer.vendor_name, v_offer.vendor_account_id, v_offer.quotation_amount, auth.uid())
    returning id into v_po_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'purchase_order_generated',
      'Purchase order generated',
      format('A purchase order (%s) has been generated for your request "%s".', v_po_number, v_request.item_description),
      p_request_id,
      v_po_id
    );
  end if;

  update requests
  set current_stage_id = v_next_stage_id, updated_at = now()
  where id = p_request_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select distinct
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('Request "%s" is awaiting your approval at the %s stage.', v_request.item_description, v_next_stage.name),
    p_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage_id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage_id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  return query select p_request_id, 'open'::text, v_next_stage_id, v_po_id;
end;
$$;


ALTER FUNCTION "public"."record_approval_decision"("p_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid", "p_selected_offer_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_employee_compensation" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "basic_salary" numeric NOT NULL,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "effective_date" "date" NOT NULL,
    "contract_reference" "text",
    "note" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_employee_compensation_basic_salary_check" CHECK (("basic_salary" >= (0)::numeric))
);


ALTER TABLE "public"."hr_employee_compensation" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_employee_compensation"("p_employee_id" "uuid", "p_basic_salary" numeric, "p_effective_date" "date", "p_contract_reference" "text" DEFAULT NULL::"text", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."hr_employee_compensation"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row hr_employee_compensation%ROWTYPE;
  v_tenant_id uuid;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to record compensation';
  END IF;

  SELECT tenant_id INTO v_tenant_id FROM hr_employees WHERE id = p_employee_id;
  IF v_tenant_id IS NULL OR v_tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'employee not found';
  END IF;

  INSERT INTO hr_employee_compensation (tenant_id, employee_id, basic_salary, effective_date, contract_reference, note, created_by)
  VALUES (v_tenant_id, p_employee_id, p_basic_salary, p_effective_date, p_contract_reference, p_note, auth.uid())
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."record_employee_compensation"("p_employee_id" "uuid", "p_basic_salary" numeric, "p_effective_date" "date", "p_contract_reference" "text", "p_note" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."goods_issues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "warehouse_id" "uuid" NOT NULL,
    "project_label" "text",
    "voucher_no" "text",
    "issue_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "warehouse_officer_id" "uuid" NOT NULL,
    "received_by_name" "text",
    "approved_by_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."goods_issues" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_goods_issue"("p_warehouse_id" "uuid", "p_project_label" "text", "p_voucher_no" "text", "p_received_by_name" "text", "p_approved_by_name" "text", "p_items" "jsonb") RETURNS "public"."goods_issues"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_issue goods_issues%ROWTYPE;
  v_item jsonb;
  v_item_no int := 1;
BEGIN
  IF NOT has_receipt_access() THEN
    RAISE EXCEPTION 'not authorized to record goods issues';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM warehouses WHERE id = p_warehouse_id AND tenant_id = get_my_tenant_id()) THEN
    RAISE EXCEPTION 'warehouse not found';
  END IF;

  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'a goods issue needs at least one line item';
  END IF;

  INSERT INTO goods_issues (tenant_id, warehouse_id, project_label, voucher_no, warehouse_officer_id, received_by_name, approved_by_name)
  VALUES (get_my_tenant_id(), p_warehouse_id, p_project_label, p_voucher_no, auth.uid(), p_received_by_name, p_approved_by_name)
  RETURNING * INTO v_issue;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO goods_issue_items (
      goods_issue_id, item_no, material_catalog_id, material_description,
      cost_center_id, unit, requested_qty, delivered_qty, remarks
    )
    VALUES (
      v_issue.id, v_item_no,
      NULLIF(v_item->>'material_catalog_id', '')::uuid,
      v_item->>'material_description',
      NULLIF(v_item->>'cost_center_id', '')::uuid,
      v_item->>'unit',
      NULLIF(v_item->>'requested_qty', '')::numeric,
      (v_item->>'delivered_qty')::numeric,
      v_item->>'remarks'
    );
    v_item_no := v_item_no + 1;
  END LOOP;

  RETURN v_issue;
END;
$$;


ALTER FUNCTION "public"."record_goods_issue"("p_warehouse_id" "uuid", "p_project_label" "text", "p_voucher_no" "text", "p_received_by_name" "text", "p_approved_by_name" "text", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_invoice_approval_decision"("p_invoice_request_id" "uuid", "p_decision" "text", "p_comment" "text" DEFAULT NULL::"text", "p_acting_on_behalf_of" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("out_invoice_request_id" "uuid", "out_status" "text", "out_stage_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_invoice       invoice_requests%rowtype;
  v_stage         workflow_stages%rowtype;
  v_next_stage    workflow_stages%rowtype;
  v_next_stage_id uuid;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid decision: %', p_decision;
  END IF;

  SELECT * INTO v_invoice FROM invoice_requests WHERE id = p_invoice_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invoice request not found';
  END IF;
  IF v_invoice.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this invoice request';
  END IF;
  IF v_invoice.status != 'open' THEN
    RAISE EXCEPTION 'invoice request is not open (status: %)', v_invoice.status;
  END IF;
  IF v_invoice.current_stage_id IS NULL THEN
    RAISE EXCEPTION 'invoice request has no current stage';
  END IF;
  IF NOT can_act_on_stage(v_invoice.current_stage_id) THEN
    RAISE EXCEPTION 'not authorized to act on this stage';
  END IF;

  -- Submitter-block: the person who submitted the invoice may never
  -- approve/reject it themself, at any stage (belt-and-suspenders with the
  -- equivalent RLS policy, since this SECURITY DEFINER function does not
  -- go through RLS on its own).
  IF v_invoice.requester_id = auth.uid() THEN
    RAISE EXCEPTION 'you submitted this invoice -- a different reviewer must act on it';
  END IF;

  SELECT * INTO v_stage FROM workflow_stages WHERE id = v_invoice.current_stage_id;

  INSERT INTO approval_actions
    (invoice_request_id, workflow_stage_id, approver_id, acted_on_behalf_of, decision, comment)
  VALUES
    (p_invoice_request_id, v_stage.id, auth.uid(), p_acting_on_behalf_of, p_decision, p_comment);

  IF p_decision = 'rejected' THEN
    UPDATE invoice_requests SET status = 'rejected', updated_at = now() WHERE id = p_invoice_request_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    VALUES (
      v_invoice.tenant_id,
      v_invoice.requester_id,
      'invoice_rejected',
      'Invoice rejected',
      format('Your invoice for "%s" (%s) was rejected at the %s stage.', v_invoice.vendor_name, v_invoice.amount, v_stage.name),
      p_invoice_request_id
    );

    RETURN QUERY SELECT p_invoice_request_id, 'rejected'::text, v_stage.id;
    RETURN;
  END IF;

  IF v_stage.is_finance_terminal_stage THEN
    UPDATE invoice_requests
    SET status = 'closed', current_stage_id = NULL, updated_at = now()
    WHERE id = p_invoice_request_id;

    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    VALUES (
      v_invoice.tenant_id,
      v_invoice.requester_id,
      'invoice_closed',
      'Invoice closed',
      format('Your invoice for "%s" (%s) has been fully approved and closed.', v_invoice.vendor_name, v_invoice.amount),
      p_invoice_request_id
    );

    RETURN QUERY SELECT p_invoice_request_id, 'closed'::text, NULL::uuid;
    RETURN;
  END IF;

  IF v_stage.threshold_amount IS NOT NULL THEN
    IF v_invoice.amount <= v_stage.threshold_amount THEN
      v_next_stage_id := v_stage.next_stage_low_id;
    ELSE
      v_next_stage_id := v_stage.next_stage_high_id;
    END IF;
  ELSE
    v_next_stage_id := v_stage.next_stage_low_id;
  END IF;

  IF v_next_stage_id IS NULL THEN
    RAISE EXCEPTION 'stage % has no next stage configured', v_stage.name;
  END IF;

  SELECT * INTO v_next_stage FROM workflow_stages WHERE id = v_next_stage_id;

  IF v_next_stage.applies_to != 'invoices' THEN
    RAISE EXCEPTION 'stage % is not configured for the invoice workflow -- check workflow_stages config', v_next_stage.name;
  END IF;

  UPDATE invoice_requests
  SET current_stage_id = v_next_stage_id, updated_at = now()
  WHERE id = p_invoice_request_id;

  INSERT INTO notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
  SELECT DISTINCT
    v_invoice.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('An invoice for "%s" (%s) is awaiting your approval at the %s stage.', v_invoice.vendor_name, v_invoice.amount, v_next_stage.name),
    p_invoice_request_id
  FROM (
    SELECT aa.user_id AS recipient_id
    FROM approval_assignments aa
    WHERE aa.workflow_stage_id = v_next_stage_id

    UNION

    SELECT d.delegate_user_id AS recipient_id
    FROM approval_delegations d
    JOIN approval_assignments aa ON aa.user_id = d.delegator_user_id
    WHERE d.status = 'active'
      AND now() BETWEEN d.starts_at AND d.ends_at
      AND aa.workflow_stage_id = v_next_stage_id
      AND (d.workflow_stage_id IS NULL OR d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  RETURN QUERY SELECT p_invoice_request_id, 'open'::text, v_next_stage_id;
END;
$$;


ALTER FUNCTION "public"."record_invoice_approval_decision"("p_invoice_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."line_item_receipts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_request requests%ROWTYPE;
  v_line    request_line_items%ROWTYPE;
  v_already numeric;
  v_row     line_item_receipts%ROWTYPE;
BEGIN
  IF p_received_qty IS NULL OR p_received_qty <= 0 THEN
    RAISE EXCEPTION 'received quantity must be greater than zero';
  END IF;

  SELECT * INTO v_line FROM request_line_items WHERE id = p_line_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'line item not found';
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_line.request_id;
  IF v_request.tenant_id != get_my_tenant_id() THEN
    RAISE EXCEPTION 'not authorized for this request';
  END IF;
  IF v_request.status != 'closed' THEN
    RAISE EXCEPTION 'goods can only be received against a closed request (PO already generated)';
  END IF;
  IF NOT has_receipt_access() THEN
    RAISE EXCEPTION 'not authorized to record receipts';
  END IF;

  SELECT COALESCE(SUM(received_qty), 0) INTO v_already
  FROM line_item_receipts WHERE line_item_id = p_line_item_id;

  IF v_already + p_received_qty > v_line.quantity * 2 THEN
    RAISE EXCEPTION 'received quantity (%) is more than double what was ordered (%) -- check for a data entry error',
      v_already + p_received_qty, v_line.quantity;
  END IF;

  INSERT INTO line_item_receipts (line_item_id, received_qty, received_by, note)
  VALUES (p_line_item_id, p_received_qty, auth.uid(), p_note)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_warehouse_id" "uuid", "p_voucher_no" "text" DEFAULT NULL::"text", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."line_item_receipts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row public.line_item_receipts;
BEGIN
  v_row := public.record_line_item_receipt(p_line_item_id, p_received_qty, p_note);

  UPDATE line_item_receipts
  SET warehouse_id = p_warehouse_id, voucher_no = p_voucher_no
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_warehouse_id" "uuid", "p_voucher_no" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_po_pdf"("p_purchase_order_id" "uuid", "p_storage_path" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update purchase_orders po
  set pdf_storage_path = p_storage_path,
      pdf_generated_at = now()
  from requests r
  where po.id = p_purchase_order_id
    and po.request_id = r.id
    and r.tenant_id = get_my_tenant_id();

  if not found then
    raise exception 'Purchase order not found or not accessible';
  end if;
end;
$$;


ALTER FUNCTION "public"."record_po_pdf"("p_purchase_order_id" "uuid", "p_storage_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_ticket_approval"("p_ticket_id" "uuid", "p_decision" "text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."it_tickets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;
  if not is_it_support() then
    raise exception 'not authorized to approve tickets';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status != 'pending' then
    raise exception 'ticket is not pending approval';
  end if;

  update it_tickets
  set approval_status = p_decision,
      approved_by = auth.uid(),
      approved_at = now(),
      approval_notes = p_notes,
      status = case when p_decision = 'rejected' then 'closed' else status end,
      resolution_notes = case when p_decision = 'rejected'
        then coalesce(resolution_notes, 'Rejected at approval: ' || coalesce(p_notes, 'no reason given'))
        else resolution_notes end,
      closed_at = case when p_decision = 'rejected' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_ticket.tenant_id,
    v_ticket.requester_id,
    'ticket_approval_decision',
    'Ticket ' || v_ticket.ticket_number || ' ' || p_decision,
    format('Your ticket "%s" was %s.', v_ticket.subject, p_decision)
  );

  return v_ticket;
end;
$$;


ALTER FUNCTION "public"."record_ticket_approval"("p_ticket_id" "uuid", "p_decision" "text", "p_notes" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_request_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "material_type_id" "uuid",
    "material_group_id" "uuid",
    "external_material_group_id" "uuid",
    "unit" "text",
    "name" "text" NOT NULL,
    "description_tr" "text",
    "description_en" "text",
    "description_fr" "text",
    "old_material_code" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "rejection_message" "text",
    "material_catalog_id" "uuid",
    "decided_by" "uuid",
    "decided_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "material_request_items_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."material_request_items" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_all_material_request_items"("p_batch_id" "uuid", "p_message" "text") RETURNS SETOF "public"."material_request_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_item_id uuid;
begin
  for v_item_id in
    select id from material_request_items
    where batch_id = p_batch_id and tenant_id = get_my_tenant_id() and status = 'pending'
  loop
    return next reject_material_request_item(v_item_id, p_message);
  end loop;
end;
$$;


ALTER FUNCTION "public"."reject_all_material_request_items"("p_batch_id" "uuid", "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_material_request_item"("p_item_id" "uuid", "p_message" "text") RETURNS "public"."material_request_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_item material_request_items%rowtype;
  v_batch material_request_batches%rowtype;
begin
  if not has_po_access() then
    raise exception 'not authorized to reject material requests';
  end if;

  if p_message is null or trim(p_message) = '' then
    raise exception 'a message is required to reject a material request item';
  end if;

  select * into v_item from material_request_items
  where id = p_item_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'material request item not found';
  end if;

  if v_item.status <> 'pending' then
    raise exception 'this item has already been decided';
  end if;

  update material_request_items
  set status = 'rejected', rejection_message = trim(p_message), decided_by = auth.uid(), decided_at = now()
  where id = p_item_id
  returning * into v_item;

  select * into v_batch from material_request_batches where id = v_item.batch_id;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_item.tenant_id, v_batch.requester_id, 'material_request_rejected',
    'Material request rejected',
    format('"%s" was rejected: %s', v_item.name, trim(p_message))
  );

  return v_item;
end;
$$;


ALTER FUNCTION "public"."reject_material_request_item"("p_item_id" "uuid", "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_payroll_run"("p_run_id" "uuid", "p_reason" "text") RETURNS "public"."hr_payroll_runs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_payroll_approver() THEN
    RAISE EXCEPTION 'not authorized to reject payroll';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a rejection reason is required';
  END IF;

  -- Sent back to draft (not a separate 'rejected' limbo) so HR can fix
  -- and resubmit through the same path -- rejected_* columns keep the
  -- audit trail of the fact it happened.
  UPDATE hr_payroll_runs
  SET status = 'draft', rejected_by = auth.uid(), rejected_at = now(), rejection_reason = p_reason,
      submitted_at = NULL
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'pending_approval'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not pending approval';
  END IF;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."reject_payroll_run"("p_run_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_group_member"("p_group_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage group membership';
  end if;
  delete from user_group_members
  where group_id = p_group_id and user_id = p_user_id
    and group_id in (select id from user_groups where tenant_id = get_my_tenant_id());
end;
$$;


ALTER FUNCTION "public"."remove_group_member"("p_group_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to manage team membership';
  end if;
  delete from support_team_members
  where team_id = p_team_id and user_id = p_user_id
    and team_id in (select id from support_teams where tenant_id = get_my_tenant_id());
end;
$$;


ALTER FUNCTION "public"."remove_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_or_create_vendor_account"("p_tenant_id" "uuid", "p_vendor_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_account_id uuid;
  v_next_num   int;
  v_code       text;
begin
  if p_vendor_name is null or trim(p_vendor_name) = '' then
    return null;
  end if;

  select id into v_account_id
  from accounts
  where tenant_id = p_tenant_id
    and account_type in ('vendor', 'both')
    and lower(trim(name)) = lower(trim(p_vendor_name))
  limit 1;

  if found then
    return v_account_id;
  end if;

  select coalesce(max(nullif(regexp_replace(account_code, '^VEN-', ''), account_code)::int), 0) + 1
  into v_next_num
  from accounts
  where tenant_id = p_tenant_id
    and account_code like 'VEN-%';

  v_code := 'VEN-' || lpad(v_next_num::text, 4, '0');

  insert into accounts (tenant_id, account_code, name, account_type, is_active)
  values (p_tenant_id, v_code, trim(p_vendor_name), 'vendor', true)
  returning id into v_account_id;

  return v_account_id;
end;
$$;


ALTER FUNCTION "public"."resolve_or_create_vendor_account"("p_tenant_id" "uuid", "p_vendor_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."return_asset"("p_assignment_id" "uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."asset_assignments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_assignment public.asset_assignments%rowtype;
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to return assets';
  end if;
  select * into v_assignment from asset_assignments where id = p_assignment_id for update;
  if not found then
    raise exception 'assignment not found';
  end if;
  if v_assignment.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this assignment';
  end if;
  if v_assignment.returned_at is not null then
    raise exception 'assignment already returned';
  end if;

  update asset_assignments
  set returned_at = now(),
      notes = coalesce(p_notes, notes)
  where id = p_assignment_id
  returning * into v_assignment;

  update assets set status = 'in_stock', updated_at = now()
  where id = v_assignment.asset_id
  returning * into v_asset;

  return v_assignment;
end;
$$;


ALTER FUNCTION "public"."return_asset"("p_assignment_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_invitation invitations%rowtype;
  v_caller_is_platform_admin boolean;
  v_caller_tenant_id uuid;
begin
  select * into v_invitation
  from invitations
  where id = p_invitation_id;

  if not found then
    raise exception 'Invitation not found';
  end if;

  v_caller_is_platform_admin := is_platform_admin();
  v_caller_tenant_id := get_my_tenant_id();

  if not (
    v_caller_is_platform_admin
    or (
      v_invitation.role_bundle = 'member'
      and v_invitation.tenant_id = v_caller_tenant_id
      and exists (
        select 1 from staff_roles
        where user_id = auth.uid()
          and tenant_id = v_invitation.tenant_id
          and role = 'admin'
      )
    )
  ) then
    raise exception 'Not authorized to revoke this invitation';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Only pending invitations can be revoked (this one is %)', v_invitation.status;
  end if;

  update invitations set status = 'revoked' where id = p_invitation_id;
end;
$$;


ALTER FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_receipt_access"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT is_finance_team_member('finance') THEN
    RAISE EXCEPTION 'not authorized to revoke material receipt access';
  END IF;

  DELETE FROM material_receipt_assignments
  WHERE tenant_id = get_my_tenant_id() AND user_id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."revoke_receipt_access"("p_user_id" "uuid") OWNER TO "postgres";


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
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Procurement: Offer Entry', 3, 'Procurement/Logistics Expert')
    returning id into v_stage_offer;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount)
    values (p_tenant_id, 'Control Chief/Manager', 4, 'Procurement & Logistics Chief', 5000000.00)
    returning id into v_stage_chief;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Finance', 5, 'Finance Officer')
    returning id into v_stage_finance;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Project Manager', 6, 'Project Manager')
    returning id into v_stage_pm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Deputy General Manager', 7, 'Deputy General Manager')
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


ALTER FUNCTION "public"."seed_tenant_defaults"("p_tenant_id" "uuid", "p_industry_template" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_account_category_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_account_category_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_asset_tag"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if NEW.asset_tag is null then
    NEW.asset_tag := next_asset_tag(NEW.tenant_id);
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_asset_tag"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_cash_bank_transaction_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_cash_bank_transaction_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_cost_center_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();

  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'could not determine tenant_id for current user';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_cost_center_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_department_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_department_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_expenditure_slip_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_expenditure_slip_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_invoice_request_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."set_invoice_request_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_material_lookup_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_material_lookup_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_material_request_batch_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  if NEW.requester_id is null then
    NEW.requester_id := auth.uid();
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_material_request_batch_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_material_request_item_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  select tenant_id into NEW.tenant_id from material_request_batches where id = NEW.batch_id;
  if NEW.tenant_id is null then
    raise exception 'batch not found or has no tenant';
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_material_request_item_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_organization_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_organization_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_petty_cash_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  new.tenant_id := get_my_tenant_id();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_petty_cash_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_problem_number"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if NEW.problem_number is null then
    NEW.problem_number := next_problem_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_problem_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_receivable_invoice_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_receivable_invoice_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_request_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."set_request_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_request_mr_number"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if NEW.mr_number is null then
    NEW.mr_number := next_mr_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_request_mr_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_sap_payment_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  SELECT tenant_id INTO NEW.tenant_id
  FROM purchase_orders
  WHERE id = NEW.purchase_order_id;

  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'purchase_order_id % not found or has no tenant_id', NEW.purchase_order_id;
  END IF;

  NEW.recorded_by := auth.uid();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_sap_payment_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_supplier_invoice_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_supplier_invoice_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_tenant_modules"("p_tenant_id" "uuid", "p_modules" "text"[]) RETURNS SETOF "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can change a company''s modules';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  delete from tenant_modules
  where tenant_id = p_tenant_id
    and module != all(coalesce(p_modules, array[]::text[]));

  insert into tenant_modules (tenant_id, module, enabled_by)
  select p_tenant_id, m, auth.uid()
  from unnest(coalesce(p_modules, array[]::text[])) as m
  on conflict (tenant_id, module) do nothing;

  return query select module from tenant_modules where tenant_id = p_tenant_id order by module;
end;
$$;


ALTER FUNCTION "public"."set_tenant_modules"("p_tenant_id" "uuid", "p_modules" "text"[]) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "industry_template" "text" DEFAULT 'general'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    CONSTRAINT "tenants_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'suspended'::"text"])))
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


COMMENT ON COLUMN "public"."tenants"."id" IS 'Note: 00000000-0000-0000-0000-000000000099 is the reserved platform-admin home tenant, not a business tenant.';



CREATE OR REPLACE FUNCTION "public"."set_tenant_status"("p_tenant_id" "uuid", "p_status" "text") RETURNS "public"."tenants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.tenants;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can change a company''s status';
  end if;

  if p_status not in ('active', 'suspended') then
    raise exception 'status must be active or suspended (pending is set automatically)';
  end if;

  update tenants
  set status = p_status
  where id = p_tenant_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'tenant not found';
  end if;

  return v_row;
end;
$$;


ALTER FUNCTION "public"."set_tenant_status"("p_tenant_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_ticket_number"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if NEW.ticket_number is null then
    NEW.ticket_number := next_ticket_number(NEW.tenant_id);
  end if;
  if NEW.category = 'Access' then
    NEW.requires_approval := true;
    NEW.approval_status := 'pending';
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_ticket_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_warehouse_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();
  NEW.created_by := COALESCE(NEW.created_by, auth.uid());
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_warehouse_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."share_purchase_order"("p_purchase_order_id" "uuid") RETURNS "public"."purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_po purchase_orders%ROWTYPE;
  v_request requests%ROWTYPE;
  v_offer_submitter uuid;
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
    RAISE EXCEPTION 'not authorized to share this purchase order';
  END IF;

  IF v_po.shared_with_supplier THEN
    RETURN v_po;
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = v_po.request_id;

  UPDATE purchase_orders
  SET shared_with_supplier = true
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_po;

  SELECT submitted_by INTO v_offer_submitter
  FROM request_offers
  WHERE request_id = v_po.request_id AND is_selected
  LIMIT 1;

  IF v_offer_submitter IS NOT NULL THEN
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    VALUES (
      v_request.tenant_id,
      v_offer_submitter,
      'po_shared',
      'PO shared with supplier',
      format('PO %s shared with %s. You can proceed.', v_po.po_number, v_po.vendor_name),
      v_request.id,
      v_po.id
    );
  END IF;

  RETURN v_po;
END;
$$;


ALTER FUNCTION "public"."share_purchase_order"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."impersonation_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "platform_admin_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ended_at" timestamp with time zone
);


ALTER TABLE "public"."impersonation_sessions" OWNER TO "postgres";


COMMENT ON TABLE "public"."impersonation_sessions" IS 'Tenant-level impersonation for platform admins. get_my_tenant_id() checks this first -- see that function''s definition.';



CREATE OR REPLACE FUNCTION "public"."start_impersonation"("p_tenant_id" "uuid") RETURNS "public"."impersonation_sessions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_session impersonation_sessions;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can start impersonation';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'No such tenant';
  end if;

  -- Close any stale/dangling session for this admin first.
  update impersonation_sessions
  set ended_at = now()
  where platform_admin_id = auth.uid() and ended_at is null;

  insert into impersonation_sessions (platform_admin_id, tenant_id)
  values (auth.uid(), p_tenant_id)
  returning * into v_session;

  insert into impersonation_logs (platform_admin_id, platform_admin_email, tenant_id, action)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_tenant_id, 'start');

  return v_session;
end;
$$;


ALTER FUNCTION "public"."start_impersonation"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "requester_id" "uuid" NOT NULL,
    "department_id" "uuid" NOT NULL,
    "cost_center_id" "uuid",
    "current_stage_id" "uuid",
    "item_description" "text" NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "replaces_request_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivery_date" "date",
    "subcontractor" "text",
    "organization_id" "uuid",
    "mr_number" "text" NOT NULL,
    CONSTRAINT "requests_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'rejected'::"text", 'closed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."requests" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_offers_for_approval"("p_request_id" "uuid") RETURNS "public"."requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_request     requests%rowtype;
  v_stage       workflow_stages%rowtype;
  v_next_stage  workflow_stages%rowtype;
  v_offer_count int;
begin
  select * into v_request from requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'open' then
    raise exception 'request is not open (status: %)', v_request.status;
  end if;

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;
  if not v_stage.requires_offer_entry then
    raise exception 'this request is not at an offer-entry stage';
  end if;
  if not can_act_on_stage(v_stage.id) then
    raise exception 'not authorized to submit offers on this request';
  end if;

  select count(*) into v_offer_count from request_offers where request_id = p_request_id;
  if v_offer_count < 2 then
    raise exception 'at least 2 competing offers are required before sending to Budget Controller (currently %)', v_offer_count;
  end if;

  if v_stage.next_stage_low_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  update requests
  set current_stage_id = v_stage.next_stage_low_id, updated_at = now()
  where id = p_request_id
  returning * into v_request;

  select * into v_next_stage from workflow_stages where id = v_stage.next_stage_low_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select distinct
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Offers submitted -- approval needed',
    format('%s competing offers were submitted for request "%s" and are awaiting your review.',
           v_offer_count, v_request.item_description),
    p_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage.id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage.id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage.id)
  ) recipients;

  return v_request;
end;
$$;


ALTER FUNCTION "public"."submit_offers_for_approval"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_payroll_run"("p_run_id" "uuid") RETURNS "public"."hr_payroll_runs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row hr_payroll_runs%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to submit payroll';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM hr_payroll_items WHERE payroll_run_id = p_run_id) THEN
    RAISE EXCEPTION 'cannot submit a payroll run with no line items';
  END IF;

  UPDATE hr_payroll_runs
  SET status = 'pending_approval', submitted_at = now()
  WHERE id = p_run_id AND tenant_id = get_my_tenant_id() AND status = 'draft'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll run not found, or not in draft';
  END IF;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."submit_payroll_run"("p_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_request_with_line_items"("p_item_description" "text", "p_quantity" integer, "p_cost_center_id" "uuid", "p_delivery_date" "date", "p_subcontractor" "text", "p_line_items" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_request_id uuid;
  v_item jsonb;
BEGIN
  IF p_line_items IS NULL OR jsonb_array_length(p_line_items) = 0 THEN
    RAISE EXCEPTION 'at least one line item is required';
  END IF;

  -- tenant_id, requester_id, department_id, status, current_stage_id are all
  -- set server-side by trg_set_request_defaults, same as a direct insert.
  INSERT INTO requests (item_description, quantity, cost_center_id, delivery_date, subcontractor)
  VALUES (p_item_description, p_quantity, p_cost_center_id, p_delivery_date, p_subcontractor)
  RETURNING id INTO v_request_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items)
  LOOP
    IF NULLIF(v_item->>'material_service', '') IS NULL THEN
      RAISE EXCEPTION 'each line item requires material_service';
    END IF;

    INSERT INTO request_line_items (
      request_id, material_service, cost_code, group_code, place_of_use,
      quantity, unit_price, currency
    )
    VALUES (
      v_request_id,
      v_item->>'material_service',
      NULLIF(v_item->>'cost_code', ''),
      NULLIF(v_item->>'group_code', ''),
      NULLIF(v_item->>'place_of_use', ''),
      (v_item->>'quantity')::numeric,
      NULLIF(v_item->>'unit_price', '')::numeric,
      COALESCE(NULLIF(v_item->>'currency', ''), 'UGX')
    );
  END LOOP;

  RETURN v_request_id;
END;
$$;


ALTER FUNCTION "public"."submit_request_with_line_items"("p_item_description" "text", "p_quantity" integer, "p_cost_center_id" "uuid", "p_delivery_date" "date", "p_subcontractor" "text", "p_line_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."supplier_invoice_outstanding"("p_invoice_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select si.amount_incl_vat
    - coalesce((select sum(cbt.amount) from cash_bank_transactions cbt
                where cbt.reference_type = 'supplier_invoice' and cbt.reference_id = si.id), 0)
    - coalesce((select sum(apa.applied_amount) from advance_payment_applications apa
                where apa.reference_type = 'supplier_invoice' and apa.reference_id = si.id), 0)
  from supplier_invoices si
  where si.id = p_invoice_id;
$$;


ALTER FUNCTION "public"."supplier_invoice_outstanding"("p_invoice_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."supplier_invoice_payable_now"("p_invoice_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT GREATEST(0,
    LEAST(
      supplier_invoice_receipt_cap(p_invoice_id) - (si.amount_incl_vat - supplier_invoice_outstanding(p_invoice_id)),
      supplier_invoice_outstanding(p_invoice_id)
    )
  )
  FROM supplier_invoices si WHERE si.id = p_invoice_id;
$$;


ALTER FUNCTION "public"."supplier_invoice_payable_now"("p_invoice_id" "uuid") OWNER TO "postgres";


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


ALTER FUNCTION "public"."supplier_invoice_receipt_cap"("p_invoice_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."try_complete_po"("p_purchase_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."try_complete_po"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unlink_ticket_from_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support() then
    raise exception 'not authorized to unlink tickets from problems';
  end if;
  delete from problem_tickets
  where problem_id = p_problem_id and ticket_id = p_ticket_id and tenant_id = get_my_tenant_id();
end;
$$;


ALTER FUNCTION "public"."unlink_ticket_from_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_users" (
    "id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "department_id" "uuid",
    "name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "role_title" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_platform_admin" boolean DEFAULT false NOT NULL,
    "is_company_admin" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."app_users" OWNER TO "postgres";


COMMENT ON COLUMN "public"."app_users"."is_company_admin" IS 'True for the tenant''s overall company admin (accepted a company_admin-bundle invite). Distinct from staff_roles admin rows, which are per-module. Used to gate who may invite new members (see invite-user edge function) -- module admins may no longer invite; only the company admin (or a platform admin) can.';



CREATE OR REPLACE FUNCTION "public"."update_app_user"("p_user_id" "uuid", "p_department_id" "uuid" DEFAULT NULL::"uuid", "p_role_title" "text" DEFAULT NULL::"text", "p_is_platform_admin" boolean DEFAULT NULL::boolean) RETURNS "public"."app_users"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user public.app_users%rowtype;
  v_caller public.app_users%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage accounts';
  end if;
  select * into v_caller from app_users where id = auth.uid();
  select * into v_user from app_users where id = p_user_id for update;
  if not found or v_user.tenant_id != get_my_tenant_id() then
    raise exception 'user not found';
  end if;
  if p_is_platform_admin is not null and not v_caller.is_platform_admin then
    raise exception 'only a platform admin can change platform admin status';
  end if;

  update app_users
  set department_id = coalesce(p_department_id, department_id),
      role_title = coalesce(p_role_title, role_title),
      is_platform_admin = coalesce(p_is_platform_admin, is_platform_admin)
  where id = p_user_id
  returning * into v_user;

  return v_user;
end;
$$;


ALTER FUNCTION "public"."update_app_user"("p_user_id" "uuid", "p_department_id" "uuid", "p_role_title" "text", "p_is_platform_admin" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_asset"("p_asset_id" "uuid", "p_name" "text" DEFAULT NULL::"text", "p_category" "text" DEFAULT NULL::"text", "p_serial_number" "text" DEFAULT NULL::"text", "p_vendor" "text" DEFAULT NULL::"text", "p_purchase_cost" numeric DEFAULT NULL::numeric, "p_status" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."assets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_asset public.assets%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update assets';
  end if;
  select * into v_asset from assets where id = p_asset_id for update;
  if not found then
    raise exception 'asset not found';
  end if;
  if v_asset.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this asset';
  end if;
  -- 'assigned' status is only set via assign_asset/return_asset, not here
  if p_status is not null and p_status not in ('in_stock','maintenance','retired') then
    raise exception 'invalid status for direct update: %', p_status;
  end if;
  if p_status is not null and v_asset.status = 'assigned' then
    raise exception 'asset is currently assigned; return it before changing status';
  end if;

  update assets
  set name = coalesce(p_name, name),
      category = coalesce(p_category, category),
      serial_number = coalesce(p_serial_number, serial_number),
      vendor = coalesce(p_vendor, vendor),
      purchase_cost = coalesce(p_purchase_cost, purchase_cost),
      status = coalesce(p_status, status),
      notes = coalesce(p_notes, notes),
      updated_at = now()
  where id = p_asset_id
  returning * into v_asset;

  return v_asset;
end;
$$;


ALTER FUNCTION "public"."update_asset"("p_asset_id" "uuid", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_cost" numeric, "p_status" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_faq"("p_faq_id" "uuid", "p_question" "text" DEFAULT NULL::"text", "p_answer" "text" DEFAULT NULL::"text", "p_category" "text" DEFAULT NULL::"text", "p_sort_order" integer DEFAULT NULL::integer, "p_is_published" boolean DEFAULT NULL::boolean) RETURNS "public"."faqs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_faq public.faqs%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update FAQ entries';
  end if;
  select * into v_faq from faqs where id = p_faq_id for update;
  if not found or v_faq.tenant_id != get_my_tenant_id() then
    raise exception 'FAQ not found';
  end if;

  update faqs
  set question = coalesce(p_question, question),
      answer = coalesce(p_answer, answer),
      category = coalesce(p_category, category),
      sort_order = coalesce(p_sort_order, sort_order),
      is_published = coalesce(p_is_published, is_published),
      updated_at = now()
  where id = p_faq_id
  returning * into v_faq;

  return v_faq;
end;
$$;


ALTER FUNCTION "public"."update_faq"("p_faq_id" "uuid", "p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_kb_article"("p_article_id" "uuid", "p_title" "text" DEFAULT NULL::"text", "p_content" "text" DEFAULT NULL::"text", "p_category" "text" DEFAULT NULL::"text", "p_is_published" boolean DEFAULT NULL::boolean) RETURNS "public"."kb_articles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_article public.kb_articles%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update knowledge base articles';
  end if;
  select * into v_article from kb_articles where id = p_article_id for update;
  if not found or v_article.tenant_id != get_my_tenant_id() then
    raise exception 'article not found';
  end if;

  update kb_articles
  set title = coalesce(p_title, title),
      content = coalesce(p_content, content),
      category = coalesce(p_category, category),
      is_published = coalesce(p_is_published, is_published),
      updated_at = now()
  where id = p_article_id
  returning * into v_article;

  return v_article;
end;
$$;


ALTER FUNCTION "public"."update_kb_article"("p_article_id" "uuid", "p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_license"("p_license_id" "uuid", "p_license_key" "text" DEFAULT NULL::"text", "p_seats_total" integer DEFAULT NULL::integer, "p_vendor" "text" DEFAULT NULL::"text", "p_expiry_date" "date" DEFAULT NULL::"date", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."licenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_license public.licenses%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update licenses';
  end if;
  select * into v_license from licenses where id = p_license_id for update;
  if not found then
    raise exception 'license not found';
  end if;
  if v_license.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this license';
  end if;

  update licenses
  set license_key = coalesce(p_license_key, license_key),
      seats_total = coalesce(p_seats_total, seats_total),
      vendor = coalesce(p_vendor, vendor),
      expiry_date = coalesce(p_expiry_date, expiry_date),
      notes = coalesce(p_notes, notes),
      updated_at = now()
  where id = p_license_id
  returning * into v_license;

  return v_license;
end;
$$;


ALTER FUNCTION "public"."update_license"("p_license_id" "uuid", "p_license_key" "text", "p_seats_total" integer, "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_payroll_item"("p_item_id" "uuid", "p_allowances" numeric, "p_deductions" numeric, "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."hr_payroll_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row hr_payroll_items%ROWTYPE;
BEGIN
  IF NOT is_hr_team_member() THEN
    RAISE EXCEPTION 'not authorized to edit payroll';
  END IF;

  UPDATE hr_payroll_items i
  SET allowances = p_allowances, deductions = p_deductions, note = p_note
  FROM hr_payroll_runs r
  WHERE i.id = p_item_id
    AND r.id = i.payroll_run_id
    AND r.tenant_id = get_my_tenant_id()
    AND r.status = 'draft'
  RETURNING i.* INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'payroll item not found, or run is no longer in draft';
  END IF;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."update_payroll_item"("p_item_id" "uuid", "p_allowances" numeric, "p_deductions" numeric, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_priority_level"("p_code" "text", "p_label" "text" DEFAULT NULL::"text", "p_color" "text" DEFAULT NULL::"text") RETURNS "public"."priority_levels"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.priority_levels%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage priority levels';
  end if;
  update priority_levels
  set label = coalesce(p_label, label), color = coalesce(p_color, color)
  where code = p_code and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'priority level not found';
  end if;
  return v_row;
end;
$$;


ALTER FUNCTION "public"."update_priority_level"("p_code" "text", "p_label" "text", "p_color" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_problem"("p_problem_id" "uuid", "p_status" "text" DEFAULT NULL::"text", "p_root_cause" "text" DEFAULT NULL::"text", "p_assigned_to" "uuid" DEFAULT NULL::"uuid", "p_title" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text") RETURNS "public"."problems"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_problem public.problems%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update problems';
  end if;
  select * into v_problem from problems where id = p_problem_id for update;
  if not found then
    raise exception 'problem not found';
  end if;
  if v_problem.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this problem';
  end if;
  if p_status is not null and p_status not in ('open','investigating','resolved','closed') then
    raise exception 'invalid status: %', p_status;
  end if;

  update problems
  set status = coalesce(p_status, status),
      root_cause = coalesce(p_root_cause, root_cause),
      assigned_to = coalesce(p_assigned_to, assigned_to),
      title = coalesce(p_title, title),
      description = coalesce(p_description, description),
      resolved_at = case when p_status = 'resolved' and resolved_at is null then now() else resolved_at end,
      closed_at = case when p_status = 'closed' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_problem_id
  returning * into v_problem;

  return v_problem;
end;
$$;


ALTER FUNCTION "public"."update_problem"("p_problem_id" "uuid", "p_status" "text", "p_root_cause" "text", "p_assigned_to" "uuid", "p_title" "text", "p_description" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_support_team"("p_id" "uuid", "p_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "public"."support_teams"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage support teams';
  end if;
  update support_teams
  set name = coalesce(p_name, name), description = coalesce(p_description, description), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'support team not found';
  end if;
  return v_row;
end;
$$;


ALTER FUNCTION "public"."update_support_team"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_ticket_category"("p_id" "uuid", "p_name" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "public"."ticket_categories"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  update ticket_categories
  set name = coalesce(p_name, name), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'ticket category not found';
  end if;
  return v_row;
end;
$$;


ALTER FUNCTION "public"."update_ticket_category"("p_id" "uuid", "p_name" "text", "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_ticket_status"("p_ticket_id" "uuid", "p_status" "text", "p_resolution_notes" "text" DEFAULT NULL::"text") RETURNS "public"."it_tickets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if p_status not in ('open','in_progress','resolved','closed') then
    raise exception 'invalid status: %', p_status;
  end if;
  if not is_it_support() then
    raise exception 'not authorized to update ticket status';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status = 'pending' and p_status = 'in_progress' then
    raise exception 'ticket is awaiting approval and cannot be actioned yet';
  end if;

  update it_tickets
  set status = p_status,
      resolution_notes = coalesce(p_resolution_notes, resolution_notes),
      resolved_at = case when p_status = 'resolved' and resolved_at is null then now() else resolved_at end,
      closed_at = case when p_status = 'closed' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_ticket.tenant_id,
    v_ticket.requester_id,
    'ticket_status_changed',
    'Ticket ' || v_ticket.ticket_number || ' updated',
    format('Your ticket "%s" is now %s.', v_ticket.subject, p_status)
  );

  return v_ticket;
end;
$$;


ALTER FUNCTION "public"."update_ticket_status"("p_ticket_id" "uuid", "p_status" "text", "p_resolution_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_workflow_stage_threshold"("p_stage_id" "uuid", "p_threshold_amount" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_current numeric(14, 2);
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can edit workflow stage thresholds';
  end if;

  if p_threshold_amount is null or p_threshold_amount < 0 then
    raise exception 'threshold_amount must be a non-negative number';
  end if;

  select threshold_amount into v_current
  from workflow_stages
  where id = p_stage_id;

  if not found then
    raise exception 'workflow stage not found';
  end if;

  if v_current is null then
    raise exception 'this stage has no threshold branch to edit';
  end if;

  update workflow_stages
  set threshold_amount = p_threshold_amount
  where id = p_stage_id;
end;
$$;


ALTER FUNCTION "public"."update_workflow_stage_threshold"("p_stage_id" "uuid", "p_threshold_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_sla_policy"("p_priority" "text", "p_target_hours" integer, "p_description" "text" DEFAULT NULL::"text") RETURNS "public"."sla_policies"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.sla_policies%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to manage SLA policies';
  end if;
  if p_priority not in ('low','medium','high','urgent') then
    raise exception 'invalid priority: %', p_priority;
  end if;

  insert into sla_policies (tenant_id, priority, target_hours, description)
  values (get_my_tenant_id(), p_priority, p_target_hours, p_description)
  on conflict (tenant_id, priority)
  do update set target_hours = excluded.target_hours, description = excluded.description, updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;


ALTER FUNCTION "public"."upsert_sla_policy"("p_priority" "text", "p_target_hours" integer, "p_description" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."account_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."account_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "account_code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "account_type" "text" NOT NULL,
    "contact_name" "text",
    "contact_phone" "text",
    "contact_email" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "category_id" "uuid",
    "tax_id" "text",
    "business_registration_number" "text",
    "license_number" "text",
    "license_expiry" "date",
    "address" "text",
    "bank_name" "text",
    "bank_account_name" "text",
    "bank_account_number" "text",
    "bank_branch" "text",
    "swift_code" "text",
    CONSTRAINT "accounts_account_type_check" CHECK (("account_type" = ANY (ARRAY['vendor'::"text", 'client'::"text", 'both'::"text"])))
);


ALTER TABLE "public"."accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."advance_payment_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "advance_payment_id" "uuid" NOT NULL,
    "reference_type" "text" NOT NULL,
    "reference_id" "uuid" NOT NULL,
    "applied_amount" numeric NOT NULL,
    "applied_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "applied_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    CONSTRAINT "advance_payment_applications_applied_amount_check" CHECK (("applied_amount" > (0)::numeric)),
    CONSTRAINT "advance_payment_applications_reference_type_check" CHECK (("reference_type" = ANY (ARRAY['supplier_invoice'::"text", 'receivable_invoice'::"text"])))
);


ALTER TABLE "public"."advance_payment_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."advance_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "account_id" "uuid" NOT NULL,
    "direction" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "payment_method" "text" NOT NULL,
    "bank_account" "text",
    "payment_date" "date" NOT NULL,
    "description" "text",
    "recorded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "advance_payments_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "advance_payments_direction_check" CHECK (("direction" = ANY (ARRAY['payment'::"text", 'receipt'::"text"]))),
    CONSTRAINT "advance_payments_payment_method_check" CHECK (("payment_method" = ANY (ARRAY['cash'::"text", 'bank'::"text"])))
);


ALTER TABLE "public"."advance_payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."approval_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid",
    "workflow_stage_id" "uuid" NOT NULL,
    "approver_id" "uuid" NOT NULL,
    "acted_on_behalf_of" "uuid",
    "decision" "text" NOT NULL,
    "comment" "text",
    "acted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "invoice_request_id" "uuid",
    CONSTRAINT "approval_actions_decision_check" CHECK (("decision" = ANY (ARRAY['approved'::"text", 'rejected'::"text"]))),
    CONSTRAINT "approval_actions_exactly_one_target" CHECK (((("request_id" IS NOT NULL) AND ("invoice_request_id" IS NULL)) OR (("request_id" IS NULL) AND ("invoice_request_id" IS NOT NULL))))
);


ALTER TABLE "public"."approval_actions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."approval_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "workflow_stage_id" "uuid" NOT NULL,
    "scope_type" "text" DEFAULT 'global'::"text" NOT NULL,
    "scope_id" "uuid",
    "threshold_max" numeric(14,2),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "approval_assignments_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['department'::"text", 'cost_center'::"text", 'global'::"text"])))
);


ALTER TABLE "public"."approval_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "client_id" "uuid",
    "type" "text" DEFAULT 'call'::"text" NOT NULL,
    "subject" "text" NOT NULL,
    "description" "text",
    "activity_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bd_activities_type_check" CHECK (("type" = ANY (ARRAY['call'::"text", 'email'::"text", 'meeting'::"text", 'note'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."bd_activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_client_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bd_client_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_clients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "category_id" "uuid",
    "industry" "text",
    "email" "text",
    "phone" "text",
    "website" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bd_clients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "client_id" "uuid" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "position" "text",
    "is_primary" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bd_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_lead_sources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bd_lead_sources" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_lead_statuses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "label" "text" NOT NULL,
    "color" "text" DEFAULT '#90caf9'::"text" NOT NULL,
    "order_index" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "bd_lead_statuses_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'contacted'::"text", 'qualified'::"text", 'unqualified'::"text", 'converted'::"text", 'lost'::"text"])))
);


ALTER TABLE "public"."bd_lead_statuses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "lead_no" "text",
    "company_name" "text" NOT NULL,
    "contact_name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "source_id" "uuid",
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "estimated_value" numeric(14,2),
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "notes" "text",
    "converted_opportunity_id" "uuid",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bd_leads_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'contacted'::"text", 'qualified'::"text", 'unqualified'::"text", 'converted'::"text", 'lost'::"text"])))
);


ALTER TABLE "public"."bd_leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_opportunities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "opportunity_no" "text",
    "title" "text" NOT NULL,
    "client_id" "uuid",
    "lead_id" "uuid",
    "stage" "text" DEFAULT 'identification'::"text" NOT NULL,
    "probability" integer,
    "estimated_value" numeric(14,2),
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "expected_close_date" "date",
    "description" "text",
    "lost_reason" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bd_opportunities_probability_check" CHECK ((("probability" >= 0) AND ("probability" <= 100))),
    CONSTRAINT "bd_opportunities_stage_check" CHECK (("stage" = ANY (ARRAY['identification'::"text", 'qualification'::"text", 'proposal'::"text", 'negotiation'::"text", 'closed_won'::"text", 'closed_lost'::"text"])))
);


ALTER TABLE "public"."bd_opportunities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_opportunity_stages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "stage" "text" NOT NULL,
    "label" "text" NOT NULL,
    "probability_default" integer DEFAULT 10 NOT NULL,
    "color" "text" DEFAULT '#90caf9'::"text" NOT NULL,
    "order_index" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "bd_opportunity_stages_probability_default_check" CHECK ((("probability_default" >= 0) AND ("probability_default" <= 100))),
    CONSTRAINT "bd_opportunity_stages_stage_check" CHECK (("stage" = ANY (ARRAY['identification'::"text", 'qualification'::"text", 'proposal'::"text", 'negotiation'::"text", 'closed_won'::"text", 'closed_lost'::"text"])))
);


ALTER TABLE "public"."bd_opportunity_stages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_proposal_statuses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "label" "text" NOT NULL,
    "color" "text" DEFAULT '#bdbdbd'::"text" NOT NULL,
    "order_index" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "bd_proposal_statuses_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'in_review'::"text", 'pending_approval'::"text", 'approved'::"text", 'sent'::"text", 'accepted'::"text", 'rejected'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."bd_proposal_statuses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_proposal_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "content" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bd_proposal_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_proposal_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bd_proposal_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_proposals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "proposal_no" "text",
    "title" "text" NOT NULL,
    "client_id" "uuid",
    "opportunity_id" "uuid",
    "type_id" "uuid",
    "total_value" numeric(14,2) NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "valid_until" "date",
    "content" "text",
    "decided_by" "uuid",
    "decided_at" timestamp with time zone,
    "decision_notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bd_proposals_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'in_review'::"text", 'pending_approval'::"text", 'approved'::"text", 'sent'::"text", 'accepted'::"text", 'rejected'::"text", 'expired'::"text"]))),
    CONSTRAINT "bd_proposals_total_value_check" CHECK (("total_value" > (0)::numeric))
);


ALTER TABLE "public"."bd_proposals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_tender_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bd_tender_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bd_tenders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "tender_no" "text",
    "title" "text" NOT NULL,
    "client_id" "uuid",
    "type_id" "uuid",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "submission_deadline" timestamp with time zone,
    "estimated_value" numeric(14,2),
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "portal_url" "text",
    "description" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bd_tenders_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'submitted'::"text", 'under_evaluation'::"text", 'awarded'::"text", 'lost'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."bd_tenders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cash_bank_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "transaction_type" "text" NOT NULL,
    "payment_method" "text" NOT NULL,
    "reference_type" "text" NOT NULL,
    "reference_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "transaction_date" "date" NOT NULL,
    "bank_account" "text",
    "description" "text",
    "recorded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "cash_bank_transactions_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "cash_bank_transactions_payment_method_check" CHECK (("payment_method" = ANY (ARRAY['cash'::"text", 'bank'::"text"]))),
    CONSTRAINT "cash_bank_transactions_reference_type_check" CHECK (("reference_type" = ANY (ARRAY['supplier_invoice'::"text", 'expenditure_slip'::"text", 'receivable_invoice'::"text", 'payroll_run'::"text"]))),
    CONSTRAINT "cash_bank_transactions_transaction_type_check" CHECK (("transaction_type" = ANY (ARRAY['payment'::"text", 'receipt'::"text"])))
);


ALTER TABLE "public"."cash_bank_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cost_centers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "project_code" "text",
    "budget_amount" numeric(14,2),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cost_centers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."departments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "parent_department_id" "uuid",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."departments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."doc_sequences" (
    "tenant_id" "uuid" NOT NULL,
    "doc_type" "text" NOT NULL,
    "year" "text" NOT NULL,
    "last_number" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."doc_sequences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expenditure_slips" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "cost_center_id" "uuid" NOT NULL,
    "slip_number" "text" NOT NULL,
    "slip_date" "date" NOT NULL,
    "payee_name" "text" NOT NULL,
    "purpose" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "recorded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "organization_id" "uuid",
    "petty_cash_float_id" "uuid",
    CONSTRAINT "expenditure_slips_amount_check" CHECK (("amount" > (0)::numeric))
);


ALTER TABLE "public"."expenditure_slips" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_material_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."external_material_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."finance_team_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "finance_team_members_role_check" CHECK (("role" = ANY (ARRAY['finance'::"text", 'cost_control'::"text"])))
);


ALTER TABLE "public"."finance_team_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fuel_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "machine_id" "uuid" NOT NULL,
    "log_date" "date" NOT NULL,
    "fuel_liters" numeric NOT NULL,
    "cost" numeric,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "fuel_logs_fuel_liters_check" CHECK (("fuel_liters" >= (0)::numeric))
);


ALTER TABLE "public"."fuel_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."goods_issue_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "goods_issue_id" "uuid" NOT NULL,
    "item_no" integer NOT NULL,
    "material_catalog_id" "uuid",
    "material_description" "text" NOT NULL,
    "cost_center_id" "uuid",
    "unit" "text" NOT NULL,
    "requested_qty" numeric,
    "delivered_qty" numeric NOT NULL,
    "remarks" "text",
    CONSTRAINT "goods_issue_items_delivered_qty_check" CHECK (("delivered_qty" > (0)::numeric)),
    CONSTRAINT "goods_issue_items_requested_qty_check" CHECK ((("requested_qty" IS NULL) OR ("requested_qty" >= (0)::numeric)))
);


ALTER TABLE "public"."goods_issue_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_appraisals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "period" "text" NOT NULL,
    "rating" integer,
    "comments" "text",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_appraisals_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 5))),
    CONSTRAINT "hr_appraisals_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'in_progress'::"text", 'completed'::"text", 'reviewed'::"text"])))
);


ALTER TABLE "public"."hr_appraisals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_attendance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "attendance_date" "date" NOT NULL,
    "check_in" timestamp with time zone,
    "check_out" timestamp with time zone,
    "status" "text" DEFAULT 'present'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_attendance_status_check" CHECK (("status" = ANY (ARRAY['present'::"text", 'absent'::"text", 'late'::"text", 'on_leave'::"text"])))
);


ALTER TABLE "public"."hr_attendance" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."hr_employee_current_compensation" WITH ("security_invoker"='true') AS
 SELECT DISTINCT ON ("employee_id") "employee_id",
    "tenant_id",
    "basic_salary",
    "currency",
    "effective_date",
    "contract_reference"
   FROM "public"."hr_employee_compensation"
  WHERE ("effective_date" <= CURRENT_DATE)
  ORDER BY "employee_id", "effective_date" DESC, "created_at" DESC;


ALTER VIEW "public"."hr_employee_current_compensation" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_employees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "employee_no" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "phone" "text",
    "department_id" "uuid",
    "position_id" "uuid",
    "manager_id" "uuid",
    "employment_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "hire_date" "date",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_employees_employment_status_check" CHECK (("employment_status" = ANY (ARRAY['active'::"text", 'on_leave'::"text", 'terminated'::"text", 'resigned'::"text"])))
);


ALTER TABLE "public"."hr_employees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_job_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "job_posting_id" "uuid",
    "candidate_name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "stage" "text" DEFAULT 'applied'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hr_job_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_job_postings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "department_id" "uuid",
    "position_id" "uuid",
    "description" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_job_postings_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'closed'::"text", 'on_hold'::"text"])))
);


ALTER TABLE "public"."hr_job_postings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_leave_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "leave_no" "text" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "leave_type_id" "uuid" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "days" integer NOT NULL,
    "reason" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "approver_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_leave_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."hr_leave_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_leave_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "days_per_year" integer DEFAULT 21 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hr_leave_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_positions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hr_positions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_team_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hr_team_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hr_trainings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "provider" "text",
    "start_date" "date",
    "end_date" "date",
    "status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hr_trainings_status_check" CHECK (("status" = ANY (ARRAY['planned'::"text", 'in_progress'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."hr_trainings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."impersonation_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "platform_admin_id" "uuid" NOT NULL,
    "platform_admin_email" "text",
    "tenant_id" "uuid",
    "action" "text" NOT NULL,
    "logged_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."impersonation_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invitations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "invited_by" "uuid" NOT NULL,
    "role_bundle" "text" DEFAULT 'company_admin'::"text" NOT NULL,
    "modules_and_roles" "jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "accepted_at" timestamp with time zone,
    "finance_role" "text",
    CONSTRAINT "invitations_finance_role_check" CHECK (("finance_role" = ANY (ARRAY['finance'::"text", 'cost_control'::"text"]))),
    CONSTRAINT "invitations_role_bundle_check" CHECK (("role_bundle" = ANY (ARRAY['company_admin'::"text", 'member'::"text"]))),
    CONSTRAINT "invitations_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'expired'::"text", 'revoked'::"text"])))
);


ALTER TABLE "public"."invitations" OWNER TO "postgres";


COMMENT ON TABLE "public"."invitations" IS 'Tracks invite lifecycle independently of auth.users. Rows are created by the invite-user edge function and consumed by accept-invite.';



COMMENT ON COLUMN "public"."invitations"."finance_role" IS 'Grants a finance_team_members row on accept. NULL for company_admin invites (implies ''finance'' automatically, same as modules_and_roles=null implying all 8 modules). For member invites: ''finance'' (view+write) or ''cost_control'' (view only), or NULL for no finance access.';



CREATE TABLE IF NOT EXISTS "public"."invoice_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "requester_id" "uuid" NOT NULL,
    "department_id" "uuid",
    "cost_center_id" "uuid",
    "current_stage_id" "uuid",
    "vendor_name" "text",
    "description" "text",
    "amount" numeric DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "invoice_requests_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "invoice_requests_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'rejected'::"text", 'closed'::"text"])))
);


ALTER TABLE "public"."invoice_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."law_case_hearings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "case_id" "uuid" NOT NULL,
    "hearing_date" timestamp with time zone NOT NULL,
    "location" "text",
    "outcome" "text",
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."law_case_hearings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."law_case_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."law_case_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."law_cases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "case_no" "text" NOT NULL,
    "title" "text" NOT NULL,
    "type_id" "uuid",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "description" "text",
    "lawyer_name" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "law_cases_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'in_progress'::"text", 'closed'::"text", 'on_hold'::"text"])))
);


ALTER TABLE "public"."law_cases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."law_compliance_register" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "item_no" "text" NOT NULL,
    "title" "text" NOT NULL,
    "regulation" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "due_date" "date",
    "owner_id" "uuid",
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "law_compliance_register_status_check" CHECK (("status" = ANY (ARRAY['compliant'::"text", 'non_compliant'::"text", 'pending'::"text", 'overdue'::"text"])))
);


ALTER TABLE "public"."law_compliance_register" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."law_contract_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."law_contract_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."law_contracts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "contract_no" "text" NOT NULL,
    "title" "text" NOT NULL,
    "type_id" "uuid",
    "party_name" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "start_date" "date",
    "end_date" "date",
    "value" numeric(14,2),
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "law_contracts_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'pending_approval'::"text", 'active'::"text", 'expired'::"text", 'terminated'::"text"])))
);


ALTER TABLE "public"."law_contracts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."law_regulatory_filings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "filing_type" "text",
    "reference_no" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "filing_date" "date",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "law_regulatory_filings_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'filed'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."law_regulatory_filings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."request_line_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "material_service" "text" NOT NULL,
    "cost_code" "text",
    "group_code" "text",
    "place_of_use" "text",
    "quantity" numeric NOT NULL,
    "unit_price" numeric,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total" numeric GENERATED ALWAYS AS (("quantity" * "unit_price")) STORED,
    CONSTRAINT "request_line_items_quantity_check" CHECK (("quantity" > (0)::numeric)),
    CONSTRAINT "request_line_items_unit_price_check" CHECK ((("unit_price" IS NULL) OR ("unit_price" >= (0)::numeric)))
);


ALTER TABLE "public"."request_line_items" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."line_item_receipt_status" WITH ("security_invoker"='true') AS
 SELECT "rli"."id" AS "line_item_id",
    "rli"."request_id",
    "rli"."material_service",
    "rli"."quantity" AS "ordered_qty",
    COALESCE("sum"("lir"."received_qty"), (0)::numeric) AS "received_qty",
        CASE
            WHEN (COALESCE("sum"("lir"."received_qty"), (0)::numeric) = (0)::numeric) THEN 'none'::"text"
            WHEN (COALESCE("sum"("lir"."received_qty"), (0)::numeric) < "rli"."quantity") THEN 'partial'::"text"
            WHEN (COALESCE("sum"("lir"."received_qty"), (0)::numeric) = "rli"."quantity") THEN 'full'::"text"
            ELSE 'over'::"text"
        END AS "receipt_status",
    "max"("lir"."received_at") AS "last_received_at"
   FROM ("public"."request_line_items" "rli"
     LEFT JOIN "public"."line_item_receipts" "lir" ON (("lir"."line_item_id" = "rli"."id")))
  GROUP BY "rli"."id", "rli"."request_id", "rli"."material_service", "rli"."quantity";


ALTER VIEW "public"."line_item_receipt_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."machine_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "machine_id" "uuid" NOT NULL,
    "project_name" "text",
    "operator_name" "text",
    "start_date" "date",
    "end_date" "date",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "machine_assignments_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."machine_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."machine_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."machine_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."machines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "machine_no" "text" NOT NULL,
    "name" "text" NOT NULL,
    "type_id" "uuid",
    "model" "text",
    "serial_number" "text",
    "status" "text" DEFAULT 'available'::"text" NOT NULL,
    "location" "text",
    "purchase_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "machines_status_check" CHECK (("status" = ANY (ARRAY['available'::"text", 'in_use'::"text", 'maintenance'::"text", 'retired'::"text", 'breakdown'::"text"])))
);


ALTER TABLE "public"."machines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."maintenance_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "machine_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "description" "text" NOT NULL,
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "requested_by" "uuid",
    "scheduled_date" "date",
    "completed_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "maintenance_requests_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'in_progress'::"text", 'completed'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "maintenance_requests_type_check" CHECK (("type" = ANY (ARRAY['preventive'::"text", 'corrective'::"text", 'inspection'::"text"])))
);


ALTER TABLE "public"."maintenance_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."maintenance_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."maintenance_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."material_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_request_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "requester_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."material_request_batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."material_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "request_id" "uuid",
    "purchase_order_id" "uuid",
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "invoice_request_id" "uuid"
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."oif_sequences" (
    "organization_id" "uuid" NOT NULL,
    "invoice_type" "text" NOT NULL,
    "last_number" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "oif_sequences_invoice_type_check" CHECK (("invoice_type" = ANY (ARRAY['supplier'::"text", 'receivable'::"text"])))
);


ALTER TABLE "public"."oif_sequences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."operation_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "machine_id" "uuid" NOT NULL,
    "log_date" "date" NOT NULL,
    "hours_used" numeric NOT NULL,
    "operator_name" "text",
    "work_description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operation_logs_hours_used_check" CHECK ((("hours_used" >= (0)::numeric) AND ("hours_used" <= (24)::numeric)))
);


ALTER TABLE "public"."operation_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organizations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "company_code" "text" NOT NULL,
    "site_name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."organizations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payroll_approvers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."payroll_approvers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."petty_cash_floats" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "cost_center_id" "uuid" NOT NULL,
    "custodian_user_id" "uuid" NOT NULL,
    "float_name" "text" NOT NULL,
    "ceiling_amount" numeric NOT NULL,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "petty_cash_floats_ceiling_amount_check" CHECK (("ceiling_amount" > (0)::numeric))
);


ALTER TABLE "public"."petty_cash_floats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."petty_cash_replenishments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "petty_cash_float_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL,
    "replenished_date" "date" NOT NULL,
    "funded_from" "text" NOT NULL,
    "bank_account" "text",
    "description" "text",
    "recorded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "petty_cash_replenishments_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "petty_cash_replenishments_funded_from_check" CHECK (("funded_from" = ANY (ARRAY['cash'::"text", 'bank'::"text"])))
);


ALTER TABLE "public"."petty_cash_replenishments" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."petty_cash_float_balances" WITH ("security_invoker"='true') AS
 SELECT "f"."id" AS "petty_cash_float_id",
    "f"."tenant_id",
    "f"."cost_center_id",
    "f"."custodian_user_id",
    "f"."float_name",
    "f"."ceiling_amount",
    "f"."currency",
    "f"."is_active",
    COALESCE("r"."total_replenished", (0)::numeric) AS "total_replenished",
    COALESCE("s"."total_spent", (0)::numeric) AS "total_spent",
    (COALESCE("r"."total_replenished", (0)::numeric) - COALESCE("s"."total_spent", (0)::numeric)) AS "current_balance"
   FROM (("public"."petty_cash_floats" "f"
     LEFT JOIN ( SELECT "petty_cash_replenishments"."petty_cash_float_id",
            "sum"("petty_cash_replenishments"."amount") AS "total_replenished"
           FROM "public"."petty_cash_replenishments"
          GROUP BY "petty_cash_replenishments"."petty_cash_float_id") "r" ON (("r"."petty_cash_float_id" = "f"."id")))
     LEFT JOIN ( SELECT "expenditure_slips"."petty_cash_float_id",
            "sum"("expenditure_slips"."amount") AS "total_spent"
           FROM "public"."expenditure_slips"
          WHERE ("expenditure_slips"."petty_cash_float_id" IS NOT NULL)
          GROUP BY "expenditure_slips"."petty_cash_float_id") "s" ON (("s"."petty_cash_float_id" = "f"."id")));


ALTER VIEW "public"."petty_cash_float_balances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platform_settings" (
    "id" boolean DEFAULT true NOT NULL,
    "branding" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "notifications" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "security" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    CONSTRAINT "platform_settings_singleton" CHECK ("id")
);


ALTER TABLE "public"."platform_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pmo_milestones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "due_date" "date",
    "completion_percent" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pmo_milestones_completion_percent_check" CHECK ((("completion_percent" >= 0) AND ("completion_percent" <= 100))),
    CONSTRAINT "pmo_milestones_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'in_progress'::"text", 'done'::"text", 'missed'::"text"])))
);


ALTER TABLE "public"."pmo_milestones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pmo_project_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pmo_project_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pmo_projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "project_no" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category_id" "uuid",
    "client_name" "text",
    "status" "text" DEFAULT 'not_started'::"text" NOT NULL,
    "budget" numeric,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "start_date" "date",
    "end_date" "date",
    "manager_id" "uuid",
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pmo_projects_status_check" CHECK (("status" = ANY (ARRAY['not_started'::"text", 'in_progress'::"text", 'on_hold'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."pmo_projects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pmo_resource_allocations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid",
    "project_id" "uuid",
    "allocation_percent" integer DEFAULT 100 NOT NULL,
    "start_date" "date",
    "end_date" "date",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pmo_resource_allocations_allocation_percent_check" CHECK ((("allocation_percent" >= 0) AND ("allocation_percent" <= 200))),
    CONSTRAINT "pmo_resource_allocations_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'planned'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."pmo_resource_allocations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pmo_task_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pmo_task_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pmo_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "project_id" "uuid",
    "title" "text" NOT NULL,
    "type_id" "uuid",
    "status" "text" DEFAULT 'todo'::"text" NOT NULL,
    "priority" "text" DEFAULT 'medium'::"text" NOT NULL,
    "assignee_id" "uuid",
    "due_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "start_date" "date",
    CONSTRAINT "pmo_tasks_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'medium'::"text", 'high'::"text", 'critical'::"text"]))),
    CONSTRAINT "pmo_tasks_status_check" CHECK (("status" = ANY (ARRAY['todo'::"text", 'in_progress'::"text", 'review'::"text", 'done'::"text"])))
);


ALTER TABLE "public"."pmo_tasks" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."po_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."po_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."problem_tickets" (
    "problem_id" "uuid" NOT NULL,
    "ticket_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "linked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."problem_tickets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receivable_invoices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "cost_center_id" "uuid",
    "invoice_number" "text" NOT NULL,
    "invoice_date" "date" NOT NULL,
    "amount_incl_vat" numeric NOT NULL,
    "vat_amount" numeric DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "recorded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "client_account_id" "uuid",
    "organization_id" "uuid" NOT NULL,
    "prf_oif_number" "text" NOT NULL,
    "due_date" "date",
    CONSTRAINT "receivable_invoices_amount_incl_vat_check" CHECK (("amount_incl_vat" > (0)::numeric)),
    CONSTRAINT "receivable_invoices_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'paid'::"text"]))),
    CONSTRAINT "receivable_invoices_vat_amount_check" CHECK (("vat_amount" >= (0)::numeric))
);


ALTER TABLE "public"."receivable_invoices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."request_offers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "vendor_name" "text" NOT NULL,
    "quotation_amount" numeric(14,2) NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "vendor_account_id" "uuid",
    "is_selected" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."request_offers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sap_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "purchase_order_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL,
    "status" "text" DEFAULT 'pending_sap'::"text" NOT NULL,
    "sap_reference" "text",
    "recorded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sap_payments_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "sap_payments_status_check" CHECK (("status" = ANY (ARRAY['pending_sap'::"text", 'sent_to_sap'::"text", 'paid'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."sap_payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."staff_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "module" "text" NOT NULL,
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_roles_module_check" CHECK (("module" = ANY (ARRAY['hr'::"text", 'legal'::"text", 'bd'::"text", 'it'::"text", 'pmo'::"text", 'machine_operation'::"text", 'sustainability'::"text", 'procurement'::"text"]))),
    CONSTRAINT "staff_roles_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])))
);


ALTER TABLE "public"."staff_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stock_balances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "warehouse_id" "uuid" NOT NULL,
    "material_catalog_id" "uuid",
    "material_name" "text" NOT NULL,
    "unit" "text",
    "stock_key" "text" GENERATED ALWAYS AS (COALESCE(("material_catalog_id")::"text", "lower"(TRIM(BOTH FROM "material_name")))) STORED,
    "quantity_on_hand" numeric DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."stock_balances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stock_movements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "warehouse_id" "uuid" NOT NULL,
    "material_catalog_id" "uuid",
    "material_name" "text" NOT NULL,
    "unit" "text",
    "movement_type" "text" NOT NULL,
    "quantity" numeric NOT NULL,
    "reference_type" "text" NOT NULL,
    "reference_id" "uuid" NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recorded_by" "uuid" NOT NULL,
    CONSTRAINT "stock_movements_movement_type_check" CHECK (("movement_type" = ANY (ARRAY['in'::"text", 'out'::"text"]))),
    CONSTRAINT "stock_movements_quantity_check" CHECK (("quantity" > (0)::numeric)),
    CONSTRAINT "stock_movements_reference_type_check" CHECK (("reference_type" = ANY (ARRAY['goods_receipt'::"text", 'goods_issue'::"text"])))
);


ALTER TABLE "public"."stock_movements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."supplier_invoices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "purchase_order_id" "uuid",
    "invoice_number" "text" NOT NULL,
    "invoice_date" "date" NOT NULL,
    "amount_incl_vat" numeric NOT NULL,
    "vat_amount" numeric DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'UGX'::"text" NOT NULL,
    "description" "text",
    "recorded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cost_center_id" "uuid",
    "invoice_type" "text" GENERATED ALWAYS AS (
CASE
    WHEN ("purchase_order_id" IS NOT NULL) THEN 'po_related'::"text"
    ELSE 'non_po'::"text"
END) STORED,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "vendor_account_id" "uuid",
    "organization_id" "uuid" NOT NULL,
    "prf_oif_number" "text" NOT NULL,
    "due_date" "date",
    CONSTRAINT "supplier_invoices_amount_incl_vat_check" CHECK (("amount_incl_vat" > (0)::numeric)),
    CONSTRAINT "supplier_invoices_po_or_cost_center_check" CHECK ((("purchase_order_id" IS NOT NULL) OR ("cost_center_id" IS NOT NULL))),
    CONSTRAINT "supplier_invoices_vat_amount_check" CHECK (("vat_amount" >= (0)::numeric))
);


ALTER TABLE "public"."supplier_invoices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."support_team_members" (
    "team_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."support_team_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sustainability_audits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "type" "text",
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "audit_date" "date",
    "findings" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sustainability_audits_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'in_progress'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."sustainability_audits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sustainability_certifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "standard" "text",
    "issue_date" "date",
    "expiry_date" "date",
    "status" "text" DEFAULT 'valid'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sustainability_certifications_status_check" CHECK (("status" = ANY (ARRAY['valid'::"text", 'expired'::"text", 'pending_renewal'::"text"])))
);


ALTER TABLE "public"."sustainability_certifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sustainability_initiative_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sustainability_initiative_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sustainability_initiatives" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "category_id" "uuid",
    "status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "target_value" numeric(14,2),
    "current_value" numeric(14,2),
    "owner" "text",
    "start_date" "date",
    "end_date" "date",
    "description" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sustainability_initiatives_status_check" CHECK (("status" = ANY (ARRAY['planned'::"text", 'in_progress'::"text", 'completed'::"text", 'on_hold'::"text"])))
);


ALTER TABLE "public"."sustainability_initiatives" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sustainability_metric_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "unit" "text",
    "type" "text" DEFAULT 'carbon'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sustainability_metric_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sustainability_metrics" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "metric_type_id" "uuid",
    "type" "text" DEFAULT 'carbon'::"text" NOT NULL,
    "value" numeric(14,2) NOT NULL,
    "unit" "text",
    "recorded_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sustainability_metrics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_modules" (
    "tenant_id" "uuid" NOT NULL,
    "module" "text" NOT NULL,
    "enabled_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "enabled_by" "uuid",
    CONSTRAINT "tenant_modules_module_check" CHECK (("module" = ANY (ARRAY['hr'::"text", 'legal'::"text", 'bd'::"text", 'it'::"text", 'pmo'::"text", 'machine_operation'::"text", 'sustainability'::"text", 'procurement'::"text"])))
);


ALTER TABLE "public"."tenant_modules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_group_members" (
    "group_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_group_members" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_account_ledger" WITH ("security_invoker"='true') AS
 SELECT "supplier_invoices"."tenant_id",
    "supplier_invoices"."vendor_account_id" AS "account_id",
    'supplier_invoice'::"text" AS "source_type",
    "supplier_invoices"."id" AS "source_id",
    "supplier_invoices"."invoice_number" AS "reference_no",
    "supplier_invoices"."invoice_date" AS "transaction_date",
    "supplier_invoices"."amount_incl_vat" AS "debit",
    (0)::numeric AS "credit",
    "supplier_invoices"."currency"
   FROM "public"."supplier_invoices"
  WHERE ("supplier_invoices"."vendor_account_id" IS NOT NULL)
UNION ALL
 SELECT "receivable_invoices"."tenant_id",
    "receivable_invoices"."client_account_id" AS "account_id",
    'receivable_invoice'::"text" AS "source_type",
    "receivable_invoices"."id" AS "source_id",
    "receivable_invoices"."invoice_number" AS "reference_no",
    "receivable_invoices"."invoice_date" AS "transaction_date",
    "receivable_invoices"."amount_incl_vat" AS "debit",
    (0)::numeric AS "credit",
    "receivable_invoices"."currency"
   FROM "public"."receivable_invoices"
  WHERE ("receivable_invoices"."client_account_id" IS NOT NULL)
UNION ALL
 SELECT "cbt"."tenant_id",
        CASE
            WHEN ("cbt"."reference_type" = 'supplier_invoice'::"text") THEN "si"."vendor_account_id"
            WHEN ("cbt"."reference_type" = 'receivable_invoice'::"text") THEN "ri"."client_account_id"
            ELSE NULL::"uuid"
        END AS "account_id",
    'cash_bank_transaction'::"text" AS "source_type",
    "cbt"."id" AS "source_id",
    "cbt"."description" AS "reference_no",
    "cbt"."transaction_date",
    (0)::numeric AS "debit",
    "cbt"."amount" AS "credit",
    "cbt"."currency"
   FROM (("public"."cash_bank_transactions" "cbt"
     LEFT JOIN "public"."supplier_invoices" "si" ON ((("cbt"."reference_type" = 'supplier_invoice'::"text") AND ("cbt"."reference_id" = "si"."id"))))
     LEFT JOIN "public"."receivable_invoices" "ri" ON ((("cbt"."reference_type" = 'receivable_invoice'::"text") AND ("cbt"."reference_id" = "ri"."id"))))
  WHERE ("cbt"."reference_type" = ANY (ARRAY['supplier_invoice'::"text", 'receivable_invoice'::"text"]));


ALTER VIEW "public"."v_account_ledger" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_advance_payments" WITH ("security_invoker"='true') AS
 SELECT "ap"."id",
    "ap"."tenant_id",
    "ap"."account_id",
    "a"."account_code",
    "a"."name" AS "account_name",
    "ap"."direction",
    "ap"."amount",
    "ap"."currency",
    "ap"."payment_date",
    "ap"."payment_method",
    "ap"."description",
    COALESCE("applied"."total_applied", (0)::numeric) AS "total_applied",
    ("ap"."amount" - COALESCE("applied"."total_applied", (0)::numeric)) AS "remaining_amount"
   FROM (("public"."advance_payments" "ap"
     JOIN "public"."accounts" "a" ON (("a"."id" = "ap"."account_id")))
     LEFT JOIN ( SELECT "advance_payment_applications"."advance_payment_id",
            "sum"("advance_payment_applications"."applied_amount") AS "total_applied"
           FROM "public"."advance_payment_applications"
          GROUP BY "advance_payment_applications"."advance_payment_id") "applied" ON (("applied"."advance_payment_id" = "ap"."id")));


ALTER VIEW "public"."v_advance_payments" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_cost_transactions_inquiry" WITH ("security_invoker"='true') AS
 SELECT "supplier_invoices"."tenant_id",
    "supplier_invoices"."cost_center_id",
    'supplier_invoice'::"text" AS "source_type",
    "supplier_invoices"."id" AS "source_id",
    "supplier_invoices"."invoice_number" AS "reference_no",
    "supplier_invoices"."invoice_date" AS "transaction_date",
    "supplier_invoices"."amount_incl_vat" AS "amount",
    "supplier_invoices"."currency"
   FROM "public"."supplier_invoices"
  WHERE ("supplier_invoices"."cost_center_id" IS NOT NULL)
UNION ALL
 SELECT "expenditure_slips"."tenant_id",
    "expenditure_slips"."cost_center_id",
    'expenditure_slip'::"text" AS "source_type",
    "expenditure_slips"."id" AS "source_id",
    "expenditure_slips"."slip_number" AS "reference_no",
    "expenditure_slips"."slip_date" AS "transaction_date",
    "expenditure_slips"."amount",
    "expenditure_slips"."currency"
   FROM "public"."expenditure_slips"
UNION ALL
 SELECT "r"."tenant_id",
    "r"."cost_center_id",
    'purchase_order'::"text" AS "source_type",
    "po"."id" AS "source_id",
    "po"."po_number" AS "reference_no",
    ("po"."generated_at")::"date" AS "transaction_date",
    "po"."amount",
    'UGX'::"text" AS "currency"
   FROM ("public"."purchase_orders" "po"
     JOIN "public"."requests" "r" ON (("r"."id" = "po"."request_id")))
  WHERE ("r"."cost_center_id" IS NOT NULL);


ALTER VIEW "public"."v_cost_transactions_inquiry" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_durations" WITH ("security_invoker"='true') AS
 SELECT "ri"."tenant_id",
    'receivable_invoice'::"text" AS "source_type",
    "ri"."id" AS "source_id",
    "ri"."invoice_number",
    "ri"."invoice_date",
    "ri"."amount_incl_vat" AS "outstanding_amount",
    "ri"."currency",
    "ri"."status",
    (CURRENT_DATE - "ri"."invoice_date") AS "days_outstanding"
   FROM "public"."receivable_invoices" "ri"
  WHERE ("ri"."status" = 'open'::"text")
UNION ALL
 SELECT "si"."tenant_id",
    'supplier_invoice'::"text" AS "source_type",
    "si"."id" AS "source_id",
    "si"."invoice_number",
    "si"."invoice_date",
    ("si"."amount_incl_vat" - COALESCE("paid"."total_paid", (0)::numeric)) AS "outstanding_amount",
    "si"."currency",
    'open'::"text" AS "status",
    (CURRENT_DATE - "si"."invoice_date") AS "days_outstanding"
   FROM ("public"."supplier_invoices" "si"
     LEFT JOIN ( SELECT "cash_bank_transactions"."reference_id",
            "sum"("cash_bank_transactions"."amount") AS "total_paid"
           FROM "public"."cash_bank_transactions"
          WHERE ("cash_bank_transactions"."reference_type" = 'supplier_invoice'::"text")
          GROUP BY "cash_bank_transactions"."reference_id") "paid" ON (("paid"."reference_id" = "si"."id")))
  WHERE (("si"."amount_incl_vat" - COALESCE("paid"."total_paid", (0)::numeric)) > (0)::numeric);


ALTER VIEW "public"."v_durations" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_payment_plan" WITH ("security_invoker"='true') AS
 SELECT "si"."tenant_id",
    'supplier_invoice'::"text" AS "source_type",
    "si"."id" AS "source_id",
    "si"."invoice_number",
    "si"."invoice_date",
    "si"."due_date",
    "si"."currency",
    ("si"."amount_incl_vat" - COALESCE("paid"."total_paid", (0)::numeric)) AS "outstanding_amount"
   FROM ("public"."supplier_invoices" "si"
     LEFT JOIN ( SELECT "cash_bank_transactions"."reference_id",
            "sum"("cash_bank_transactions"."amount") AS "total_paid"
           FROM "public"."cash_bank_transactions"
          WHERE ("cash_bank_transactions"."reference_type" = 'supplier_invoice'::"text")
          GROUP BY "cash_bank_transactions"."reference_id") "paid" ON (("paid"."reference_id" = "si"."id")))
  WHERE (("si"."due_date" IS NOT NULL) AND (("si"."amount_incl_vat" - COALESCE("paid"."total_paid", (0)::numeric)) > (0)::numeric))
UNION ALL
 SELECT "ri"."tenant_id",
    'receivable_invoice'::"text" AS "source_type",
    "ri"."id" AS "source_id",
    "ri"."invoice_number",
    "ri"."invoice_date",
    "ri"."due_date",
    "ri"."currency",
    "ri"."amount_incl_vat" AS "outstanding_amount"
   FROM "public"."receivable_invoices" "ri"
  WHERE (("ri"."due_date" IS NOT NULL) AND ("ri"."status" = 'open'::"text"));


ALTER VIEW "public"."v_payment_plan" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workflow_stages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "sequence_order" integer NOT NULL,
    "approver_role" "text" NOT NULL,
    "threshold_amount" numeric(14,2),
    "next_stage_low_id" "uuid",
    "next_stage_high_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "requires_offer_entry" boolean DEFAULT false NOT NULL,
    "blocks_offer_submitter_approval" boolean DEFAULT false NOT NULL,
    "is_finance_terminal_stage" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "applies_to" "text" DEFAULT 'requests'::"text" NOT NULL,
    "requires_offer_selection" boolean DEFAULT false NOT NULL,
    CONSTRAINT "workflow_stages_applies_to_check" CHECK (("applies_to" = ANY (ARRAY['requests'::"text", 'invoices'::"text"])))
);


ALTER TABLE "public"."workflow_stages" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_request_tracking" WITH ("security_invoker"='true') AS
 SELECT "r"."id" AS "request_id",
    "r"."mr_number",
    "r"."created_at" AS "mr_date",
    "r"."item_description" AS "mr_title",
    "r"."subcontractor",
    "r"."status",
    "r"."delivery_date",
    "r"."organization_id",
    "org"."company_code",
    "org"."site_name",
    "r"."requester_id",
    "ru"."name" AS "mr_originator",
    "li"."cost_code",
    "li"."place_of_use",
    "ws"."name" AS "pending_authority",
    "po"."id" AS "purchase_order_id",
    "po"."po_number",
    "po"."initial_po_number",
    "po"."vendor_name" AS "company",
    "po"."amount" AS "po_total",
    "po"."currency",
    "po"."generated_by" AS "po_requester_id",
    "gu"."name" AS "po_requester_name",
    "po"."generated_at" AS "po_date",
    "po"."delivered_at",
    "po"."completed_at" AS "closing_date"
   FROM (((((("public"."requests" "r"
     LEFT JOIN "public"."organizations" "org" ON (("org"."id" = "r"."organization_id")))
     LEFT JOIN "public"."app_users" "ru" ON (("ru"."id" = "r"."requester_id")))
     LEFT JOIN LATERAL ( SELECT "request_line_items"."cost_code",
            "request_line_items"."place_of_use"
           FROM "public"."request_line_items"
          WHERE ("request_line_items"."request_id" = "r"."id")
          ORDER BY "request_line_items"."created_at"
         LIMIT 1) "li" ON (true))
     LEFT JOIN "public"."workflow_stages" "ws" ON (("ws"."id" = "r"."current_stage_id")))
     LEFT JOIN "public"."purchase_orders" "po" ON (("po"."request_id" = "r"."id")))
     LEFT JOIN "public"."app_users" "gu" ON (("gu"."id" = "po"."generated_by")));


ALTER VIEW "public"."v_request_tracking" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_trial_balance" WITH ("security_invoker"='true') AS
 SELECT "a"."tenant_id",
    "a"."id" AS "account_id",
    "a"."account_code",
    "a"."name" AS "account_name",
    "ac"."name" AS "category_name",
    "l"."currency",
    "sum"("l"."debit") AS "total_debit",
    "sum"("l"."credit") AS "total_credit",
    ("sum"("l"."debit") - "sum"("l"."credit")) AS "balance"
   FROM (("public"."accounts" "a"
     LEFT JOIN "public"."account_categories" "ac" ON (("ac"."id" = "a"."category_id")))
     LEFT JOIN "public"."v_account_ledger" "l" ON (("l"."account_id" = "a"."id")))
  GROUP BY "a"."tenant_id", "a"."id", "a"."account_code", "a"."name", "ac"."name", "l"."currency";


ALTER VIEW "public"."v_trial_balance" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_vat_report" WITH ("security_invoker"='true') AS
 SELECT "supplier_invoices"."tenant_id",
    "supplier_invoices"."organization_id",
    'supplier_invoice'::"text" AS "source_type",
    "supplier_invoices"."id" AS "source_id",
    "supplier_invoices"."invoice_number",
    "supplier_invoices"."invoice_date",
    "supplier_invoices"."vat_amount",
    "supplier_invoices"."amount_incl_vat",
    "supplier_invoices"."currency"
   FROM "public"."supplier_invoices"
UNION ALL
 SELECT "receivable_invoices"."tenant_id",
    "receivable_invoices"."organization_id",
    'receivable_invoice'::"text" AS "source_type",
    "receivable_invoices"."id" AS "source_id",
    "receivable_invoices"."invoice_number",
    "receivable_invoices"."invoice_date",
    "receivable_invoices"."vat_amount",
    "receivable_invoices"."amount_incl_vat",
    "receivable_invoices"."currency"
   FROM "public"."receivable_invoices";


ALTER VIEW "public"."v_vat_report" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_vendor_evaluation" WITH ("security_invoker"='true') AS
 WITH "po_agg" AS (
         SELECT "po"."vendor_account_id",
            "count"(DISTINCT "po"."id") AS "total_pos",
            "sum"("po"."amount") AS "total_po_value",
            "count"(DISTINCT "po"."id") FILTER (WHERE ("po"."delivered_at" IS NOT NULL)) AS "delivered_pos",
            "avg"((EXTRACT(epoch FROM ("po"."delivered_at" - "po"."generated_at")) / 86400.0)) FILTER (WHERE ("po"."delivered_at" IS NOT NULL)) AS "avg_days_to_deliver",
            "count"(DISTINCT "po"."id") FILTER (WHERE (("po"."delivered_at" IS NOT NULL) AND ("r"."delivery_date" IS NOT NULL) AND (("po"."delivered_at")::"date" <= "r"."delivery_date"))) AS "on_time_pos",
            "count"(DISTINCT "po"."id") FILTER (WHERE (("po"."delivered_at" IS NOT NULL) AND ("r"."delivery_date" IS NOT NULL))) AS "pos_with_target_date"
           FROM ("public"."purchase_orders" "po"
             JOIN "public"."requests" "r" ON (("r"."id" = "po"."request_id")))
          WHERE ("po"."vendor_account_id" IS NOT NULL)
          GROUP BY "po"."vendor_account_id"
        ), "line_agg" AS (
         SELECT "po"."vendor_account_id",
            "count"(*) FILTER (WHERE ("lirs"."receipt_status" = 'full'::"text")) AS "full_lines",
            "count"(*) FILTER (WHERE ("lirs"."receipt_status" = 'partial'::"text")) AS "partial_lines",
            "count"(*) FILTER (WHERE ("lirs"."receipt_status" = 'over'::"text")) AS "over_lines",
            "count"(*) FILTER (WHERE ("lirs"."receipt_status" <> 'none'::"text")) AS "received_lines",
            "count"(*) AS "total_lines"
           FROM (("public"."purchase_orders" "po"
             JOIN "public"."requests" "r" ON (("r"."id" = "po"."request_id")))
             JOIN "public"."line_item_receipt_status" "lirs" ON (("lirs"."request_id" = "r"."id")))
          WHERE ("po"."vendor_account_id" IS NOT NULL)
          GROUP BY "po"."vendor_account_id"
        )
 SELECT "a"."id" AS "vendor_account_id",
    "a"."tenant_id",
    "a"."account_code",
    "a"."name" AS "vendor_name",
    "a"."contact_name",
    "a"."contact_phone",
    "a"."contact_email",
    "a"."is_active",
    COALESCE("po_agg"."total_pos", (0)::bigint) AS "total_pos",
    COALESCE("po_agg"."total_po_value", (0)::numeric) AS "total_po_value",
    COALESCE("po_agg"."delivered_pos", (0)::bigint) AS "delivered_pos",
    "round"("po_agg"."avg_days_to_deliver", 1) AS "avg_days_to_deliver",
        CASE
            WHEN (COALESCE("po_agg"."pos_with_target_date", (0)::bigint) > 0) THEN "round"(((100.0 * ("po_agg"."on_time_pos")::numeric) / ("po_agg"."pos_with_target_date")::numeric), 1)
            ELSE NULL::numeric
        END AS "on_time_delivery_pct",
        CASE
            WHEN (COALESCE("line_agg"."received_lines", (0)::bigint) > 0) THEN "round"(((100.0 * ("line_agg"."full_lines")::numeric) / ("line_agg"."received_lines")::numeric), 1)
            ELSE NULL::numeric
        END AS "fulfillment_accuracy_pct",
        CASE
            WHEN (COALESCE("line_agg"."received_lines", (0)::bigint) > 0) THEN "round"(((100.0 * ("line_agg"."over_lines")::numeric) / ("line_agg"."received_lines")::numeric), 1)
            ELSE NULL::numeric
        END AS "over_delivery_pct",
        CASE
            WHEN (COALESCE("line_agg"."received_lines", (0)::bigint) > 0) THEN "round"(((100.0 * ("line_agg"."partial_lines")::numeric) / ("line_agg"."received_lines")::numeric), 1)
            ELSE NULL::numeric
        END AS "under_delivery_pct"
   FROM (("public"."accounts" "a"
     LEFT JOIN "po_agg" ON (("po_agg"."vendor_account_id" = "a"."id")))
     LEFT JOIN "line_agg" ON (("line_agg"."vendor_account_id" = "a"."id")))
  WHERE ("a"."account_type" = ANY (ARRAY['vendor'::"text", 'both'::"text"]));


ALTER VIEW "public"."v_vendor_evaluation" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."warehouses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "code" "text",
    "project_label" "text",
    "department_id" "uuid",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."warehouses" OWNER TO "postgres";


ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."account_categories"
    ADD CONSTRAINT "account_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."account_categories"
    ADD CONSTRAINT "account_categories_tenant_id_code_key" UNIQUE ("tenant_id", "code");



ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_tenant_id_account_code_key" UNIQUE ("tenant_id", "account_code");



ALTER TABLE ONLY "public"."advance_payment_applications"
    ADD CONSTRAINT "advance_payment_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."advance_payments"
    ADD CONSTRAINT "advance_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_users"
    ADD CONSTRAINT "app_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."approval_actions"
    ADD CONSTRAINT "approval_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."approval_assignments"
    ADD CONSTRAINT "approval_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."approval_assignments"
    ADD CONSTRAINT "approval_assignments_tenant_user_stage_key" UNIQUE ("tenant_id", "user_id", "workflow_stage_id");



ALTER TABLE ONLY "public"."approval_delegations"
    ADD CONSTRAINT "approval_delegations_no_overlap" EXCLUDE USING "gist" ("delegator_user_id" WITH =, "delegate_user_id" WITH =, COALESCE("workflow_stage_id", '00000000-0000-0000-0000-000000000000'::"uuid") WITH =, "tstzrange"("starts_at", "ends_at") WITH &&) WHERE (("status" = 'active'::"text"));



ALTER TABLE ONLY "public"."approval_delegations"
    ADD CONSTRAINT "approval_delegations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."asset_assignments"
    ADD CONSTRAINT "asset_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."asset_requests"
    ADD CONSTRAINT "asset_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_asset_tag_key" UNIQUE ("asset_tag");



ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_activities"
    ADD CONSTRAINT "bd_activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_client_categories"
    ADD CONSTRAINT "bd_client_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_client_categories"
    ADD CONSTRAINT "bd_client_categories_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."bd_clients"
    ADD CONSTRAINT "bd_clients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_contacts"
    ADD CONSTRAINT "bd_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_lead_sources"
    ADD CONSTRAINT "bd_lead_sources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_lead_sources"
    ADD CONSTRAINT "bd_lead_sources_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."bd_lead_statuses"
    ADD CONSTRAINT "bd_lead_statuses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_lead_statuses"
    ADD CONSTRAINT "bd_lead_statuses_tenant_id_status_key" UNIQUE ("tenant_id", "status");



ALTER TABLE ONLY "public"."bd_leads"
    ADD CONSTRAINT "bd_leads_lead_no_key" UNIQUE ("lead_no");



ALTER TABLE ONLY "public"."bd_leads"
    ADD CONSTRAINT "bd_leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_opportunities"
    ADD CONSTRAINT "bd_opportunities_opportunity_no_key" UNIQUE ("opportunity_no");



ALTER TABLE ONLY "public"."bd_opportunities"
    ADD CONSTRAINT "bd_opportunities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_opportunity_stages"
    ADD CONSTRAINT "bd_opportunity_stages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_opportunity_stages"
    ADD CONSTRAINT "bd_opportunity_stages_tenant_id_stage_key" UNIQUE ("tenant_id", "stage");



ALTER TABLE ONLY "public"."bd_proposal_statuses"
    ADD CONSTRAINT "bd_proposal_statuses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_proposal_statuses"
    ADD CONSTRAINT "bd_proposal_statuses_tenant_id_status_key" UNIQUE ("tenant_id", "status");



ALTER TABLE ONLY "public"."bd_proposal_templates"
    ADD CONSTRAINT "bd_proposal_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_proposal_templates"
    ADD CONSTRAINT "bd_proposal_templates_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."bd_proposal_types"
    ADD CONSTRAINT "bd_proposal_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_proposal_types"
    ADD CONSTRAINT "bd_proposal_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_proposal_no_key" UNIQUE ("proposal_no");



ALTER TABLE ONLY "public"."bd_tender_types"
    ADD CONSTRAINT "bd_tender_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_tender_types"
    ADD CONSTRAINT "bd_tender_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."bd_tenders"
    ADD CONSTRAINT "bd_tenders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bd_tenders"
    ADD CONSTRAINT "bd_tenders_tender_no_key" UNIQUE ("tender_no");



ALTER TABLE ONLY "public"."cash_bank_transactions"
    ADD CONSTRAINT "cash_bank_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cost_centers"
    ADD CONSTRAINT "cost_centers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."doc_sequences"
    ADD CONSTRAINT "doc_sequences_pkey" PRIMARY KEY ("tenant_id", "doc_type", "year");



ALTER TABLE ONLY "public"."expenditure_slips"
    ADD CONSTRAINT "expenditure_slips_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_material_groups"
    ADD CONSTRAINT "external_material_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_material_groups"
    ADD CONSTRAINT "external_material_groups_tenant_id_code_key" UNIQUE ("tenant_id", "code");



ALTER TABLE ONLY "public"."faqs"
    ADD CONSTRAINT "faqs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."finance_team_members"
    ADD CONSTRAINT "finance_team_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."finance_team_members"
    ADD CONSTRAINT "finance_team_members_tenant_id_user_id_role_key" UNIQUE ("tenant_id", "user_id", "role");



ALTER TABLE ONLY "public"."fuel_logs"
    ADD CONSTRAINT "fuel_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."goods_issue_items"
    ADD CONSTRAINT "goods_issue_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."goods_issues"
    ADD CONSTRAINT "goods_issues_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_appraisals"
    ADD CONSTRAINT "hr_appraisals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_attendance"
    ADD CONSTRAINT "hr_attendance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_attendance"
    ADD CONSTRAINT "hr_attendance_tenant_id_employee_id_attendance_date_key" UNIQUE ("tenant_id", "employee_id", "attendance_date");



ALTER TABLE ONLY "public"."hr_employee_compensation"
    ADD CONSTRAINT "hr_employee_compensation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_tenant_id_email_key" UNIQUE ("tenant_id", "email");



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_tenant_id_employee_no_key" UNIQUE ("tenant_id", "employee_no");



ALTER TABLE ONLY "public"."hr_job_applications"
    ADD CONSTRAINT "hr_job_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_job_postings"
    ADD CONSTRAINT "hr_job_postings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_leave_requests"
    ADD CONSTRAINT "hr_leave_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_leave_requests"
    ADD CONSTRAINT "hr_leave_requests_tenant_id_leave_no_key" UNIQUE ("tenant_id", "leave_no");



ALTER TABLE ONLY "public"."hr_leave_types"
    ADD CONSTRAINT "hr_leave_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_leave_types"
    ADD CONSTRAINT "hr_leave_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."hr_payroll_items"
    ADD CONSTRAINT "hr_payroll_items_payroll_run_id_employee_id_key" UNIQUE ("payroll_run_id", "employee_id");



ALTER TABLE ONLY "public"."hr_payroll_items"
    ADD CONSTRAINT "hr_payroll_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_payroll_runs"
    ADD CONSTRAINT "hr_payroll_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_payroll_runs"
    ADD CONSTRAINT "hr_payroll_runs_tenant_id_period_key" UNIQUE ("tenant_id", "period");



ALTER TABLE ONLY "public"."hr_positions"
    ADD CONSTRAINT "hr_positions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_positions"
    ADD CONSTRAINT "hr_positions_tenant_id_title_key" UNIQUE ("tenant_id", "title");



ALTER TABLE ONLY "public"."hr_team_members"
    ADD CONSTRAINT "hr_team_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hr_team_members"
    ADD CONSTRAINT "hr_team_members_tenant_id_user_id_key" UNIQUE ("tenant_id", "user_id");



ALTER TABLE ONLY "public"."hr_trainings"
    ADD CONSTRAINT "hr_trainings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."impersonation_logs"
    ADD CONSTRAINT "impersonation_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."impersonation_sessions"
    ADD CONSTRAINT "impersonation_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_tenant_id_email_status_key" UNIQUE ("tenant_id", "email", "status");



ALTER TABLE ONLY "public"."invoice_requests"
    ADD CONSTRAINT "invoice_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."it_tickets"
    ADD CONSTRAINT "it_tickets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."it_tickets"
    ADD CONSTRAINT "it_tickets_tenant_id_ticket_number_key" UNIQUE ("tenant_id", "ticket_number");



ALTER TABLE ONLY "public"."kb_articles"
    ADD CONSTRAINT "kb_articles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."law_case_hearings"
    ADD CONSTRAINT "law_case_hearings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."law_case_types"
    ADD CONSTRAINT "law_case_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."law_case_types"
    ADD CONSTRAINT "law_case_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."law_cases"
    ADD CONSTRAINT "law_cases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."law_cases"
    ADD CONSTRAINT "law_cases_tenant_id_case_no_key" UNIQUE ("tenant_id", "case_no");



ALTER TABLE ONLY "public"."law_compliance_register"
    ADD CONSTRAINT "law_compliance_register_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."law_compliance_register"
    ADD CONSTRAINT "law_compliance_register_tenant_id_item_no_key" UNIQUE ("tenant_id", "item_no");



ALTER TABLE ONLY "public"."law_contract_types"
    ADD CONSTRAINT "law_contract_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."law_contract_types"
    ADD CONSTRAINT "law_contract_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."law_contracts"
    ADD CONSTRAINT "law_contracts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."law_contracts"
    ADD CONSTRAINT "law_contracts_tenant_id_contract_no_key" UNIQUE ("tenant_id", "contract_no");



ALTER TABLE ONLY "public"."law_regulatory_filings"
    ADD CONSTRAINT "law_regulatory_filings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."licenses"
    ADD CONSTRAINT "licenses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."line_item_receipts"
    ADD CONSTRAINT "line_item_receipts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."machine_assignments"
    ADD CONSTRAINT "machine_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."machine_types"
    ADD CONSTRAINT "machine_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."machine_types"
    ADD CONSTRAINT "machine_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."machines"
    ADD CONSTRAINT "machines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."machines"
    ADD CONSTRAINT "machines_tenant_id_machine_no_key" UNIQUE ("tenant_id", "machine_no");



ALTER TABLE ONLY "public"."maintenance_requests"
    ADD CONSTRAINT "maintenance_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."maintenance_types"
    ADD CONSTRAINT "maintenance_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."maintenance_types"
    ADD CONSTRAINT "maintenance_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."material_catalog"
    ADD CONSTRAINT "material_catalog_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_catalog"
    ADD CONSTRAINT "material_catalog_tenant_id_code_key" UNIQUE ("tenant_id", "code");



ALTER TABLE ONLY "public"."material_groups"
    ADD CONSTRAINT "material_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_groups"
    ADD CONSTRAINT "material_groups_tenant_id_code_key" UNIQUE ("tenant_id", "code");



ALTER TABLE ONLY "public"."material_receipt_assignments"
    ADD CONSTRAINT "material_receipt_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_receipt_assignments"
    ADD CONSTRAINT "material_receipt_assignments_tenant_id_user_id_key" UNIQUE ("tenant_id", "user_id");



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_request_batches"
    ADD CONSTRAINT "material_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_types"
    ADD CONSTRAINT "material_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_types"
    ADD CONSTRAINT "material_types_tenant_id_code_key" UNIQUE ("tenant_id", "code");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."oif_sequences"
    ADD CONSTRAINT "oif_sequences_pkey" PRIMARY KEY ("organization_id", "invoice_type");



ALTER TABLE ONLY "public"."operation_logs"
    ADD CONSTRAINT "operation_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_tenant_id_company_code_site_name_key" UNIQUE ("tenant_id", "company_code", "site_name");



ALTER TABLE ONLY "public"."payroll_approvers"
    ADD CONSTRAINT "payroll_approvers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payroll_approvers"
    ADD CONSTRAINT "payroll_approvers_tenant_id_user_id_key" UNIQUE ("tenant_id", "user_id");



ALTER TABLE ONLY "public"."petty_cash_floats"
    ADD CONSTRAINT "petty_cash_floats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."petty_cash_replenishments"
    ADD CONSTRAINT "petty_cash_replenishments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."platform_settings"
    ADD CONSTRAINT "platform_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pmo_milestones"
    ADD CONSTRAINT "pmo_milestones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pmo_project_categories"
    ADD CONSTRAINT "pmo_project_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pmo_project_categories"
    ADD CONSTRAINT "pmo_project_categories_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."pmo_projects"
    ADD CONSTRAINT "pmo_projects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pmo_projects"
    ADD CONSTRAINT "pmo_projects_tenant_id_project_no_key" UNIQUE ("tenant_id", "project_no");



ALTER TABLE ONLY "public"."pmo_resource_allocations"
    ADD CONSTRAINT "pmo_resource_allocations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pmo_task_types"
    ADD CONSTRAINT "pmo_task_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pmo_task_types"
    ADD CONSTRAINT "pmo_task_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."pmo_tasks"
    ADD CONSTRAINT "pmo_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."po_edits"
    ADD CONSTRAINT "po_edits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."priority_levels"
    ADD CONSTRAINT "priority_levels_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."priority_levels"
    ADD CONSTRAINT "priority_levels_tenant_id_code_key" UNIQUE ("tenant_id", "code");



ALTER TABLE ONLY "public"."problem_tickets"
    ADD CONSTRAINT "problem_tickets_pkey" PRIMARY KEY ("problem_id", "ticket_id");



ALTER TABLE ONLY "public"."problems"
    ADD CONSTRAINT "problems_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."problems"
    ADD CONSTRAINT "problems_problem_number_key" UNIQUE ("problem_number");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_po_number_key" UNIQUE ("po_number");



ALTER TABLE ONLY "public"."receivable_invoices"
    ADD CONSTRAINT "receivable_invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."request_line_items"
    ADD CONSTRAINT "request_line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."request_offers"
    ADD CONSTRAINT "request_offers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."request_offers"
    ADD CONSTRAINT "request_offers_unique_vendor_per_request" UNIQUE ("request_id", "vendor_name");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sap_payments"
    ADD CONSTRAINT "sap_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sla_policies"
    ADD CONSTRAINT "sla_policies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sla_policies"
    ADD CONSTRAINT "sla_policies_tenant_id_priority_key" UNIQUE ("tenant_id", "priority");



ALTER TABLE ONLY "public"."staff_roles"
    ADD CONSTRAINT "staff_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_roles"
    ADD CONSTRAINT "staff_roles_tenant_id_user_id_module_key" UNIQUE ("tenant_id", "user_id", "module");



ALTER TABLE ONLY "public"."stock_balances"
    ADD CONSTRAINT "stock_balances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_balances"
    ADD CONSTRAINT "stock_balances_warehouse_id_stock_key_key" UNIQUE ("warehouse_id", "stock_key");



ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."supplier_invoices"
    ADD CONSTRAINT "supplier_invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."support_team_members"
    ADD CONSTRAINT "support_team_members_pkey" PRIMARY KEY ("team_id", "user_id");



ALTER TABLE ONLY "public"."support_teams"
    ADD CONSTRAINT "support_teams_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sustainability_audits"
    ADD CONSTRAINT "sustainability_audits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sustainability_certifications"
    ADD CONSTRAINT "sustainability_certifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sustainability_initiative_categories"
    ADD CONSTRAINT "sustainability_initiative_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sustainability_initiative_categories"
    ADD CONSTRAINT "sustainability_initiative_categories_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."sustainability_initiatives"
    ADD CONSTRAINT "sustainability_initiatives_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sustainability_metric_types"
    ADD CONSTRAINT "sustainability_metric_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sustainability_metric_types"
    ADD CONSTRAINT "sustainability_metric_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."sustainability_metrics"
    ADD CONSTRAINT "sustainability_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenant_modules"
    ADD CONSTRAINT "tenant_modules_pkey" PRIMARY KEY ("tenant_id", "module");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_categories"
    ADD CONSTRAINT "ticket_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_categories"
    ADD CONSTRAINT "ticket_categories_tenant_id_code_key" UNIQUE ("tenant_id", "code");



ALTER TABLE ONLY "public"."user_group_members"
    ADD CONSTRAINT "user_group_members_pkey" PRIMARY KEY ("group_id", "user_id");



ALTER TABLE ONLY "public"."user_groups"
    ADD CONSTRAINT "user_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."warehouses"
    ADD CONSTRAINT "warehouses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workflow_stages"
    ADD CONSTRAINT "workflow_stages_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "app_users_single_platform_admin" ON "public"."app_users" USING "btree" ("is_platform_admin") WHERE ("is_platform_admin" = true);



CREATE INDEX "cash_bank_transactions_reference_idx" ON "public"."cash_bank_transactions" USING "btree" ("reference_type", "reference_id");



CREATE INDEX "hr_job_applications_job_posting_id_idx" ON "public"."hr_job_applications" USING "btree" ("job_posting_id");



CREATE INDEX "hr_job_applications_tenant_id_idx" ON "public"."hr_job_applications" USING "btree" ("tenant_id");



CREATE INDEX "idx_access_requests_decided_by" ON "public"."access_requests" USING "btree" ("decided_by");



CREATE INDEX "idx_access_requests_requested_by" ON "public"."access_requests" USING "btree" ("requested_by");



CREATE INDEX "idx_access_requests_tenant_id" ON "public"."access_requests" USING "btree" ("tenant_id");



CREATE INDEX "idx_accounts_category_id" ON "public"."accounts" USING "btree" ("category_id");



CREATE INDEX "idx_accounts_tenant" ON "public"."accounts" USING "btree" ("tenant_id");



CREATE INDEX "idx_advance_payment_applications_advance_payment_id" ON "public"."advance_payment_applications" USING "btree" ("advance_payment_id");



CREATE INDEX "idx_advance_payment_applications_applied_by" ON "public"."advance_payment_applications" USING "btree" ("applied_by");



CREATE INDEX "idx_advance_payments_account_id" ON "public"."advance_payments" USING "btree" ("account_id");



CREATE INDEX "idx_advance_payments_recorded_by" ON "public"."advance_payments" USING "btree" ("recorded_by");



CREATE INDEX "idx_advance_payments_tenant_id" ON "public"."advance_payments" USING "btree" ("tenant_id");



CREATE INDEX "idx_app_users_department" ON "public"."app_users" USING "btree" ("department_id");



CREATE INDEX "idx_app_users_tenant" ON "public"."app_users" USING "btree" ("tenant_id");



CREATE INDEX "idx_approval_actions_acted_on_behalf_of" ON "public"."approval_actions" USING "btree" ("acted_on_behalf_of");



CREATE INDEX "idx_approval_actions_approver_id" ON "public"."approval_actions" USING "btree" ("approver_id");



CREATE INDEX "idx_approval_actions_invoice_request_id" ON "public"."approval_actions" USING "btree" ("invoice_request_id");



CREATE INDEX "idx_approval_actions_request" ON "public"."approval_actions" USING "btree" ("request_id");



CREATE INDEX "idx_approval_actions_stage" ON "public"."approval_actions" USING "btree" ("workflow_stage_id");



CREATE INDEX "idx_approval_assignments_stage" ON "public"."approval_assignments" USING "btree" ("workflow_stage_id");



CREATE INDEX "idx_approval_assignments_tenant" ON "public"."approval_assignments" USING "btree" ("tenant_id");



CREATE INDEX "idx_approval_assignments_user" ON "public"."approval_assignments" USING "btree" ("user_id");



CREATE INDEX "idx_approval_delegations_delegate" ON "public"."approval_delegations" USING "btree" ("delegate_user_id");



CREATE INDEX "idx_approval_delegations_delegator" ON "public"."approval_delegations" USING "btree" ("delegator_user_id");



CREATE INDEX "idx_approval_delegations_status" ON "public"."approval_delegations" USING "btree" ("status");



CREATE INDEX "idx_approval_delegations_tenant" ON "public"."approval_delegations" USING "btree" ("tenant_id");



CREATE INDEX "idx_approval_delegations_workflow_stage_id" ON "public"."approval_delegations" USING "btree" ("workflow_stage_id");



CREATE INDEX "idx_asset_assignments_asset_id" ON "public"."asset_assignments" USING "btree" ("asset_id");



CREATE INDEX "idx_asset_assignments_assigned_by" ON "public"."asset_assignments" USING "btree" ("assigned_by");



CREATE INDEX "idx_asset_assignments_assigned_to" ON "public"."asset_assignments" USING "btree" ("assigned_to");



CREATE INDEX "idx_asset_assignments_tenant_id" ON "public"."asset_assignments" USING "btree" ("tenant_id");



CREATE INDEX "idx_asset_requests_decided_by" ON "public"."asset_requests" USING "btree" ("decided_by");



CREATE INDEX "idx_asset_requests_fulfilled_asset_id" ON "public"."asset_requests" USING "btree" ("fulfilled_asset_id");



CREATE INDEX "idx_asset_requests_fulfilled_assignment_id" ON "public"."asset_requests" USING "btree" ("fulfilled_assignment_id");



CREATE INDEX "idx_asset_requests_requested_by" ON "public"."asset_requests" USING "btree" ("requested_by");



CREATE INDEX "idx_asset_requests_tenant_id" ON "public"."asset_requests" USING "btree" ("tenant_id");



CREATE INDEX "idx_assets_tenant_id" ON "public"."assets" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_activities_client" ON "public"."bd_activities" USING "btree" ("client_id");



CREATE INDEX "idx_bd_activities_created_by" ON "public"."bd_activities" USING "btree" ("created_by");



CREATE INDEX "idx_bd_activities_tenant" ON "public"."bd_activities" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_clients_category" ON "public"."bd_clients" USING "btree" ("category_id");



CREATE INDEX "idx_bd_clients_created_by" ON "public"."bd_clients" USING "btree" ("created_by");



CREATE INDEX "idx_bd_clients_tenant" ON "public"."bd_clients" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_contacts_client" ON "public"."bd_contacts" USING "btree" ("client_id");



CREATE INDEX "idx_bd_contacts_tenant" ON "public"."bd_contacts" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_leads_converted_opportunity_id" ON "public"."bd_leads" USING "btree" ("converted_opportunity_id");



CREATE INDEX "idx_bd_leads_created_by" ON "public"."bd_leads" USING "btree" ("created_by");



CREATE INDEX "idx_bd_leads_source" ON "public"."bd_leads" USING "btree" ("source_id");



CREATE INDEX "idx_bd_leads_tenant" ON "public"."bd_leads" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_opportunities_client" ON "public"."bd_opportunities" USING "btree" ("client_id");



CREATE INDEX "idx_bd_opportunities_created_by" ON "public"."bd_opportunities" USING "btree" ("created_by");



CREATE INDEX "idx_bd_opportunities_lead" ON "public"."bd_opportunities" USING "btree" ("lead_id");



CREATE INDEX "idx_bd_opportunities_tenant" ON "public"."bd_opportunities" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_opportunities_tenant_id_stage" ON "public"."bd_opportunities" USING "btree" ("tenant_id", "stage");



CREATE INDEX "idx_bd_proposals_client" ON "public"."bd_proposals" USING "btree" ("client_id");



CREATE INDEX "idx_bd_proposals_created_by" ON "public"."bd_proposals" USING "btree" ("created_by");



CREATE INDEX "idx_bd_proposals_decided_by" ON "public"."bd_proposals" USING "btree" ("decided_by");



CREATE INDEX "idx_bd_proposals_opportunity" ON "public"."bd_proposals" USING "btree" ("opportunity_id");



CREATE INDEX "idx_bd_proposals_tenant" ON "public"."bd_proposals" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_proposals_tenant_id_status" ON "public"."bd_proposals" USING "btree" ("tenant_id", "status");



CREATE INDEX "idx_bd_proposals_type_id" ON "public"."bd_proposals" USING "btree" ("type_id");



CREATE INDEX "idx_bd_tenders_client" ON "public"."bd_tenders" USING "btree" ("client_id");



CREATE INDEX "idx_bd_tenders_created_by" ON "public"."bd_tenders" USING "btree" ("created_by");



CREATE INDEX "idx_bd_tenders_tenant" ON "public"."bd_tenders" USING "btree" ("tenant_id");



CREATE INDEX "idx_bd_tenders_type_id" ON "public"."bd_tenders" USING "btree" ("type_id");



CREATE INDEX "idx_cash_bank_transactions_recorded_by" ON "public"."cash_bank_transactions" USING "btree" ("recorded_by");



CREATE INDEX "idx_cash_bank_transactions_tenant_id" ON "public"."cash_bank_transactions" USING "btree" ("tenant_id");



CREATE INDEX "idx_cost_centers_tenant" ON "public"."cost_centers" USING "btree" ("tenant_id");



CREATE INDEX "idx_departments_parent" ON "public"."departments" USING "btree" ("parent_department_id");



CREATE INDEX "idx_departments_tenant" ON "public"."departments" USING "btree" ("tenant_id");



CREATE INDEX "idx_expenditure_slips_cost_center_id" ON "public"."expenditure_slips" USING "btree" ("cost_center_id");



CREATE INDEX "idx_expenditure_slips_organization_id" ON "public"."expenditure_slips" USING "btree" ("organization_id");



CREATE INDEX "idx_expenditure_slips_petty_cash_float_id" ON "public"."expenditure_slips" USING "btree" ("petty_cash_float_id");



CREATE INDEX "idx_expenditure_slips_recorded_by" ON "public"."expenditure_slips" USING "btree" ("recorded_by");



CREATE INDEX "idx_expenditure_slips_tenant_id" ON "public"."expenditure_slips" USING "btree" ("tenant_id");



CREATE INDEX "idx_faqs_tenant_id" ON "public"."faqs" USING "btree" ("tenant_id");



CREATE INDEX "idx_finance_team_members_user_id" ON "public"."finance_team_members" USING "btree" ("user_id");



CREATE INDEX "idx_fuel_logs_date" ON "public"."fuel_logs" USING "btree" ("log_date");



CREATE INDEX "idx_fuel_logs_machine" ON "public"."fuel_logs" USING "btree" ("machine_id");



CREATE INDEX "idx_fuel_logs_tenant" ON "public"."fuel_logs" USING "btree" ("tenant_id");



CREATE INDEX "idx_goods_issue_items_cost_center_id" ON "public"."goods_issue_items" USING "btree" ("cost_center_id");



CREATE INDEX "idx_goods_issue_items_issue" ON "public"."goods_issue_items" USING "btree" ("goods_issue_id");



CREATE INDEX "idx_goods_issue_items_material_catalog_id" ON "public"."goods_issue_items" USING "btree" ("material_catalog_id");



CREATE INDEX "idx_goods_issues_tenant_id" ON "public"."goods_issues" USING "btree" ("tenant_id");



CREATE INDEX "idx_goods_issues_warehouse_id" ON "public"."goods_issues" USING "btree" ("warehouse_id");



CREATE INDEX "idx_goods_issues_warehouse_officer_id" ON "public"."goods_issues" USING "btree" ("warehouse_officer_id");



CREATE INDEX "idx_hr_appraisals_created_by" ON "public"."hr_appraisals" USING "btree" ("created_by");



CREATE INDEX "idx_hr_appraisals_employee" ON "public"."hr_appraisals" USING "btree" ("employee_id");



CREATE INDEX "idx_hr_appraisals_tenant" ON "public"."hr_appraisals" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_attendance_employee" ON "public"."hr_attendance" USING "btree" ("employee_id");



CREATE INDEX "idx_hr_attendance_tenant" ON "public"."hr_attendance" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_employee_compensation_created_by" ON "public"."hr_employee_compensation" USING "btree" ("created_by");



CREATE INDEX "idx_hr_employee_compensation_employee" ON "public"."hr_employee_compensation" USING "btree" ("employee_id", "effective_date" DESC);



CREATE INDEX "idx_hr_employee_compensation_tenant_id" ON "public"."hr_employee_compensation" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_employees_department" ON "public"."hr_employees" USING "btree" ("department_id");



CREATE INDEX "idx_hr_employees_manager" ON "public"."hr_employees" USING "btree" ("manager_id");



CREATE INDEX "idx_hr_employees_position_id" ON "public"."hr_employees" USING "btree" ("position_id");



CREATE INDEX "idx_hr_employees_tenant" ON "public"."hr_employees" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_employees_user" ON "public"."hr_employees" USING "btree" ("user_id");



CREATE INDEX "idx_hr_job_postings_department_id" ON "public"."hr_job_postings" USING "btree" ("department_id");



CREATE INDEX "idx_hr_job_postings_position_id" ON "public"."hr_job_postings" USING "btree" ("position_id");



CREATE INDEX "idx_hr_job_postings_tenant" ON "public"."hr_job_postings" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_leave_requests_approver_id" ON "public"."hr_leave_requests" USING "btree" ("approver_id");



CREATE INDEX "idx_hr_leave_requests_employee" ON "public"."hr_leave_requests" USING "btree" ("employee_id");



CREATE INDEX "idx_hr_leave_requests_leave_type_id" ON "public"."hr_leave_requests" USING "btree" ("leave_type_id");



CREATE INDEX "idx_hr_leave_requests_tenant" ON "public"."hr_leave_requests" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_leave_types_tenant" ON "public"."hr_leave_types" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_payroll_items_employee_id" ON "public"."hr_payroll_items" USING "btree" ("employee_id");



CREATE INDEX "idx_hr_payroll_items_run" ON "public"."hr_payroll_items" USING "btree" ("payroll_run_id");



CREATE INDEX "idx_hr_payroll_runs_approved_by" ON "public"."hr_payroll_runs" USING "btree" ("approved_by");



CREATE INDEX "idx_hr_payroll_runs_prepared_by" ON "public"."hr_payroll_runs" USING "btree" ("prepared_by");



CREATE INDEX "idx_hr_payroll_runs_rejected_by" ON "public"."hr_payroll_runs" USING "btree" ("rejected_by");



CREATE INDEX "idx_hr_positions_tenant" ON "public"."hr_positions" USING "btree" ("tenant_id");



CREATE INDEX "idx_hr_team_members_user_id" ON "public"."hr_team_members" USING "btree" ("user_id");



CREATE INDEX "idx_hr_trainings_created_by" ON "public"."hr_trainings" USING "btree" ("created_by");



CREATE INDEX "idx_hr_trainings_tenant" ON "public"."hr_trainings" USING "btree" ("tenant_id");



CREATE INDEX "idx_impersonation_logs_tenant_id" ON "public"."impersonation_logs" USING "btree" ("tenant_id");



CREATE INDEX "idx_impersonation_sessions_tenant_id" ON "public"."impersonation_sessions" USING "btree" ("tenant_id");



CREATE INDEX "idx_invitations_invited_by" ON "public"."invitations" USING "btree" ("invited_by");



CREATE INDEX "idx_invoice_requests_cost_center_id" ON "public"."invoice_requests" USING "btree" ("cost_center_id");



CREATE INDEX "idx_invoice_requests_current_stage_id" ON "public"."invoice_requests" USING "btree" ("current_stage_id");



CREATE INDEX "idx_invoice_requests_department_id" ON "public"."invoice_requests" USING "btree" ("department_id");



CREATE INDEX "idx_invoice_requests_requester_id" ON "public"."invoice_requests" USING "btree" ("requester_id");



CREATE INDEX "idx_invoice_requests_tenant_id" ON "public"."invoice_requests" USING "btree" ("tenant_id");



CREATE INDEX "idx_it_tickets_approved_by" ON "public"."it_tickets" USING "btree" ("approved_by");



CREATE INDEX "idx_it_tickets_department_id" ON "public"."it_tickets" USING "btree" ("department_id");



CREATE INDEX "idx_kb_articles_created_by" ON "public"."kb_articles" USING "btree" ("created_by");



CREATE INDEX "idx_kb_articles_tenant_id" ON "public"."kb_articles" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_case_hearings_created_by" ON "public"."law_case_hearings" USING "btree" ("created_by");



CREATE INDEX "idx_law_case_types_tenant" ON "public"."law_case_types" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_cases_created_by" ON "public"."law_cases" USING "btree" ("created_by");



CREATE INDEX "idx_law_cases_tenant" ON "public"."law_cases" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_cases_type" ON "public"."law_cases" USING "btree" ("type_id");



CREATE INDEX "idx_law_compliance_owner" ON "public"."law_compliance_register" USING "btree" ("owner_id");



CREATE INDEX "idx_law_compliance_register_created_by" ON "public"."law_compliance_register" USING "btree" ("created_by");



CREATE INDEX "idx_law_compliance_tenant" ON "public"."law_compliance_register" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_contract_types_tenant" ON "public"."law_contract_types" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_contracts_created_by" ON "public"."law_contracts" USING "btree" ("created_by");



CREATE INDEX "idx_law_contracts_tenant" ON "public"."law_contracts" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_contracts_type" ON "public"."law_contracts" USING "btree" ("type_id");



CREATE INDEX "idx_law_filings_tenant" ON "public"."law_regulatory_filings" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_hearings_case" ON "public"."law_case_hearings" USING "btree" ("case_id");



CREATE INDEX "idx_law_hearings_tenant" ON "public"."law_case_hearings" USING "btree" ("tenant_id");



CREATE INDEX "idx_law_regulatory_filings_created_by" ON "public"."law_regulatory_filings" USING "btree" ("created_by");



CREATE INDEX "idx_licenses_asset_id" ON "public"."licenses" USING "btree" ("asset_id");



CREATE INDEX "idx_licenses_tenant_id" ON "public"."licenses" USING "btree" ("tenant_id");



CREATE INDEX "idx_line_item_receipts_approved_by" ON "public"."line_item_receipts" USING "btree" ("approved_by");



CREATE INDEX "idx_line_item_receipts_line_item" ON "public"."line_item_receipts" USING "btree" ("line_item_id");



CREATE INDEX "idx_line_item_receipts_received_by" ON "public"."line_item_receipts" USING "btree" ("received_by");



CREATE INDEX "idx_line_item_receipts_warehouse_id" ON "public"."line_item_receipts" USING "btree" ("warehouse_id");



CREATE INDEX "idx_machine_assignments_machine" ON "public"."machine_assignments" USING "btree" ("machine_id");



CREATE INDEX "idx_machine_assignments_tenant" ON "public"."machine_assignments" USING "btree" ("tenant_id");



CREATE INDEX "idx_machine_types_tenant" ON "public"."machine_types" USING "btree" ("tenant_id");



CREATE INDEX "idx_machines_tenant" ON "public"."machines" USING "btree" ("tenant_id");



CREATE INDEX "idx_machines_type" ON "public"."machines" USING "btree" ("type_id");



CREATE INDEX "idx_maintenance_requests_machine" ON "public"."maintenance_requests" USING "btree" ("machine_id");



CREATE INDEX "idx_maintenance_requests_requested_by" ON "public"."maintenance_requests" USING "btree" ("requested_by");



CREATE INDEX "idx_maintenance_requests_tenant" ON "public"."maintenance_requests" USING "btree" ("tenant_id");



CREATE INDEX "idx_maintenance_types_tenant" ON "public"."maintenance_types" USING "btree" ("tenant_id");



CREATE INDEX "idx_material_catalog_external_material_group_id" ON "public"."material_catalog" USING "btree" ("external_material_group_id");



CREATE INDEX "idx_material_catalog_material_group_id" ON "public"."material_catalog" USING "btree" ("material_group_id");



CREATE INDEX "idx_material_catalog_material_type_id" ON "public"."material_catalog" USING "btree" ("material_type_id");



CREATE UNIQUE INDEX "idx_material_catalog_tenant_code" ON "public"."material_catalog" USING "btree" ("tenant_id", "code") WHERE (("code" IS NOT NULL) AND ("code" <> ''::"text"));



CREATE INDEX "idx_material_catalog_tenant_id" ON "public"."material_catalog" USING "btree" ("tenant_id");



CREATE INDEX "idx_material_receipt_assignments_assigned_by" ON "public"."material_receipt_assignments" USING "btree" ("assigned_by");



CREATE INDEX "idx_material_receipt_assignments_user_id" ON "public"."material_receipt_assignments" USING "btree" ("user_id");



CREATE INDEX "idx_material_request_batches_requester_id" ON "public"."material_request_batches" USING "btree" ("requester_id");



CREATE INDEX "idx_material_request_batches_tenant_id" ON "public"."material_request_batches" USING "btree" ("tenant_id");



CREATE INDEX "idx_material_request_items_batch_id" ON "public"."material_request_items" USING "btree" ("batch_id");



CREATE INDEX "idx_material_request_items_decided_by" ON "public"."material_request_items" USING "btree" ("decided_by");



CREATE INDEX "idx_material_request_items_external_material_group_id" ON "public"."material_request_items" USING "btree" ("external_material_group_id");



CREATE INDEX "idx_material_request_items_material_catalog_id" ON "public"."material_request_items" USING "btree" ("material_catalog_id");



CREATE INDEX "idx_material_request_items_material_group_id" ON "public"."material_request_items" USING "btree" ("material_group_id");



CREATE INDEX "idx_material_request_items_material_type_id" ON "public"."material_request_items" USING "btree" ("material_type_id");



CREATE INDEX "idx_material_request_items_tenant_id" ON "public"."material_request_items" USING "btree" ("tenant_id");



CREATE INDEX "idx_notifications_invoice_request_id" ON "public"."notifications" USING "btree" ("invoice_request_id");



CREATE INDEX "idx_notifications_purchase_order_id" ON "public"."notifications" USING "btree" ("purchase_order_id");



CREATE INDEX "idx_notifications_recipient" ON "public"."notifications" USING "btree" ("recipient_id");



CREATE INDEX "idx_notifications_request_id" ON "public"."notifications" USING "btree" ("request_id");



CREATE INDEX "idx_notifications_tenant" ON "public"."notifications" USING "btree" ("tenant_id");



CREATE INDEX "idx_operation_logs_date" ON "public"."operation_logs" USING "btree" ("log_date");



CREATE INDEX "idx_operation_logs_machine" ON "public"."operation_logs" USING "btree" ("machine_id");



CREATE INDEX "idx_operation_logs_tenant" ON "public"."operation_logs" USING "btree" ("tenant_id");



CREATE INDEX "idx_payroll_approvers_user_id" ON "public"."payroll_approvers" USING "btree" ("user_id");



CREATE INDEX "idx_petty_cash_floats_cost_center_id" ON "public"."petty_cash_floats" USING "btree" ("cost_center_id");



CREATE INDEX "idx_petty_cash_floats_custodian_user_id" ON "public"."petty_cash_floats" USING "btree" ("custodian_user_id");



CREATE INDEX "idx_petty_cash_floats_tenant_id" ON "public"."petty_cash_floats" USING "btree" ("tenant_id");



CREATE INDEX "idx_petty_cash_replenishments_petty_cash_float_id" ON "public"."petty_cash_replenishments" USING "btree" ("petty_cash_float_id");



CREATE INDEX "idx_petty_cash_replenishments_recorded_by" ON "public"."petty_cash_replenishments" USING "btree" ("recorded_by");



CREATE INDEX "idx_petty_cash_replenishments_tenant_id" ON "public"."petty_cash_replenishments" USING "btree" ("tenant_id");



CREATE INDEX "idx_pmo_milestones_project" ON "public"."pmo_milestones" USING "btree" ("project_id");



CREATE INDEX "idx_pmo_milestones_tenant" ON "public"."pmo_milestones" USING "btree" ("tenant_id");



CREATE INDEX "idx_pmo_project_categories_tenant" ON "public"."pmo_project_categories" USING "btree" ("tenant_id");



CREATE INDEX "idx_pmo_projects_category" ON "public"."pmo_projects" USING "btree" ("category_id");



CREATE INDEX "idx_pmo_projects_manager_id" ON "public"."pmo_projects" USING "btree" ("manager_id");



CREATE INDEX "idx_pmo_projects_tenant" ON "public"."pmo_projects" USING "btree" ("tenant_id");



CREATE INDEX "idx_pmo_resource_allocations_employee" ON "public"."pmo_resource_allocations" USING "btree" ("employee_id");



CREATE INDEX "idx_pmo_resource_allocations_project" ON "public"."pmo_resource_allocations" USING "btree" ("project_id");



CREATE INDEX "idx_pmo_resource_allocations_tenant" ON "public"."pmo_resource_allocations" USING "btree" ("tenant_id");



CREATE INDEX "idx_pmo_task_types_tenant" ON "public"."pmo_task_types" USING "btree" ("tenant_id");



CREATE INDEX "idx_pmo_tasks_assignee_id" ON "public"."pmo_tasks" USING "btree" ("assignee_id");



CREATE INDEX "idx_pmo_tasks_project" ON "public"."pmo_tasks" USING "btree" ("project_id");



CREATE INDEX "idx_pmo_tasks_tenant" ON "public"."pmo_tasks" USING "btree" ("tenant_id");



CREATE INDEX "idx_pmo_tasks_type" ON "public"."pmo_tasks" USING "btree" ("type_id");



CREATE INDEX "idx_po_edits_edited_by" ON "public"."po_edits" USING "btree" ("edited_by");



CREATE INDEX "idx_po_edits_purchase_order_id" ON "public"."po_edits" USING "btree" ("purchase_order_id");



CREATE INDEX "idx_problem_tickets_tenant_id" ON "public"."problem_tickets" USING "btree" ("tenant_id");



CREATE INDEX "idx_problem_tickets_ticket_id" ON "public"."problem_tickets" USING "btree" ("ticket_id");



CREATE INDEX "idx_problems_assigned_to" ON "public"."problems" USING "btree" ("assigned_to");



CREATE INDEX "idx_problems_created_by" ON "public"."problems" USING "btree" ("created_by");



CREATE INDEX "idx_problems_tenant_id" ON "public"."problems" USING "btree" ("tenant_id");



CREATE INDEX "idx_purchase_orders_generated_by" ON "public"."purchase_orders" USING "btree" ("generated_by");



CREATE INDEX "idx_purchase_orders_request" ON "public"."purchase_orders" USING "btree" ("request_id");



CREATE INDEX "idx_purchase_orders_vendor_account_id" ON "public"."purchase_orders" USING "btree" ("vendor_account_id");



CREATE INDEX "idx_receivable_invoices_client_account_id" ON "public"."receivable_invoices" USING "btree" ("client_account_id");



CREATE INDEX "idx_receivable_invoices_cost_center_id" ON "public"."receivable_invoices" USING "btree" ("cost_center_id");



CREATE INDEX "idx_receivable_invoices_organization_id" ON "public"."receivable_invoices" USING "btree" ("organization_id");



CREATE INDEX "idx_receivable_invoices_recorded_by" ON "public"."receivable_invoices" USING "btree" ("recorded_by");



CREATE INDEX "idx_receivable_invoices_tenant_id" ON "public"."receivable_invoices" USING "btree" ("tenant_id");



CREATE INDEX "idx_request_line_items_request" ON "public"."request_line_items" USING "btree" ("request_id");



CREATE INDEX "idx_request_offers_request" ON "public"."request_offers" USING "btree" ("request_id");



CREATE INDEX "idx_request_offers_submitted_by" ON "public"."request_offers" USING "btree" ("submitted_by");



CREATE INDEX "idx_request_offers_vendor_account_id" ON "public"."request_offers" USING "btree" ("vendor_account_id");



CREATE INDEX "idx_requests_cost_center_id" ON "public"."requests" USING "btree" ("cost_center_id");



CREATE INDEX "idx_requests_department_id" ON "public"."requests" USING "btree" ("department_id");



CREATE INDEX "idx_requests_organization_id" ON "public"."requests" USING "btree" ("organization_id");



CREATE INDEX "idx_requests_replaces_request_id" ON "public"."requests" USING "btree" ("replaces_request_id");



CREATE INDEX "idx_requests_requester" ON "public"."requests" USING "btree" ("requester_id");



CREATE INDEX "idx_requests_stage" ON "public"."requests" USING "btree" ("current_stage_id");



CREATE INDEX "idx_requests_status" ON "public"."requests" USING "btree" ("status");



CREATE INDEX "idx_requests_tenant" ON "public"."requests" USING "btree" ("tenant_id");



CREATE INDEX "idx_sap_payments_po" ON "public"."sap_payments" USING "btree" ("purchase_order_id");



CREATE INDEX "idx_sap_payments_tenant" ON "public"."sap_payments" USING "btree" ("tenant_id");



CREATE INDEX "idx_staff_roles_tenant" ON "public"."staff_roles" USING "btree" ("tenant_id");



CREATE INDEX "idx_staff_roles_user" ON "public"."staff_roles" USING "btree" ("user_id");



CREATE INDEX "idx_stock_balances_material_catalog_id" ON "public"."stock_balances" USING "btree" ("material_catalog_id");



CREATE INDEX "idx_stock_balances_tenant_id" ON "public"."stock_balances" USING "btree" ("tenant_id");



CREATE INDEX "idx_stock_movements_material_catalog_id" ON "public"."stock_movements" USING "btree" ("material_catalog_id");



CREATE INDEX "idx_stock_movements_recorded_by" ON "public"."stock_movements" USING "btree" ("recorded_by");



CREATE INDEX "idx_stock_movements_reference" ON "public"."stock_movements" USING "btree" ("reference_type", "reference_id");



CREATE INDEX "idx_stock_movements_tenant_id" ON "public"."stock_movements" USING "btree" ("tenant_id");



CREATE INDEX "idx_stock_movements_warehouse_material" ON "public"."stock_movements" USING "btree" ("warehouse_id", "material_catalog_id");



CREATE INDEX "idx_supplier_invoices_cost_center_id" ON "public"."supplier_invoices" USING "btree" ("cost_center_id");



CREATE INDEX "idx_supplier_invoices_organization_id" ON "public"."supplier_invoices" USING "btree" ("organization_id");



CREATE INDEX "idx_supplier_invoices_recorded_by" ON "public"."supplier_invoices" USING "btree" ("recorded_by");



CREATE INDEX "idx_supplier_invoices_tenant_id" ON "public"."supplier_invoices" USING "btree" ("tenant_id");



CREATE INDEX "idx_supplier_invoices_vendor_account_id" ON "public"."supplier_invoices" USING "btree" ("vendor_account_id");



CREATE INDEX "idx_support_team_members_user_id" ON "public"."support_team_members" USING "btree" ("user_id");



CREATE INDEX "idx_support_teams_tenant_id" ON "public"."support_teams" USING "btree" ("tenant_id");



CREATE INDEX "idx_sustain_audits_tenant" ON "public"."sustainability_audits" USING "btree" ("tenant_id");



CREATE INDEX "idx_sustain_certs_expiry" ON "public"."sustainability_certifications" USING "btree" ("expiry_date");



CREATE INDEX "idx_sustain_certs_tenant" ON "public"."sustainability_certifications" USING "btree" ("tenant_id");



CREATE INDEX "idx_sustain_init_cat_tenant" ON "public"."sustainability_initiative_categories" USING "btree" ("tenant_id");



CREATE INDEX "idx_sustain_initiatives_category" ON "public"."sustainability_initiatives" USING "btree" ("category_id");



CREATE INDEX "idx_sustain_initiatives_tenant" ON "public"."sustainability_initiatives" USING "btree" ("tenant_id");



CREATE INDEX "idx_sustain_metric_types_tenant" ON "public"."sustainability_metric_types" USING "btree" ("tenant_id");



CREATE INDEX "idx_sustain_metrics_recorded_date" ON "public"."sustainability_metrics" USING "btree" ("recorded_date");



CREATE INDEX "idx_sustain_metrics_tenant" ON "public"."sustainability_metrics" USING "btree" ("tenant_id");



CREATE INDEX "idx_sustain_metrics_type" ON "public"."sustainability_metrics" USING "btree" ("metric_type_id");



CREATE INDEX "idx_sustainability_audits_created_by" ON "public"."sustainability_audits" USING "btree" ("created_by");



CREATE INDEX "idx_sustainability_certifications_created_by" ON "public"."sustainability_certifications" USING "btree" ("created_by");



CREATE INDEX "idx_sustainability_initiatives_created_by" ON "public"."sustainability_initiatives" USING "btree" ("created_by");



CREATE INDEX "idx_sustainability_metrics_created_by" ON "public"."sustainability_metrics" USING "btree" ("created_by");



CREATE INDEX "idx_tenants_created_by" ON "public"."tenants" USING "btree" ("created_by");



CREATE INDEX "idx_user_group_members_user_id" ON "public"."user_group_members" USING "btree" ("user_id");



CREATE INDEX "idx_user_groups_tenant_id" ON "public"."user_groups" USING "btree" ("tenant_id");



CREATE INDEX "idx_warehouses_created_by" ON "public"."warehouses" USING "btree" ("created_by");



CREATE INDEX "idx_warehouses_department_id" ON "public"."warehouses" USING "btree" ("department_id");



CREATE UNIQUE INDEX "idx_warehouses_tenant_code" ON "public"."warehouses" USING "btree" ("tenant_id", "code") WHERE ("code" IS NOT NULL);



CREATE INDEX "idx_workflow_stages_next_stage_high_id" ON "public"."workflow_stages" USING "btree" ("next_stage_high_id");



CREATE INDEX "idx_workflow_stages_next_stage_low_id" ON "public"."workflow_stages" USING "btree" ("next_stage_low_id");



CREATE INDEX "idx_workflow_stages_tenant" ON "public"."workflow_stages" USING "btree" ("tenant_id");



CREATE INDEX "impersonation_sessions_active_idx" ON "public"."impersonation_sessions" USING "btree" ("platform_admin_id") WHERE ("ended_at" IS NULL);



CREATE INDEX "invitations_tenant_status_idx" ON "public"."invitations" USING "btree" ("tenant_id", "status");



CREATE INDEX "it_tickets_assignee_idx" ON "public"."it_tickets" USING "btree" ("assignee_id");



CREATE INDEX "it_tickets_requester_idx" ON "public"."it_tickets" USING "btree" ("requester_id");



CREATE INDEX "it_tickets_tenant_status_idx" ON "public"."it_tickets" USING "btree" ("tenant_id", "status");



CREATE INDEX "notifications_recipient_unread_idx" ON "public"."notifications" USING "btree" ("recipient_id", "created_at" DESC) WHERE ("read_at" IS NULL);



CREATE UNIQUE INDEX "receivable_invoices_prf_oif_number_key" ON "public"."receivable_invoices" USING "btree" ("prf_oif_number");



CREATE UNIQUE INDEX "request_offers_one_selected_per_request" ON "public"."request_offers" USING "btree" ("request_id") WHERE "is_selected";



CREATE UNIQUE INDEX "requests_mr_number_key" ON "public"."requests" USING "btree" ("mr_number") WHERE ("mr_number" IS NOT NULL);



CREATE UNIQUE INDEX "supplier_invoices_prf_oif_number_key" ON "public"."supplier_invoices" USING "btree" ("prf_oif_number");



CREATE UNIQUE INDEX "supplier_invoices_purchase_order_id_unique" ON "public"."supplier_invoices" USING "btree" ("purchase_order_id") WHERE ("purchase_order_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "accounts_touch_updated_at" BEFORE UPDATE ON "public"."accounts" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "invoice_request_defaults" BEFORE INSERT ON "public"."invoice_requests" FOR EACH ROW EXECUTE FUNCTION "public"."set_invoice_request_defaults"();



CREATE OR REPLACE TRIGGER "it_tickets_set_number" BEFORE INSERT ON "public"."it_tickets" FOR EACH ROW EXECUTE FUNCTION "public"."set_ticket_number"();



CREATE OR REPLACE TRIGGER "lock_receivable_invoice_organization" BEFORE UPDATE ON "public"."receivable_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_invoice_organization_change"();



CREATE OR REPLACE TRIGGER "lock_supplier_invoice_organization" BEFORE UPDATE ON "public"."supplier_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_invoice_organization_change"();



CREATE OR REPLACE TRIGGER "protect_delegation_immutable_fields" BEFORE UPDATE ON "public"."approval_delegations" FOR EACH ROW EXECUTE FUNCTION "public"."protect_delegation_immutable_fields"();



CREATE OR REPLACE TRIGGER "set_cash_bank_transaction_defaults_trigger" BEFORE INSERT ON "public"."cash_bank_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."set_cash_bank_transaction_defaults"();



CREATE OR REPLACE TRIGGER "set_expenditure_slip_defaults_trigger" BEFORE INSERT ON "public"."expenditure_slips" FOR EACH ROW EXECUTE FUNCTION "public"."set_expenditure_slip_defaults"();



CREATE OR REPLACE TRIGGER "set_petty_cash_float_defaults_trigger" BEFORE INSERT ON "public"."petty_cash_floats" FOR EACH ROW EXECUTE FUNCTION "public"."set_petty_cash_defaults"();



CREATE OR REPLACE TRIGGER "set_petty_cash_replenishment_defaults_trigger" BEFORE INSERT ON "public"."petty_cash_replenishments" FOR EACH ROW EXECUTE FUNCTION "public"."set_petty_cash_defaults"();



CREATE OR REPLACE TRIGGER "set_receivable_invoice_defaults_trigger" BEFORE INSERT ON "public"."receivable_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."set_receivable_invoice_defaults"();



CREATE OR REPLACE TRIGGER "set_receivable_invoice_oif" BEFORE INSERT ON "public"."receivable_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."assign_receivable_invoice_oif"();



CREATE OR REPLACE TRIGGER "set_supplier_invoice_defaults_trigger" BEFORE INSERT ON "public"."supplier_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."set_supplier_invoice_defaults"();



CREATE OR REPLACE TRIGGER "set_supplier_invoice_oif" BEFORE INSERT ON "public"."supplier_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."assign_supplier_invoice_oif"();



CREATE OR REPLACE TRIGGER "set_warehouse_defaults_trigger" BEFORE INSERT ON "public"."warehouses" FOR EACH ROW EXECUTE FUNCTION "public"."set_warehouse_defaults"();



CREATE OR REPLACE TRIGGER "touch_expenditure_slip_updated_at_trigger" BEFORE UPDATE ON "public"."expenditure_slips" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "touch_petty_cash_float_updated_at_trigger" BEFORE UPDATE ON "public"."petty_cash_floats" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "touch_receivable_invoice_updated_at_trigger" BEFORE UPDATE ON "public"."receivable_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "touch_supplier_invoice_updated_at_trigger" BEFORE UPDATE ON "public"."supplier_invoices" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_apply_stock_movement" AFTER INSERT ON "public"."stock_movements" FOR EACH ROW EXECUTE FUNCTION "public"."apply_stock_movement"();



CREATE OR REPLACE TRIGGER "trg_bd_clients_upd" BEFORE UPDATE ON "public"."bd_clients" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_bd_lead_no" BEFORE INSERT ON "public"."bd_leads" FOR EACH ROW EXECUTE FUNCTION "public"."generate_bd_lead_no"();



CREATE OR REPLACE TRIGGER "trg_bd_leads_upd" BEFORE UPDATE ON "public"."bd_leads" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_bd_opportunities_upd" BEFORE UPDATE ON "public"."bd_opportunities" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_bd_opportunity_no" BEFORE INSERT ON "public"."bd_opportunities" FOR EACH ROW EXECUTE FUNCTION "public"."generate_bd_opportunity_no"();



CREATE OR REPLACE TRIGGER "trg_bd_proposal_no" BEFORE INSERT ON "public"."bd_proposals" FOR EACH ROW EXECUTE FUNCTION "public"."generate_bd_proposal_no"();



CREATE OR REPLACE TRIGGER "trg_bd_proposal_templates_upd" BEFORE UPDATE ON "public"."bd_proposal_templates" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_bd_proposals_upd" BEFORE UPDATE ON "public"."bd_proposals" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_bd_tender_no" BEFORE INSERT ON "public"."bd_tenders" FOR EACH ROW EXECUTE FUNCTION "public"."generate_bd_tender_no"();



CREATE OR REPLACE TRIGGER "trg_bd_tenders_upd" BEFORE UPDATE ON "public"."bd_tenders" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_check_payment_against_receipt" BEFORE INSERT ON "public"."cash_bank_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."check_payment_against_receipt"();



CREATE OR REPLACE TRIGGER "trg_check_payroll_disbursement" BEFORE INSERT ON "public"."cash_bank_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."check_payroll_disbursement"();



CREATE OR REPLACE TRIGGER "trg_check_po_completion_on_advance_application" AFTER INSERT ON "public"."advance_payment_applications" FOR EACH ROW EXECUTE FUNCTION "public"."check_po_completion_on_advance_application"();



CREATE OR REPLACE TRIGGER "trg_check_po_completion_on_cash_bank" AFTER INSERT ON "public"."cash_bank_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."check_po_completion_on_cash_bank"();



CREATE OR REPLACE TRIGGER "trg_hr_appraisals_upd" BEFORE UPDATE ON "public"."hr_appraisals" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_hr_emp_no" BEFORE INSERT ON "public"."hr_employees" FOR EACH ROW EXECUTE FUNCTION "public"."generate_hr_employee_no"();



CREATE OR REPLACE TRIGGER "trg_hr_emp_upd" BEFORE UPDATE ON "public"."hr_employees" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_hr_leave_no" BEFORE INSERT ON "public"."hr_leave_requests" FOR EACH ROW EXECUTE FUNCTION "public"."generate_hr_leave_no"();



CREATE OR REPLACE TRIGGER "trg_hr_leave_upd" BEFORE UPDATE ON "public"."hr_leave_requests" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_hr_trainings_upd" BEFORE UPDATE ON "public"."hr_trainings" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_law_case_no" BEFORE INSERT ON "public"."law_cases" FOR EACH ROW EXECUTE FUNCTION "public"."generate_law_case_no"();



CREATE OR REPLACE TRIGGER "trg_law_cases_upd" BEFORE UPDATE ON "public"."law_cases" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_law_compliance_no" BEFORE INSERT ON "public"."law_compliance_register" FOR EACH ROW EXECUTE FUNCTION "public"."generate_law_compliance_no"();



CREATE OR REPLACE TRIGGER "trg_law_contract_no" BEFORE INSERT ON "public"."law_contracts" FOR EACH ROW EXECUTE FUNCTION "public"."generate_law_contract_no"();



CREATE OR REPLACE TRIGGER "trg_law_contracts_upd" BEFORE UPDATE ON "public"."law_contracts" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_link_vendor_account_on_offer" BEFORE INSERT ON "public"."request_offers" FOR EACH ROW EXECUTE FUNCTION "public"."link_vendor_account_on_offer"();



CREATE OR REPLACE TRIGGER "trg_machine_assignments_upd" BEFORE UPDATE ON "public"."machine_assignments" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_machine_no" BEFORE INSERT ON "public"."machines" FOR EACH ROW EXECUTE FUNCTION "public"."generate_machine_no"();



CREATE OR REPLACE TRIGGER "trg_machines_upd" BEFORE UPDATE ON "public"."machines" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_maintenance_requests_upd" BEFORE UPDATE ON "public"."maintenance_requests" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_pmo_milestones_upd" BEFORE UPDATE ON "public"."pmo_milestones" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_pmo_project_no" BEFORE INSERT ON "public"."pmo_projects" FOR EACH ROW EXECUTE FUNCTION "public"."generate_pmo_project_no"();



CREATE OR REPLACE TRIGGER "trg_pmo_projects_upd" BEFORE UPDATE ON "public"."pmo_projects" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_pmo_resource_allocations_upd" BEFORE UPDATE ON "public"."pmo_resource_allocations" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_pmo_tasks_upd" BEFORE UPDATE ON "public"."pmo_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



CREATE OR REPLACE TRIGGER "trg_post_issue_items_to_stock" AFTER INSERT ON "public"."goods_issue_items" FOR EACH ROW EXECUTE FUNCTION "public"."post_issue_items_to_stock"();



CREATE OR REPLACE TRIGGER "trg_post_receipt_to_stock" AFTER INSERT ON "public"."line_item_receipts" FOR EACH ROW EXECUTE FUNCTION "public"."post_receipt_to_stock"();



CREATE OR REPLACE TRIGGER "trg_protect_po_immutable_fields" BEFORE UPDATE ON "public"."purchase_orders" FOR EACH ROW EXECUTE FUNCTION "public"."protect_po_immutable_fields"();



CREATE OR REPLACE TRIGGER "trg_set_account_category_defaults" BEFORE INSERT ON "public"."account_categories" FOR EACH ROW EXECUTE FUNCTION "public"."set_account_category_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_asset_tag" BEFORE INSERT ON "public"."assets" FOR EACH ROW EXECUTE FUNCTION "public"."set_asset_tag"();



CREATE OR REPLACE TRIGGER "trg_set_cost_center_defaults" BEFORE INSERT ON "public"."cost_centers" FOR EACH ROW EXECUTE FUNCTION "public"."set_cost_center_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_department_defaults" BEFORE INSERT ON "public"."departments" FOR EACH ROW EXECUTE FUNCTION "public"."set_department_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_external_material_groups_defaults" BEFORE INSERT ON "public"."external_material_groups" FOR EACH ROW EXECUTE FUNCTION "public"."set_material_lookup_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_material_groups_defaults" BEFORE INSERT ON "public"."material_groups" FOR EACH ROW EXECUTE FUNCTION "public"."set_material_lookup_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_material_request_batch_defaults" BEFORE INSERT ON "public"."material_request_batches" FOR EACH ROW EXECUTE FUNCTION "public"."set_material_request_batch_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_material_request_item_defaults" BEFORE INSERT ON "public"."material_request_items" FOR EACH ROW EXECUTE FUNCTION "public"."set_material_request_item_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_material_types_defaults" BEFORE INSERT ON "public"."material_types" FOR EACH ROW EXECUTE FUNCTION "public"."set_material_lookup_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_organization_defaults" BEFORE INSERT ON "public"."organizations" FOR EACH ROW EXECUTE FUNCTION "public"."set_organization_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_problem_number" BEFORE INSERT ON "public"."problems" FOR EACH ROW EXECUTE FUNCTION "public"."set_problem_number"();



CREATE OR REPLACE TRIGGER "trg_set_request_defaults" BEFORE INSERT ON "public"."requests" FOR EACH ROW EXECUTE FUNCTION "public"."set_request_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_request_mr_number" BEFORE INSERT ON "public"."requests" FOR EACH ROW EXECUTE FUNCTION "public"."set_request_mr_number"();



CREATE OR REPLACE TRIGGER "trg_set_sap_payment_defaults" BEFORE INSERT ON "public"."sap_payments" FOR EACH ROW EXECUTE FUNCTION "public"."set_sap_payment_defaults"();



CREATE OR REPLACE TRIGGER "trg_sustain_initiatives_upd" BEFORE UPDATE ON "public"."sustainability_initiatives" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at_generic"();



ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."account_categories"
    ADD CONSTRAINT "account_categories_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."account_categories"("id");



ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."advance_payment_applications"
    ADD CONSTRAINT "advance_payment_applications_advance_payment_id_fkey" FOREIGN KEY ("advance_payment_id") REFERENCES "public"."advance_payments"("id");



ALTER TABLE ONLY "public"."advance_payment_applications"
    ADD CONSTRAINT "advance_payment_applications_applied_by_fkey" FOREIGN KEY ("applied_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."advance_payments"
    ADD CONSTRAINT "advance_payments_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id");



ALTER TABLE ONLY "public"."advance_payments"
    ADD CONSTRAINT "advance_payments_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."advance_payments"
    ADD CONSTRAINT "advance_payments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."app_users"
    ADD CONSTRAINT "app_users_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."app_users"
    ADD CONSTRAINT "app_users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_users"
    ADD CONSTRAINT "app_users_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_actions"
    ADD CONSTRAINT "approval_actions_acted_on_behalf_of_fkey" FOREIGN KEY ("acted_on_behalf_of") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."approval_actions"
    ADD CONSTRAINT "approval_actions_approver_id_fkey" FOREIGN KEY ("approver_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."approval_actions"
    ADD CONSTRAINT "approval_actions_invoice_request_id_fkey" FOREIGN KEY ("invoice_request_id") REFERENCES "public"."invoice_requests"("id");



ALTER TABLE ONLY "public"."approval_actions"
    ADD CONSTRAINT "approval_actions_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_actions"
    ADD CONSTRAINT "approval_actions_workflow_stage_id_fkey" FOREIGN KEY ("workflow_stage_id") REFERENCES "public"."workflow_stages"("id");



ALTER TABLE ONLY "public"."approval_assignments"
    ADD CONSTRAINT "approval_assignments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_assignments"
    ADD CONSTRAINT "approval_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_assignments"
    ADD CONSTRAINT "approval_assignments_workflow_stage_id_fkey" FOREIGN KEY ("workflow_stage_id") REFERENCES "public"."workflow_stages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_delegations"
    ADD CONSTRAINT "approval_delegations_delegate_user_id_fkey" FOREIGN KEY ("delegate_user_id") REFERENCES "public"."app_users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_delegations"
    ADD CONSTRAINT "approval_delegations_delegator_user_id_fkey" FOREIGN KEY ("delegator_user_id") REFERENCES "public"."app_users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_delegations"
    ADD CONSTRAINT "approval_delegations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."approval_delegations"
    ADD CONSTRAINT "approval_delegations_workflow_stage_id_fkey" FOREIGN KEY ("workflow_stage_id") REFERENCES "public"."workflow_stages"("id");



ALTER TABLE ONLY "public"."asset_assignments"
    ADD CONSTRAINT "asset_assignments_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."assets"("id");



ALTER TABLE ONLY "public"."asset_assignments"
    ADD CONSTRAINT "asset_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."asset_assignments"
    ADD CONSTRAINT "asset_assignments_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."asset_assignments"
    ADD CONSTRAINT "asset_assignments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."asset_requests"
    ADD CONSTRAINT "asset_requests_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."asset_requests"
    ADD CONSTRAINT "asset_requests_fulfilled_asset_id_fkey" FOREIGN KEY ("fulfilled_asset_id") REFERENCES "public"."assets"("id");



ALTER TABLE ONLY "public"."asset_requests"
    ADD CONSTRAINT "asset_requests_fulfilled_assignment_id_fkey" FOREIGN KEY ("fulfilled_assignment_id") REFERENCES "public"."asset_assignments"("id");



ALTER TABLE ONLY "public"."asset_requests"
    ADD CONSTRAINT "asset_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."asset_requests"
    ADD CONSTRAINT "asset_requests_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."bd_activities"
    ADD CONSTRAINT "bd_activities_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."bd_clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_activities"
    ADD CONSTRAINT "bd_activities_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."bd_activities"
    ADD CONSTRAINT "bd_activities_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_client_categories"
    ADD CONSTRAINT "bd_client_categories_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_clients"
    ADD CONSTRAINT "bd_clients_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."bd_client_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_clients"
    ADD CONSTRAINT "bd_clients_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."bd_clients"
    ADD CONSTRAINT "bd_clients_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_contacts"
    ADD CONSTRAINT "bd_contacts_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."bd_clients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_contacts"
    ADD CONSTRAINT "bd_contacts_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_lead_sources"
    ADD CONSTRAINT "bd_lead_sources_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_lead_statuses"
    ADD CONSTRAINT "bd_lead_statuses_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_leads"
    ADD CONSTRAINT "bd_leads_converted_opportunity_fk" FOREIGN KEY ("converted_opportunity_id") REFERENCES "public"."bd_opportunities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_leads"
    ADD CONSTRAINT "bd_leads_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."bd_leads"
    ADD CONSTRAINT "bd_leads_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."bd_lead_sources"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_leads"
    ADD CONSTRAINT "bd_leads_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_opportunities"
    ADD CONSTRAINT "bd_opportunities_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."bd_clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_opportunities"
    ADD CONSTRAINT "bd_opportunities_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."bd_opportunities"
    ADD CONSTRAINT "bd_opportunities_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."bd_leads"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_opportunities"
    ADD CONSTRAINT "bd_opportunities_tenant_id_stage_fkey" FOREIGN KEY ("tenant_id", "stage") REFERENCES "public"."bd_opportunity_stages"("tenant_id", "stage");



ALTER TABLE ONLY "public"."bd_opportunity_stages"
    ADD CONSTRAINT "bd_opportunity_stages_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_proposal_statuses"
    ADD CONSTRAINT "bd_proposal_statuses_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_proposal_templates"
    ADD CONSTRAINT "bd_proposal_templates_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_proposal_types"
    ADD CONSTRAINT "bd_proposal_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."bd_clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_opportunity_id_fkey" FOREIGN KEY ("opportunity_id") REFERENCES "public"."bd_opportunities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_tenant_id_status_fkey" FOREIGN KEY ("tenant_id", "status") REFERENCES "public"."bd_proposal_statuses"("tenant_id", "status");



ALTER TABLE ONLY "public"."bd_proposals"
    ADD CONSTRAINT "bd_proposals_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."bd_proposal_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_tender_types"
    ADD CONSTRAINT "bd_tender_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_tenders"
    ADD CONSTRAINT "bd_tenders_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."bd_clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bd_tenders"
    ADD CONSTRAINT "bd_tenders_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."bd_tenders"
    ADD CONSTRAINT "bd_tenders_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bd_tenders"
    ADD CONSTRAINT "bd_tenders_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."bd_tender_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."cash_bank_transactions"
    ADD CONSTRAINT "cash_bank_transactions_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."cash_bank_transactions"
    ADD CONSTRAINT "cash_bank_transactions_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."cost_centers"
    ADD CONSTRAINT "cost_centers_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_parent_department_id_fkey" FOREIGN KEY ("parent_department_id") REFERENCES "public"."departments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."doc_sequences"
    ADD CONSTRAINT "doc_sequences_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expenditure_slips"
    ADD CONSTRAINT "expenditure_slips_cost_center_id_fkey" FOREIGN KEY ("cost_center_id") REFERENCES "public"."cost_centers"("id");



ALTER TABLE ONLY "public"."expenditure_slips"
    ADD CONSTRAINT "expenditure_slips_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."expenditure_slips"
    ADD CONSTRAINT "expenditure_slips_petty_cash_float_id_fkey" FOREIGN KEY ("petty_cash_float_id") REFERENCES "public"."petty_cash_floats"("id");



ALTER TABLE ONLY "public"."expenditure_slips"
    ADD CONSTRAINT "expenditure_slips_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."expenditure_slips"
    ADD CONSTRAINT "expenditure_slips_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."external_material_groups"
    ADD CONSTRAINT "external_material_groups_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."faqs"
    ADD CONSTRAINT "faqs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."finance_team_members"
    ADD CONSTRAINT "finance_team_members_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."finance_team_members"
    ADD CONSTRAINT "finance_team_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fuel_logs"
    ADD CONSTRAINT "fuel_logs_machine_id_fkey" FOREIGN KEY ("machine_id") REFERENCES "public"."machines"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fuel_logs"
    ADD CONSTRAINT "fuel_logs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."goods_issue_items"
    ADD CONSTRAINT "goods_issue_items_cost_center_id_fkey" FOREIGN KEY ("cost_center_id") REFERENCES "public"."cost_centers"("id");



ALTER TABLE ONLY "public"."goods_issue_items"
    ADD CONSTRAINT "goods_issue_items_goods_issue_id_fkey" FOREIGN KEY ("goods_issue_id") REFERENCES "public"."goods_issues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."goods_issue_items"
    ADD CONSTRAINT "goods_issue_items_material_catalog_id_fkey" FOREIGN KEY ("material_catalog_id") REFERENCES "public"."material_catalog"("id");



ALTER TABLE ONLY "public"."goods_issues"
    ADD CONSTRAINT "goods_issues_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."goods_issues"
    ADD CONSTRAINT "goods_issues_warehouse_id_fkey" FOREIGN KEY ("warehouse_id") REFERENCES "public"."warehouses"("id");



ALTER TABLE ONLY "public"."goods_issues"
    ADD CONSTRAINT "goods_issues_warehouse_officer_id_fkey" FOREIGN KEY ("warehouse_officer_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_appraisals"
    ADD CONSTRAINT "hr_appraisals_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_appraisals"
    ADD CONSTRAINT "hr_appraisals_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."hr_employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_appraisals"
    ADD CONSTRAINT "hr_appraisals_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_attendance"
    ADD CONSTRAINT "hr_attendance_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."hr_employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_attendance"
    ADD CONSTRAINT "hr_attendance_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_employee_compensation"
    ADD CONSTRAINT "hr_employee_compensation_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_employee_compensation"
    ADD CONSTRAINT "hr_employee_compensation_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."hr_employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_employee_compensation"
    ADD CONSTRAINT "hr_employee_compensation_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."hr_employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_position_id_fkey" FOREIGN KEY ("position_id") REFERENCES "public"."hr_positions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_employees"
    ADD CONSTRAINT "hr_employees_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hr_job_applications"
    ADD CONSTRAINT "hr_job_applications_job_posting_id_fkey" FOREIGN KEY ("job_posting_id") REFERENCES "public"."hr_job_postings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hr_job_applications"
    ADD CONSTRAINT "hr_job_applications_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_job_postings"
    ADD CONSTRAINT "hr_job_postings_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hr_job_postings"
    ADD CONSTRAINT "hr_job_postings_position_id_fkey" FOREIGN KEY ("position_id") REFERENCES "public"."hr_positions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hr_job_postings"
    ADD CONSTRAINT "hr_job_postings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_leave_requests"
    ADD CONSTRAINT "hr_leave_requests_approver_id_fkey" FOREIGN KEY ("approver_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_leave_requests"
    ADD CONSTRAINT "hr_leave_requests_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."hr_employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_leave_requests"
    ADD CONSTRAINT "hr_leave_requests_leave_type_id_fkey" FOREIGN KEY ("leave_type_id") REFERENCES "public"."hr_leave_types"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."hr_leave_requests"
    ADD CONSTRAINT "hr_leave_requests_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_leave_types"
    ADD CONSTRAINT "hr_leave_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_payroll_items"
    ADD CONSTRAINT "hr_payroll_items_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."hr_employees"("id");



ALTER TABLE ONLY "public"."hr_payroll_items"
    ADD CONSTRAINT "hr_payroll_items_payroll_run_id_fkey" FOREIGN KEY ("payroll_run_id") REFERENCES "public"."hr_payroll_runs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_payroll_runs"
    ADD CONSTRAINT "hr_payroll_runs_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_payroll_runs"
    ADD CONSTRAINT "hr_payroll_runs_prepared_by_fkey" FOREIGN KEY ("prepared_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_payroll_runs"
    ADD CONSTRAINT "hr_payroll_runs_rejected_by_fkey" FOREIGN KEY ("rejected_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_payroll_runs"
    ADD CONSTRAINT "hr_payroll_runs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_positions"
    ADD CONSTRAINT "hr_positions_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_team_members"
    ADD CONSTRAINT "hr_team_members_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hr_team_members"
    ADD CONSTRAINT "hr_team_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_trainings"
    ADD CONSTRAINT "hr_trainings_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."hr_trainings"
    ADD CONSTRAINT "hr_trainings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."impersonation_logs"
    ADD CONSTRAINT "impersonation_logs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."impersonation_sessions"
    ADD CONSTRAINT "impersonation_sessions_platform_admin_id_fkey" FOREIGN KEY ("platform_admin_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."impersonation_sessions"
    ADD CONSTRAINT "impersonation_sessions_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invoice_requests"
    ADD CONSTRAINT "invoice_requests_cost_center_id_fkey" FOREIGN KEY ("cost_center_id") REFERENCES "public"."cost_centers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."invoice_requests"
    ADD CONSTRAINT "invoice_requests_current_stage_id_fkey" FOREIGN KEY ("current_stage_id") REFERENCES "public"."workflow_stages"("id");



ALTER TABLE ONLY "public"."invoice_requests"
    ADD CONSTRAINT "invoice_requests_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."invoice_requests"
    ADD CONSTRAINT "invoice_requests_requester_id_fkey" FOREIGN KEY ("requester_id") REFERENCES "public"."app_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."invoice_requests"
    ADD CONSTRAINT "invoice_requests_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."it_tickets"
    ADD CONSTRAINT "it_tickets_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."it_tickets"
    ADD CONSTRAINT "it_tickets_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."it_tickets"
    ADD CONSTRAINT "it_tickets_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id");



ALTER TABLE ONLY "public"."it_tickets"
    ADD CONSTRAINT "it_tickets_requester_id_fkey" FOREIGN KEY ("requester_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."it_tickets"
    ADD CONSTRAINT "it_tickets_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."kb_articles"
    ADD CONSTRAINT "kb_articles_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."kb_articles"
    ADD CONSTRAINT "kb_articles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."law_case_hearings"
    ADD CONSTRAINT "law_case_hearings_case_id_fkey" FOREIGN KEY ("case_id") REFERENCES "public"."law_cases"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."law_case_hearings"
    ADD CONSTRAINT "law_case_hearings_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."law_case_hearings"
    ADD CONSTRAINT "law_case_hearings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."law_case_types"
    ADD CONSTRAINT "law_case_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."law_cases"
    ADD CONSTRAINT "law_cases_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."law_cases"
    ADD CONSTRAINT "law_cases_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."law_cases"
    ADD CONSTRAINT "law_cases_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."law_case_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."law_compliance_register"
    ADD CONSTRAINT "law_compliance_register_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."law_compliance_register"
    ADD CONSTRAINT "law_compliance_register_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."law_compliance_register"
    ADD CONSTRAINT "law_compliance_register_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."law_contract_types"
    ADD CONSTRAINT "law_contract_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."law_contracts"
    ADD CONSTRAINT "law_contracts_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."law_contracts"
    ADD CONSTRAINT "law_contracts_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."law_contracts"
    ADD CONSTRAINT "law_contracts_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."law_contract_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."law_regulatory_filings"
    ADD CONSTRAINT "law_regulatory_filings_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."law_regulatory_filings"
    ADD CONSTRAINT "law_regulatory_filings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."licenses"
    ADD CONSTRAINT "licenses_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."assets"("id");



ALTER TABLE ONLY "public"."licenses"
    ADD CONSTRAINT "licenses_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."line_item_receipts"
    ADD CONSTRAINT "line_item_receipts_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."line_item_receipts"
    ADD CONSTRAINT "line_item_receipts_line_item_id_fkey" FOREIGN KEY ("line_item_id") REFERENCES "public"."request_line_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."line_item_receipts"
    ADD CONSTRAINT "line_item_receipts_received_by_fkey" FOREIGN KEY ("received_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."line_item_receipts"
    ADD CONSTRAINT "line_item_receipts_warehouse_id_fkey" FOREIGN KEY ("warehouse_id") REFERENCES "public"."warehouses"("id");



ALTER TABLE ONLY "public"."machine_assignments"
    ADD CONSTRAINT "machine_assignments_machine_id_fkey" FOREIGN KEY ("machine_id") REFERENCES "public"."machines"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."machine_assignments"
    ADD CONSTRAINT "machine_assignments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."machine_types"
    ADD CONSTRAINT "machine_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."machines"
    ADD CONSTRAINT "machines_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."machines"
    ADD CONSTRAINT "machines_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."machine_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."maintenance_requests"
    ADD CONSTRAINT "maintenance_requests_machine_id_fkey" FOREIGN KEY ("machine_id") REFERENCES "public"."machines"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."maintenance_requests"
    ADD CONSTRAINT "maintenance_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."app_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."maintenance_requests"
    ADD CONSTRAINT "maintenance_requests_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."maintenance_types"
    ADD CONSTRAINT "maintenance_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_catalog"
    ADD CONSTRAINT "material_catalog_external_material_group_id_fkey" FOREIGN KEY ("external_material_group_id") REFERENCES "public"."external_material_groups"("id");



ALTER TABLE ONLY "public"."material_catalog"
    ADD CONSTRAINT "material_catalog_material_group_id_fkey" FOREIGN KEY ("material_group_id") REFERENCES "public"."material_groups"("id");



ALTER TABLE ONLY "public"."material_catalog"
    ADD CONSTRAINT "material_catalog_material_type_id_fkey" FOREIGN KEY ("material_type_id") REFERENCES "public"."material_types"("id");



ALTER TABLE ONLY "public"."material_catalog"
    ADD CONSTRAINT "material_catalog_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_groups"
    ADD CONSTRAINT "material_groups_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_receipt_assignments"
    ADD CONSTRAINT "material_receipt_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."material_receipt_assignments"
    ADD CONSTRAINT "material_receipt_assignments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_receipt_assignments"
    ADD CONSTRAINT "material_receipt_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."material_request_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_external_material_group_id_fkey" FOREIGN KEY ("external_material_group_id") REFERENCES "public"."external_material_groups"("id");



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_material_catalog_id_fkey" FOREIGN KEY ("material_catalog_id") REFERENCES "public"."material_catalog"("id");



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_material_group_id_fkey" FOREIGN KEY ("material_group_id") REFERENCES "public"."material_groups"("id");



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_material_type_id_fkey" FOREIGN KEY ("material_type_id") REFERENCES "public"."material_types"("id");



ALTER TABLE ONLY "public"."material_request_items"
    ADD CONSTRAINT "material_request_items_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_request_batches"
    ADD CONSTRAINT "material_requests_requester_id_fkey" FOREIGN KEY ("requester_id") REFERENCES "public"."app_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."material_request_batches"
    ADD CONSTRAINT "material_requests_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_types"
    ADD CONSTRAINT "material_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_invoice_request_id_fkey" FOREIGN KEY ("invoice_request_id") REFERENCES "public"."invoice_requests"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_purchase_order_id_fkey" FOREIGN KEY ("purchase_order_id") REFERENCES "public"."purchase_orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."requests"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."oif_sequences"
    ADD CONSTRAINT "oif_sequences_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."operation_logs"
    ADD CONSTRAINT "operation_logs_machine_id_fkey" FOREIGN KEY ("machine_id") REFERENCES "public"."machines"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."operation_logs"
    ADD CONSTRAINT "operation_logs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."payroll_approvers"
    ADD CONSTRAINT "payroll_approvers_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payroll_approvers"
    ADD CONSTRAINT "payroll_approvers_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."petty_cash_floats"
    ADD CONSTRAINT "petty_cash_floats_cost_center_id_fkey" FOREIGN KEY ("cost_center_id") REFERENCES "public"."cost_centers"("id");



ALTER TABLE ONLY "public"."petty_cash_floats"
    ADD CONSTRAINT "petty_cash_floats_custodian_user_id_fkey" FOREIGN KEY ("custodian_user_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."petty_cash_floats"
    ADD CONSTRAINT "petty_cash_floats_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."petty_cash_replenishments"
    ADD CONSTRAINT "petty_cash_replenishments_petty_cash_float_id_fkey" FOREIGN KEY ("petty_cash_float_id") REFERENCES "public"."petty_cash_floats"("id");



ALTER TABLE ONLY "public"."petty_cash_replenishments"
    ADD CONSTRAINT "petty_cash_replenishments_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."petty_cash_replenishments"
    ADD CONSTRAINT "petty_cash_replenishments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."platform_settings"
    ADD CONSTRAINT "platform_settings_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."pmo_milestones"
    ADD CONSTRAINT "pmo_milestones_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."pmo_projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_milestones"
    ADD CONSTRAINT "pmo_milestones_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_project_categories"
    ADD CONSTRAINT "pmo_project_categories_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_projects"
    ADD CONSTRAINT "pmo_projects_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."pmo_project_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pmo_projects"
    ADD CONSTRAINT "pmo_projects_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."app_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pmo_projects"
    ADD CONSTRAINT "pmo_projects_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_resource_allocations"
    ADD CONSTRAINT "pmo_resource_allocations_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."hr_employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_resource_allocations"
    ADD CONSTRAINT "pmo_resource_allocations_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."pmo_projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_resource_allocations"
    ADD CONSTRAINT "pmo_resource_allocations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_task_types"
    ADD CONSTRAINT "pmo_task_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_tasks"
    ADD CONSTRAINT "pmo_tasks_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."app_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pmo_tasks"
    ADD CONSTRAINT "pmo_tasks_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."pmo_projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_tasks"
    ADD CONSTRAINT "pmo_tasks_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pmo_tasks"
    ADD CONSTRAINT "pmo_tasks_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."pmo_task_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."po_edits"
    ADD CONSTRAINT "po_edits_edited_by_fkey" FOREIGN KEY ("edited_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."po_edits"
    ADD CONSTRAINT "po_edits_purchase_order_id_fkey" FOREIGN KEY ("purchase_order_id") REFERENCES "public"."purchase_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."priority_levels"
    ADD CONSTRAINT "priority_levels_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."problem_tickets"
    ADD CONSTRAINT "problem_tickets_problem_id_fkey" FOREIGN KEY ("problem_id") REFERENCES "public"."problems"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."problem_tickets"
    ADD CONSTRAINT "problem_tickets_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."problem_tickets"
    ADD CONSTRAINT "problem_tickets_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."it_tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."problems"
    ADD CONSTRAINT "problems_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."problems"
    ADD CONSTRAINT "problems_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."problems"
    ADD CONSTRAINT "problems_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_generated_by_fkey" FOREIGN KEY ("generated_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_vendor_account_id_fkey" FOREIGN KEY ("vendor_account_id") REFERENCES "public"."accounts"("id");



ALTER TABLE ONLY "public"."receivable_invoices"
    ADD CONSTRAINT "receivable_invoices_client_account_id_fkey" FOREIGN KEY ("client_account_id") REFERENCES "public"."accounts"("id");



ALTER TABLE ONLY "public"."receivable_invoices"
    ADD CONSTRAINT "receivable_invoices_cost_center_id_fkey" FOREIGN KEY ("cost_center_id") REFERENCES "public"."cost_centers"("id");



ALTER TABLE ONLY "public"."receivable_invoices"
    ADD CONSTRAINT "receivable_invoices_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."receivable_invoices"
    ADD CONSTRAINT "receivable_invoices_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."receivable_invoices"
    ADD CONSTRAINT "receivable_invoices_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."request_line_items"
    ADD CONSTRAINT "request_line_items_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."request_offers"
    ADD CONSTRAINT "request_offers_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."request_offers"
    ADD CONSTRAINT "request_offers_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."request_offers"
    ADD CONSTRAINT "request_offers_vendor_account_id_fkey" FOREIGN KEY ("vendor_account_id") REFERENCES "public"."accounts"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_cost_center_id_fkey" FOREIGN KEY ("cost_center_id") REFERENCES "public"."cost_centers"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_current_stage_id_fkey" FOREIGN KEY ("current_stage_id") REFERENCES "public"."workflow_stages"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_replaces_request_id_fkey" FOREIGN KEY ("replaces_request_id") REFERENCES "public"."requests"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_requester_id_fkey" FOREIGN KEY ("requester_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sap_payments"
    ADD CONSTRAINT "sap_payments_purchase_order_id_fkey" FOREIGN KEY ("purchase_order_id") REFERENCES "public"."purchase_orders"("id");



ALTER TABLE ONLY "public"."sap_payments"
    ADD CONSTRAINT "sap_payments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sla_policies"
    ADD CONSTRAINT "sla_policies_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."staff_roles"
    ADD CONSTRAINT "staff_roles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."staff_roles"
    ADD CONSTRAINT "staff_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stock_balances"
    ADD CONSTRAINT "stock_balances_material_catalog_id_fkey" FOREIGN KEY ("material_catalog_id") REFERENCES "public"."material_catalog"("id");



ALTER TABLE ONLY "public"."stock_balances"
    ADD CONSTRAINT "stock_balances_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stock_balances"
    ADD CONSTRAINT "stock_balances_warehouse_id_fkey" FOREIGN KEY ("warehouse_id") REFERENCES "public"."warehouses"("id");



ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_material_catalog_id_fkey" FOREIGN KEY ("material_catalog_id") REFERENCES "public"."material_catalog"("id");



ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_warehouse_id_fkey" FOREIGN KEY ("warehouse_id") REFERENCES "public"."warehouses"("id");



ALTER TABLE ONLY "public"."supplier_invoices"
    ADD CONSTRAINT "supplier_invoices_cost_center_id_fkey" FOREIGN KEY ("cost_center_id") REFERENCES "public"."cost_centers"("id");



ALTER TABLE ONLY "public"."supplier_invoices"
    ADD CONSTRAINT "supplier_invoices_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."supplier_invoices"
    ADD CONSTRAINT "supplier_invoices_purchase_order_id_fkey" FOREIGN KEY ("purchase_order_id") REFERENCES "public"."purchase_orders"("id");



ALTER TABLE ONLY "public"."supplier_invoices"
    ADD CONSTRAINT "supplier_invoices_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."supplier_invoices"
    ADD CONSTRAINT "supplier_invoices_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."supplier_invoices"
    ADD CONSTRAINT "supplier_invoices_vendor_account_id_fkey" FOREIGN KEY ("vendor_account_id") REFERENCES "public"."accounts"("id");



ALTER TABLE ONLY "public"."support_team_members"
    ADD CONSTRAINT "support_team_members_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."support_teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."support_team_members"
    ADD CONSTRAINT "support_team_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."support_teams"
    ADD CONSTRAINT "support_teams_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."sustainability_audits"
    ADD CONSTRAINT "sustainability_audits_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."sustainability_audits"
    ADD CONSTRAINT "sustainability_audits_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sustainability_certifications"
    ADD CONSTRAINT "sustainability_certifications_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."sustainability_certifications"
    ADD CONSTRAINT "sustainability_certifications_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sustainability_initiative_categories"
    ADD CONSTRAINT "sustainability_initiative_categories_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sustainability_initiatives"
    ADD CONSTRAINT "sustainability_initiatives_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."sustainability_initiative_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sustainability_initiatives"
    ADD CONSTRAINT "sustainability_initiatives_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."sustainability_initiatives"
    ADD CONSTRAINT "sustainability_initiatives_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sustainability_metric_types"
    ADD CONSTRAINT "sustainability_metric_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sustainability_metrics"
    ADD CONSTRAINT "sustainability_metrics_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."sustainability_metrics"
    ADD CONSTRAINT "sustainability_metrics_metric_type_id_fkey" FOREIGN KEY ("metric_type_id") REFERENCES "public"."sustainability_metric_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sustainability_metrics"
    ADD CONSTRAINT "sustainability_metrics_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_modules"
    ADD CONSTRAINT "tenant_modules_enabled_by_fkey" FOREIGN KEY ("enabled_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."tenant_modules"
    ADD CONSTRAINT "tenant_modules_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."ticket_categories"
    ADD CONSTRAINT "ticket_categories_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."user_group_members"
    ADD CONSTRAINT "user_group_members_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."user_groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_group_members"
    ADD CONSTRAINT "user_group_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."user_groups"
    ADD CONSTRAINT "user_groups_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."warehouses"
    ADD CONSTRAINT "warehouses_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."app_users"("id");



ALTER TABLE ONLY "public"."warehouses"
    ADD CONSTRAINT "warehouses_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."warehouses"
    ADD CONSTRAINT "warehouses_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."workflow_stages"
    ADD CONSTRAINT "workflow_stages_next_stage_high_id_fkey" FOREIGN KEY ("next_stage_high_id") REFERENCES "public"."workflow_stages"("id");



ALTER TABLE ONLY "public"."workflow_stages"
    ADD CONSTRAINT "workflow_stages_next_stage_low_id_fkey" FOREIGN KEY ("next_stage_low_id") REFERENCES "public"."workflow_stages"("id");



ALTER TABLE ONLY "public"."workflow_stages"
    ADD CONSTRAINT "workflow_stages_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE "public"."access_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "access_requests_select" ON "public"."access_requests" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (("requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_it_support"())));



ALTER TABLE "public"."account_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "account_categories_delete" ON "public"."account_categories" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "account_categories_insert" ON "public"."account_categories" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "account_categories_select" ON "public"."account_categories" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "account_categories_update" ON "public"."account_categories" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "accounts_delete" ON "public"."accounts" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "accounts_insert" ON "public"."accounts" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "accounts_select" ON "public"."accounts" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "accounts_update" ON "public"."accounts" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."advance_payment_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "advance_payment_applications_delete" ON "public"."advance_payment_applications" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."advance_payments" "ap"
  WHERE (("ap"."id" = "advance_payment_applications"."advance_payment_id") AND ("ap"."tenant_id" = "public"."get_my_tenant_id"()))))));



CREATE POLICY "advance_payment_applications_insert" ON "public"."advance_payment_applications" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."advance_payments" "ap"
  WHERE (("ap"."id" = "advance_payment_applications"."advance_payment_id") AND ("ap"."tenant_id" = "public"."get_my_tenant_id"()))))));



CREATE POLICY "advance_payment_applications_select" ON "public"."advance_payment_applications" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND (EXISTS ( SELECT 1
   FROM "public"."advance_payments" "ap"
  WHERE (("ap"."id" = "advance_payment_applications"."advance_payment_id") AND ("ap"."tenant_id" = "public"."get_my_tenant_id"()))))));



ALTER TABLE "public"."advance_payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "advance_payments_delete" ON "public"."advance_payments" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "advance_payments_insert" ON "public"."advance_payments" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "advance_payments_select" ON "public"."advance_payments" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "advance_payments_update" ON "public"."advance_payments" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."app_users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_users_select_tenant" ON "public"."app_users" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) OR ("id" = ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."approval_actions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "approval_actions_select_tenant" ON "public"."approval_actions" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."requests" "r"
  WHERE (("r"."id" = "approval_actions"."request_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"())))) OR (EXISTS ( SELECT 1
   FROM "public"."invoice_requests" "ir"
  WHERE (("ir"."id" = "approval_actions"."invoice_request_id") AND ("ir"."tenant_id" = "public"."get_my_tenant_id"()))))));



ALTER TABLE "public"."approval_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "approval_assignments_select_own" ON "public"."approval_assignments" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."approval_delegations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "approval_delegations_insert_own" ON "public"."approval_delegations" FOR INSERT WITH CHECK ((("delegator_user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("tenant_id" = "public"."get_my_tenant_id"()) AND ("delegate_user_id" IS DISTINCT FROM ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."app_users" "au"
  WHERE (("au"."id" = "approval_delegations"."delegate_user_id") AND ("au"."tenant_id" = "public"."get_my_tenant_id"())))) AND ((("workflow_stage_id" IS NULL) AND (EXISTS ( SELECT 1
   FROM "public"."approval_assignments" "aa"
  WHERE ("aa"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))) OR (("workflow_stage_id" IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM "public"."approval_assignments" "aa"
  WHERE (("aa"."user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("aa"."workflow_stage_id" = "approval_delegations"."workflow_stage_id"))))))));



CREATE POLICY "approval_delegations_revoke_own" ON "public"."approval_delegations" FOR UPDATE USING ((("delegator_user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("status" = 'active'::"text"))) WITH CHECK ((("delegator_user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("status" = 'revoked'::"text")));



CREATE POLICY "approval_delegations_select_involved" ON "public"."approval_delegations" FOR SELECT USING ((("delegator_user_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("delegate_user_id" = ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."asset_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "asset_assignments_select" ON "public"."asset_assignments" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_it_support"()));



ALTER TABLE "public"."asset_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "asset_requests_select" ON "public"."asset_requests" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (("requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_it_support"())));



ALTER TABLE "public"."assets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "assets_select" ON "public"."assets" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_it_support"()));



ALTER TABLE "public"."bd_activities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_activities_select" ON "public"."bd_activities" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_activities_write_delete" ON "public"."bd_activities" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_activities_write_insert" ON "public"."bd_activities" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_activities_write_update" ON "public"."bd_activities" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_client_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_client_categories_select" ON "public"."bd_client_categories" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_client_categories_write_delete" ON "public"."bd_client_categories" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_client_categories_write_insert" ON "public"."bd_client_categories" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_client_categories_write_update" ON "public"."bd_client_categories" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_clients" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_clients_select" ON "public"."bd_clients" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_clients_write_delete" ON "public"."bd_clients" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_clients_write_insert" ON "public"."bd_clients" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_clients_write_update" ON "public"."bd_clients" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_contacts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_contacts_select" ON "public"."bd_contacts" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_contacts_write_delete" ON "public"."bd_contacts" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_contacts_write_insert" ON "public"."bd_contacts" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_contacts_write_update" ON "public"."bd_contacts" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_lead_sources" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_lead_sources_select" ON "public"."bd_lead_sources" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_lead_sources_write_delete" ON "public"."bd_lead_sources" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_lead_sources_write_insert" ON "public"."bd_lead_sources" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_lead_sources_write_update" ON "public"."bd_lead_sources" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_lead_statuses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_lead_statuses_select" ON "public"."bd_lead_statuses" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_lead_statuses_write_delete" ON "public"."bd_lead_statuses" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_lead_statuses_write_insert" ON "public"."bd_lead_statuses" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_lead_statuses_write_update" ON "public"."bd_lead_statuses" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_leads" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_leads_select" ON "public"."bd_leads" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_leads_write_delete" ON "public"."bd_leads" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_leads_write_insert" ON "public"."bd_leads" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_leads_write_update" ON "public"."bd_leads" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_opportunities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_opportunities_select" ON "public"."bd_opportunities" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_opportunities_write_delete" ON "public"."bd_opportunities" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_opportunities_write_insert" ON "public"."bd_opportunities" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_opportunities_write_update" ON "public"."bd_opportunities" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_opportunity_stages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_opportunity_stages_select" ON "public"."bd_opportunity_stages" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_opportunity_stages_write_delete" ON "public"."bd_opportunity_stages" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_opportunity_stages_write_insert" ON "public"."bd_opportunity_stages" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_opportunity_stages_write_update" ON "public"."bd_opportunity_stages" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_proposal_statuses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_proposal_statuses_select" ON "public"."bd_proposal_statuses" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_statuses_write_delete" ON "public"."bd_proposal_statuses" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_statuses_write_insert" ON "public"."bd_proposal_statuses" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_statuses_write_update" ON "public"."bd_proposal_statuses" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_proposal_templates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_proposal_templates_select" ON "public"."bd_proposal_templates" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_templates_write_delete" ON "public"."bd_proposal_templates" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_templates_write_insert" ON "public"."bd_proposal_templates" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_templates_write_update" ON "public"."bd_proposal_templates" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_proposal_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_proposal_types_select" ON "public"."bd_proposal_types" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_types_write_delete" ON "public"."bd_proposal_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_types_write_insert" ON "public"."bd_proposal_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposal_types_write_update" ON "public"."bd_proposal_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_proposals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_proposals_select" ON "public"."bd_proposals" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposals_write_delete" ON "public"."bd_proposals" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposals_write_insert" ON "public"."bd_proposals" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_proposals_write_update" ON "public"."bd_proposals" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_tender_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_tender_types_select" ON "public"."bd_tender_types" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_tender_types_write_delete" ON "public"."bd_tender_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_tender_types_write_insert" ON "public"."bd_tender_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_tender_types_write_update" ON "public"."bd_tender_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."bd_tenders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bd_tenders_select" ON "public"."bd_tenders" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_tenders_write_delete" ON "public"."bd_tenders" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_tenders_write_insert" ON "public"."bd_tenders" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



CREATE POLICY "bd_tenders_write_update" ON "public"."bd_tenders" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"())) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_business_dev"()));



ALTER TABLE "public"."cash_bank_transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cash_bank_transactions_delete" ON "public"."cash_bank_transactions" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "cash_bank_transactions_insert" ON "public"."cash_bank_transactions" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "cash_bank_transactions_select" ON "public"."cash_bank_transactions" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "cash_bank_transactions_update" ON "public"."cash_bank_transactions" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."cost_centers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cost_centers_insert_finance" ON "public"."cost_centers" FOR INSERT WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "cost_centers_select_tenant" ON "public"."cost_centers" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "cost_centers_update_finance" ON "public"."cost_centers" FOR UPDATE USING (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."departments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "departments_delete" ON "public"."departments" FOR DELETE USING ((("public"."is_finance_team_member"('finance'::"text") OR "public"."is_any_module_admin"()) AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "departments_insert" ON "public"."departments" FOR INSERT WITH CHECK ((("public"."is_finance_team_member"('finance'::"text") OR "public"."is_any_module_admin"()) AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "departments_select_tenant" ON "public"."departments" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "departments_update" ON "public"."departments" FOR UPDATE USING ((("public"."is_finance_team_member"('finance'::"text") OR "public"."is_any_module_admin"()) AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK ((("public"."is_finance_team_member"('finance'::"text") OR "public"."is_any_module_admin"()) AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."doc_sequences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expenditure_slips" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "expenditure_slips_delete" ON "public"."expenditure_slips" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "expenditure_slips_insert" ON "public"."expenditure_slips" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "expenditure_slips_select" ON "public"."expenditure_slips" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "expenditure_slips_update" ON "public"."expenditure_slips" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."external_material_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "external_material_groups_insert" ON "public"."external_material_groups" FOR INSERT WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "external_material_groups_select" ON "public"."external_material_groups" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "external_material_groups_update" ON "public"."external_material_groups" FOR UPDATE USING (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."faqs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "faqs_select" ON "public"."faqs" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("is_published" OR "public"."is_it_support"())));



CREATE POLICY "finance team can view oif sequences" ON "public"."oif_sequences" FOR SELECT USING ("public"."is_finance_team_member"());



ALTER TABLE "public"."finance_team_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "finance_team_members_delete_admin" ON "public"."finance_team_members" FOR DELETE USING ("public"."is_platform_admin"());



CREATE POLICY "finance_team_members_insert_admin" ON "public"."finance_team_members" FOR INSERT WITH CHECK ("public"."is_platform_admin"());



CREATE POLICY "finance_team_members_select_own_or_admin" ON "public"."finance_team_members" FOR SELECT USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_platform_admin"()));



CREATE POLICY "finance_team_members_update_admin" ON "public"."finance_team_members" FOR UPDATE USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



ALTER TABLE "public"."fuel_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fuel_logs_select" ON "public"."fuel_logs" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "fuel_logs_write_delete" ON "public"."fuel_logs" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "fuel_logs_write_insert" ON "public"."fuel_logs" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "fuel_logs_write_update" ON "public"."fuel_logs" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."goods_issue_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "goods_issue_items_select" ON "public"."goods_issue_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."goods_issues" "gi"
  WHERE (("gi"."id" = "goods_issue_items"."goods_issue_id") AND ("gi"."tenant_id" = "public"."get_my_tenant_id"())))));



ALTER TABLE "public"."goods_issues" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "goods_issues_select" ON "public"."goods_issues" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."hr_appraisals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_appraisals_select" ON "public"."hr_appraisals" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR (EXISTS ( SELECT 1
   FROM "public"."hr_employees" "e"
  WHERE (("e"."id" = "hr_appraisals"."employee_id") AND ("e"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))))));



CREATE POLICY "hr_appraisals_write_delete" ON "public"."hr_appraisals" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_appraisals_write_insert" ON "public"."hr_appraisals" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_appraisals_write_update" ON "public"."hr_appraisals" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."hr_attendance" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_attendance_insert" ON "public"."hr_attendance" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR (EXISTS ( SELECT 1
   FROM "public"."hr_employees" "e"
  WHERE (("e"."id" = "hr_attendance"."employee_id") AND ("e"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))))));



CREATE POLICY "hr_attendance_select" ON "public"."hr_attendance" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR (EXISTS ( SELECT 1
   FROM "public"."hr_employees" "e"
  WHERE (("e"."id" = "hr_attendance"."employee_id") AND ("e"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))))));



CREATE POLICY "hr_attendance_update" ON "public"."hr_attendance" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."hr_employee_compensation" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_employee_compensation_select" ON "public"."hr_employee_compensation" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."hr_employees" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_employees_delete" ON "public"."hr_employees" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_employees_insert" ON "public"."hr_employees" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_employees_select" ON "public"."hr_employees" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "hr_employees_update" ON "public"."hr_employees" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."hr_job_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_job_applications_delete" ON "public"."hr_job_applications" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_job_applications_insert" ON "public"."hr_job_applications" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_job_applications_select" ON "public"."hr_job_applications" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "hr_job_applications_update" ON "public"."hr_job_applications" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."hr_job_postings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_job_postings_delete" ON "public"."hr_job_postings" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "hr_job_postings_insert" ON "public"."hr_job_postings" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "hr_job_postings_select" ON "public"."hr_job_postings" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "hr_job_postings_update" ON "public"."hr_job_postings" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."hr_leave_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_leave_requests_insert" ON "public"."hr_leave_requests" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."hr_employees" "e"
  WHERE (("e"."id" = "hr_leave_requests"."employee_id") AND ("e"."user_id" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "hr_leave_requests_select" ON "public"."hr_leave_requests" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR (EXISTS ( SELECT 1
   FROM "public"."hr_employees" "e"
  WHERE (("e"."id" = "hr_leave_requests"."employee_id") AND ("e"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))))));



CREATE POLICY "hr_leave_requests_update" ON "public"."hr_leave_requests" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR (("status" = 'pending'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hr_employees" "e"
  WHERE (("e"."id" = "hr_leave_requests"."employee_id") AND ("e"."user_id" = ( SELECT "auth"."uid"() AS "uid")))))))));



ALTER TABLE "public"."hr_leave_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_leave_types_delete" ON "public"."hr_leave_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "hr_leave_types_insert" ON "public"."hr_leave_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "hr_leave_types_select" ON "public"."hr_leave_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "hr_leave_types_update" ON "public"."hr_leave_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."hr_payroll_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_payroll_items_select" ON "public"."hr_payroll_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."hr_payroll_runs" "pr"
  WHERE (("pr"."id" = "hr_payroll_items"."payroll_run_id") AND ("pr"."tenant_id" = "public"."get_my_tenant_id"())))));



ALTER TABLE "public"."hr_payroll_runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_payroll_runs_select" ON "public"."hr_payroll_runs" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."hr_positions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_positions_delete" ON "public"."hr_positions" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "hr_positions_insert" ON "public"."hr_positions" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "hr_positions_select" ON "public"."hr_positions" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "hr_positions_update" ON "public"."hr_positions" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."hr_team_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_team_members_select" ON "public"."hr_team_members" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."hr_trainings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hr_trainings_select" ON "public"."hr_trainings" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "hr_trainings_write_delete" ON "public"."hr_trainings" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_trainings_write_insert" ON "public"."hr_trainings" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "hr_trainings_write_update" ON "public"."hr_trainings" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('hr'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."impersonation_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "impersonation_logs_select_platform_admin" ON "public"."impersonation_logs" FOR SELECT USING ("public"."is_platform_admin"());



ALTER TABLE "public"."impersonation_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "impersonation_sessions_select_own" ON "public"."impersonation_sessions" FOR SELECT USING (("platform_admin_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."invitations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "invitations_insert" ON "public"."invitations" FOR INSERT WITH CHECK (("public"."is_platform_admin"() OR (("role_bundle" = 'member'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."staff_roles"
  WHERE (("staff_roles"."user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("staff_roles"."tenant_id" = "invitations"."tenant_id") AND ("staff_roles"."role" = 'admin'::"text")))))));



CREATE POLICY "invitations_select" ON "public"."invitations" FOR SELECT USING (("public"."is_platform_admin"() OR (("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."staff_roles"
  WHERE (("staff_roles"."user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("staff_roles"."tenant_id" = "invitations"."tenant_id") AND ("staff_roles"."role" = 'admin'::"text")))))));



ALTER TABLE "public"."invoice_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "invoice_requests_insert_own" ON "public"."invoice_requests" FOR INSERT WITH CHECK ((("requester_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "invoice_requests_select_own_or_actionable" ON "public"."invoice_requests" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (("requester_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."can_act_on_stage"("current_stage_id"))));



ALTER TABLE "public"."it_tickets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "it_tickets_insert" ON "public"."it_tickets" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("requester_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "it_tickets_select" ON "public"."it_tickets" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (("requester_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("assignee_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_it_support"())));



ALTER TABLE "public"."kb_articles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kb_articles_select" ON "public"."kb_articles" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("is_published" OR "public"."is_it_support"())));



ALTER TABLE "public"."law_case_hearings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."law_case_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "law_case_types_delete" ON "public"."law_case_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "law_case_types_insert" ON "public"."law_case_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "law_case_types_select" ON "public"."law_case_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "law_case_types_update" ON "public"."law_case_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."law_cases" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "law_cases_delete" ON "public"."law_cases" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_cases_insert" ON "public"."law_cases" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_cases_select" ON "public"."law_cases" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "law_cases_update" ON "public"."law_cases" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_compliance_delete" ON "public"."law_compliance_register" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_compliance_insert" ON "public"."law_compliance_register" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."law_compliance_register" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "law_compliance_select" ON "public"."law_compliance_register" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "law_compliance_update" ON "public"."law_compliance_register" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR ("owner_id" = ( SELECT "auth"."uid"() AS "uid")))));



ALTER TABLE "public"."law_contract_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "law_contract_types_delete" ON "public"."law_contract_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "law_contract_types_insert" ON "public"."law_contract_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "law_contract_types_select" ON "public"."law_contract_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "law_contract_types_update" ON "public"."law_contract_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."law_contracts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "law_contracts_delete" ON "public"."law_contracts" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_contracts_insert" ON "public"."law_contracts" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_contracts_select" ON "public"."law_contracts" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "law_contracts_update" ON "public"."law_contracts" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_filings_select" ON "public"."law_regulatory_filings" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "law_filings_write_delete" ON "public"."law_regulatory_filings" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_filings_write_insert" ON "public"."law_regulatory_filings" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_filings_write_update" ON "public"."law_regulatory_filings" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_hearings_select" ON "public"."law_case_hearings" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "law_hearings_write_delete" ON "public"."law_case_hearings" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_hearings_write_insert" ON "public"."law_case_hearings" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "law_hearings_write_update" ON "public"."law_case_hearings" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."law_regulatory_filings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."licenses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "licenses_select" ON "public"."licenses" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_it_support"()));



ALTER TABLE "public"."line_item_receipts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "line_item_receipts_select" ON "public"."line_item_receipts" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."request_line_items" "rli"
     JOIN "public"."requests" "r" ON (("r"."id" = "rli"."request_id")))
  WHERE (("rli"."id" = "line_item_receipts"."line_item_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"())))));



ALTER TABLE "public"."machine_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "machine_assignments_select" ON "public"."machine_assignments" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "machine_assignments_write_delete" ON "public"."machine_assignments" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "machine_assignments_write_insert" ON "public"."machine_assignments" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "machine_assignments_write_update" ON "public"."machine_assignments" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."machine_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "machine_types_select" ON "public"."machine_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "machine_types_write_delete" ON "public"."machine_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "machine_types_write_insert" ON "public"."machine_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "machine_types_write_update" ON "public"."machine_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."machines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "machines_select" ON "public"."machines" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "machines_write_delete" ON "public"."machines" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "machines_write_insert" ON "public"."machines" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "machines_write_update" ON "public"."machines" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."maintenance_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "maintenance_requests_select" ON "public"."maintenance_requests" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "maintenance_requests_write_delete" ON "public"."maintenance_requests" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "maintenance_requests_write_insert" ON "public"."maintenance_requests" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "maintenance_requests_write_update" ON "public"."maintenance_requests" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."maintenance_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "maintenance_types_select" ON "public"."maintenance_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "maintenance_types_write_delete" ON "public"."maintenance_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "maintenance_types_write_insert" ON "public"."maintenance_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "maintenance_types_write_update" ON "public"."maintenance_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."material_catalog" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "material_catalog_select" ON "public"."material_catalog" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "material_catalog_update" ON "public"."material_catalog" FOR UPDATE USING (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."material_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "material_groups_insert" ON "public"."material_groups" FOR INSERT WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "material_groups_select" ON "public"."material_groups" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "material_groups_update" ON "public"."material_groups" FOR UPDATE USING (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."material_receipt_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "material_receipt_assignments_select" ON "public"."material_receipt_assignments" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."material_request_batches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "material_request_batches_insert" ON "public"."material_request_batches" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("requester_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "material_request_batches_select" ON "public"."material_request_batches" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (("requester_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."has_po_access"())));



ALTER TABLE "public"."material_request_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "material_request_items_insert" ON "public"."material_request_items" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."material_request_batches" "b"
  WHERE (("b"."id" = "material_request_items"."batch_id") AND ("b"."requester_id" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "material_request_items_select" ON "public"."material_request_items" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_po_access"() OR (EXISTS ( SELECT 1
   FROM "public"."material_request_batches" "b"
  WHERE (("b"."id" = "material_request_items"."batch_id") AND ("b"."requester_id" = ( SELECT "auth"."uid"() AS "uid"))))))));



ALTER TABLE "public"."material_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "material_types_insert" ON "public"."material_types" FOR INSERT WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "material_types_select" ON "public"."material_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "material_types_update" ON "public"."material_types" FOR UPDATE USING (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."has_po_access"() AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_mark_read_own" ON "public"."notifications" FOR UPDATE USING (("recipient_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("recipient_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "notifications_select_own" ON "public"."notifications" FOR SELECT USING (("recipient_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."oif_sequences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."operation_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "operation_logs_select" ON "public"."operation_logs" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "operation_logs_write_delete" ON "public"."operation_logs" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "operation_logs_write_insert" ON "public"."operation_logs" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "operation_logs_write_update" ON "public"."operation_logs" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."organizations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "organizations_delete" ON "public"."organizations" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "organizations_insert" ON "public"."organizations" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "organizations_select" ON "public"."organizations" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."is_finance_team_member"(NULL::"text") OR "public"."has_po_access"())));



CREATE POLICY "organizations_update" ON "public"."organizations" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."payroll_approvers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "payroll_approvers_select" ON "public"."payroll_approvers" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."petty_cash_floats" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "petty_cash_floats_delete" ON "public"."petty_cash_floats" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "petty_cash_floats_insert" ON "public"."petty_cash_floats" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "petty_cash_floats_select" ON "public"."petty_cash_floats" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "petty_cash_floats_update" ON "public"."petty_cash_floats" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."petty_cash_replenishments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "petty_cash_replenishments_delete" ON "public"."petty_cash_replenishments" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "petty_cash_replenishments_insert" ON "public"."petty_cash_replenishments" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "petty_cash_replenishments_select" ON "public"."petty_cash_replenishments" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "petty_cash_replenishments_update" ON "public"."petty_cash_replenishments" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."platform_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "platform_settings_select_admin" ON "public"."platform_settings" FOR SELECT USING ("public"."is_platform_admin"());



CREATE POLICY "platform_settings_update_admin" ON "public"."platform_settings" FOR UPDATE USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



ALTER TABLE "public"."pmo_milestones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pmo_milestones_select" ON "public"."pmo_milestones" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "pmo_milestones_write_delete" ON "public"."pmo_milestones" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "pmo_milestones_write_insert" ON "public"."pmo_milestones" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "pmo_milestones_write_update" ON "public"."pmo_milestones" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."pmo_project_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pmo_project_categories_select" ON "public"."pmo_project_categories" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "pmo_project_categories_write_delete" ON "public"."pmo_project_categories" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "pmo_project_categories_write_insert" ON "public"."pmo_project_categories" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "pmo_project_categories_write_update" ON "public"."pmo_project_categories" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."pmo_projects" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pmo_projects_select" ON "public"."pmo_projects" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "pmo_projects_write_delete" ON "public"."pmo_projects" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "pmo_projects_write_insert" ON "public"."pmo_projects" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "pmo_projects_write_update" ON "public"."pmo_projects" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."pmo_resource_allocations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pmo_resource_allocations_select" ON "public"."pmo_resource_allocations" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "pmo_resource_allocations_write_delete" ON "public"."pmo_resource_allocations" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "pmo_resource_allocations_write_insert" ON "public"."pmo_resource_allocations" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "pmo_resource_allocations_write_update" ON "public"."pmo_resource_allocations" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."pmo_task_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pmo_task_types_select" ON "public"."pmo_task_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "pmo_task_types_write_delete" ON "public"."pmo_task_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "pmo_task_types_write_insert" ON "public"."pmo_task_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "pmo_task_types_write_update" ON "public"."pmo_task_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text"])));



ALTER TABLE "public"."pmo_tasks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pmo_tasks_select" ON "public"."pmo_tasks" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "pmo_tasks_write_delete" ON "public"."pmo_tasks" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR ("assignee_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "pmo_tasks_write_insert" ON "public"."pmo_tasks" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR ("assignee_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "pmo_tasks_write_update" ON "public"."pmo_tasks" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR ("assignee_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND ("public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"]) OR ("assignee_id" = ( SELECT "auth"."uid"() AS "uid")))));



ALTER TABLE "public"."po_edits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "po_edits_insert_finance" ON "public"."po_edits" FOR INSERT WITH CHECK (("public"."has_po_access"() AND (EXISTS ( SELECT 1
   FROM ("public"."purchase_orders" "po"
     JOIN "public"."requests" "r" ON (("r"."id" = "po"."request_id")))
  WHERE (("po"."id" = "po_edits"."purchase_order_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"()))))));



CREATE POLICY "po_edits_select_finance" ON "public"."po_edits" FOR SELECT USING (("public"."has_po_access"() AND (EXISTS ( SELECT 1
   FROM ("public"."purchase_orders" "po"
     JOIN "public"."requests" "r" ON (("r"."id" = "po"."request_id")))
  WHERE (("po"."id" = "po_edits"."purchase_order_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"()))))));



ALTER TABLE "public"."priority_levels" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "priority_levels_select" ON "public"."priority_levels" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."problem_tickets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "problem_tickets_select" ON "public"."problem_tickets" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_it_support"()));



ALTER TABLE "public"."problems" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "problems_select" ON "public"."problems" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_it_support"()));



ALTER TABLE "public"."purchase_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "purchase_orders_select_finance" ON "public"."purchase_orders" FOR SELECT USING (("public"."has_po_access"() AND (EXISTS ( SELECT 1
   FROM "public"."requests" "r"
  WHERE (("r"."id" = "purchase_orders"."request_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"()))))));



CREATE POLICY "purchase_orders_update_handoff" ON "public"."purchase_orders" FOR UPDATE USING (("public"."has_po_access"() AND (EXISTS ( SELECT 1
   FROM "public"."requests" "r"
  WHERE (("r"."id" = "purchase_orders"."request_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"())))))) WITH CHECK (("public"."has_po_access"() AND (EXISTS ( SELECT 1
   FROM "public"."requests" "r"
  WHERE (("r"."id" = "purchase_orders"."request_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"()))))));



ALTER TABLE "public"."receivable_invoices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "receivable_invoices_delete" ON "public"."receivable_invoices" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "receivable_invoices_insert" ON "public"."receivable_invoices" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "receivable_invoices_select" ON "public"."receivable_invoices" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "receivable_invoices_update" ON "public"."receivable_invoices" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."request_line_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "request_line_items_insert" ON "public"."request_line_items" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."requests" "r"
  WHERE (("r"."id" = "request_line_items"."request_id") AND ("r"."requester_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "request_line_items_select" ON "public"."request_line_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."requests" "r"
  WHERE (("r"."id" = "request_line_items"."request_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"())))));



ALTER TABLE "public"."request_offers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "request_offers_insert_authorized" ON "public"."request_offers" FOR INSERT WITH CHECK ((("submitted_by" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM ("public"."requests" "r"
     JOIN "public"."workflow_stages" "ws" ON (("ws"."id" = "r"."current_stage_id")))
  WHERE (("r"."id" = "request_offers"."request_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"()) AND ("r"."status" = 'open'::"text") AND "ws"."requires_offer_entry" AND "public"."can_act_on_stage"("r"."current_stage_id"))))));



CREATE POLICY "request_offers_select_via_request" ON "public"."request_offers" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."requests" "r"
  WHERE (("r"."id" = "request_offers"."request_id") AND ("r"."tenant_id" = "public"."get_my_tenant_id"()) AND (("r"."requester_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."can_act_on_stage"("r"."current_stage_id"))))));



ALTER TABLE "public"."requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "requests_insert_own" ON "public"."requests" FOR INSERT WITH CHECK ((("requester_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "requests_select_own_or_actionable" ON "public"."requests" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (("requester_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."can_act_on_stage"("current_stage_id") OR "public"."has_po_access"())));



ALTER TABLE "public"."sap_payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sap_payments_insert_finance" ON "public"."sap_payments" FOR INSERT WITH CHECK ("public"."has_po_access"());



CREATE POLICY "sap_payments_select_tenant" ON "public"."sap_payments" FOR SELECT USING (("tenant_id" = ( SELECT "app_users"."tenant_id"
   FROM "public"."app_users"
  WHERE ("app_users"."id" = ( SELECT "auth"."uid"() AS "uid")))));



ALTER TABLE "public"."sla_policies" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sla_policies_select" ON "public"."sla_policies" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."staff_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_roles_delete" ON "public"."staff_roles" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."app_users"
  WHERE (("app_users"."id" = ( SELECT "auth"."uid"() AS "uid")) AND "app_users"."is_platform_admin")))));



CREATE POLICY "staff_roles_insert" ON "public"."staff_roles" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."app_users"
  WHERE (("app_users"."id" = ( SELECT "auth"."uid"() AS "uid")) AND "app_users"."is_platform_admin")))));



CREATE POLICY "staff_roles_update" ON "public"."staff_roles" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."app_users"
  WHERE (("app_users"."id" = ( SELECT "auth"."uid"() AS "uid")) AND "app_users"."is_platform_admin"))))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."app_users"
  WHERE (("app_users"."id" = ( SELECT "auth"."uid"() AS "uid")) AND "app_users"."is_platform_admin")))));



ALTER TABLE "public"."stock_balances" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "stock_balances_select" ON "public"."stock_balances" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."stock_movements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "stock_movements_select" ON "public"."stock_movements" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."supplier_invoices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "supplier_invoices_delete" ON "public"."supplier_invoices" FOR DELETE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "supplier_invoices_insert" ON "public"."supplier_invoices" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "supplier_invoices_select" ON "public"."supplier_invoices" FOR SELECT USING (("public"."is_finance_team_member"(NULL::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "supplier_invoices_update" ON "public"."supplier_invoices" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."support_team_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "support_team_members_select" ON "public"."support_team_members" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."support_teams" "st"
  WHERE (("st"."id" = "support_team_members"."team_id") AND ("st"."tenant_id" = "public"."get_my_tenant_id"())))));



ALTER TABLE "public"."support_teams" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "support_teams_select" ON "public"."support_teams" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "sustain_audits_select" ON "public"."sustainability_audits" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "sustain_audits_write_delete" ON "public"."sustainability_audits" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_audits_write_insert" ON "public"."sustainability_audits" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_audits_write_update" ON "public"."sustainability_audits" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_certs_select" ON "public"."sustainability_certifications" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "sustain_certs_write_delete" ON "public"."sustainability_certifications" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_certs_write_insert" ON "public"."sustainability_certifications" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_certs_write_update" ON "public"."sustainability_certifications" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_init_cat_select" ON "public"."sustainability_initiative_categories" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "sustain_init_cat_write_delete" ON "public"."sustainability_initiative_categories" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "sustain_init_cat_write_insert" ON "public"."sustainability_initiative_categories" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "sustain_init_cat_write_update" ON "public"."sustainability_initiative_categories" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "sustain_initiatives_select" ON "public"."sustainability_initiatives" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "sustain_initiatives_write_delete" ON "public"."sustainability_initiatives" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_initiatives_write_insert" ON "public"."sustainability_initiatives" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_initiatives_write_update" ON "public"."sustainability_initiatives" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_metric_types_select" ON "public"."sustainability_metric_types" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "sustain_metric_types_write_delete" ON "public"."sustainability_metric_types" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "sustain_metric_types_write_insert" ON "public"."sustainability_metric_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "sustain_metric_types_write_update" ON "public"."sustainability_metric_types" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text"])));



CREATE POLICY "sustain_metrics_select" ON "public"."sustainability_metrics" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "sustain_metrics_write_delete" ON "public"."sustainability_metrics" FOR DELETE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_metrics_write_insert" ON "public"."sustainability_metrics" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



CREATE POLICY "sustain_metrics_write_update" ON "public"."sustainability_metrics" FOR UPDATE USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"]))) WITH CHECK ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."has_module_role"('sustainability'::"text", ARRAY['admin'::"text", 'manager'::"text"])));



ALTER TABLE "public"."sustainability_audits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sustainability_certifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sustainability_initiative_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sustainability_initiatives" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sustainability_metric_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sustainability_metrics" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_modules" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenant_modules_delete_platform_admin" ON "public"."tenant_modules" FOR DELETE USING ("public"."is_platform_admin"());



CREATE POLICY "tenant_modules_insert_platform_admin" ON "public"."tenant_modules" FOR INSERT WITH CHECK ("public"."is_platform_admin"());



CREATE POLICY "tenant_modules_select" ON "public"."tenant_modules" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) OR "public"."is_platform_admin"()));



CREATE POLICY "tenant_read_staff_roles" ON "public"."staff_roles" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenants_select" ON "public"."tenants" FOR SELECT USING ((("id" = "public"."get_my_tenant_id"()) OR "public"."is_platform_admin"()));



ALTER TABLE "public"."ticket_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ticket_categories_select" ON "public"."ticket_categories" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



ALTER TABLE "public"."user_group_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_group_members_select" ON "public"."user_group_members" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."user_groups" "g"
  WHERE (("g"."id" = "user_group_members"."group_id") AND ("g"."tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_it_support"()))));



ALTER TABLE "public"."user_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_groups_select" ON "public"."user_groups" FOR SELECT USING ((("tenant_id" = "public"."get_my_tenant_id"()) AND "public"."is_it_support"()));



ALTER TABLE "public"."warehouses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "warehouses_insert" ON "public"."warehouses" FOR INSERT WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



CREATE POLICY "warehouses_select" ON "public"."warehouses" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



CREATE POLICY "warehouses_update" ON "public"."warehouses" FOR UPDATE USING (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"()))) WITH CHECK (("public"."is_finance_team_member"('finance'::"text") AND ("tenant_id" = "public"."get_my_tenant_id"())));



ALTER TABLE "public"."workflow_stages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "workflow_stages_select_tenant" ON "public"."workflow_stages" FOR SELECT USING (("tenant_id" = "public"."get_my_tenant_id"()));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."add_group_member"("p_group_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_group_member"("p_group_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_group_member"("p_group_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."add_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."am_i_finance"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."am_i_finance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."am_i_finance"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_stock_movement"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_stock_movement"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_stock_movement"() TO "service_role";



GRANT ALL ON TABLE "public"."material_catalog" TO "anon";
GRANT ALL ON TABLE "public"."material_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."material_catalog" TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_all_material_request_items"("p_batch_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_all_material_request_items"("p_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_all_material_request_items"("p_batch_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."line_item_receipts" TO "anon";
GRANT ALL ON TABLE "public"."line_item_receipts" TO "authenticated";
GRANT ALL ON TABLE "public"."line_item_receipts" TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_line_item_receipt"("p_receipt_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_line_item_receipt"("p_receipt_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_line_item_receipt"("p_receipt_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_material_request_item"("p_item_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_material_request_item"("p_item_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_material_request_item"("p_item_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."hr_payroll_runs" TO "anon";
GRANT ALL ON TABLE "public"."hr_payroll_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_payroll_runs" TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_payroll_run"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_payroll_run"("p_run_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_payroll_run"("p_run_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."asset_assignments" TO "anon";
GRANT ALL ON TABLE "public"."asset_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."asset_assignments" TO "service_role";



REVOKE ALL ON FUNCTION "public"."assign_asset"("p_asset_id" "uuid", "p_assigned_to" "uuid", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_asset"("p_asset_id" "uuid", "p_assigned_to" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_asset"("p_asset_id" "uuid", "p_assigned_to" "uuid", "p_notes" "text") TO "service_role";



GRANT ALL ON TABLE "public"."material_receipt_assignments" TO "anon";
GRANT ALL ON TABLE "public"."material_receipt_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."material_receipt_assignments" TO "service_role";



REVOKE ALL ON FUNCTION "public"."assign_receipt_access"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_receipt_access"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_receipt_access"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."assign_receivable_invoice_oif"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_receivable_invoice_oif"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_receivable_invoice_oif"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."assign_supplier_invoice_oif"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_supplier_invoice_oif"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_supplier_invoice_oif"() TO "service_role";



GRANT ALL ON TABLE "public"."it_tickets" TO "anon";
GRANT ALL ON TABLE "public"."it_tickets" TO "authenticated";
GRANT ALL ON TABLE "public"."it_tickets" TO "service_role";



REVOKE ALL ON FUNCTION "public"."assign_ticket"("p_ticket_id" "uuid", "p_assignee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_ticket"("p_ticket_id" "uuid", "p_assignee_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_ticket"("p_ticket_id" "uuid", "p_assignee_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_access_finance"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_access_finance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_access_finance"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_act_on_stage"("check_stage_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_act_on_stage"("check_stage_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_act_on_stage"("check_stage_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_manage_po_handoff"("p_purchase_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_manage_po_handoff"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_manage_po_handoff"("p_purchase_order_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancel_request"("p_request_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_request"("p_request_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_request"("p_request_id" "uuid", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_payment_against_receipt"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_payment_against_receipt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_payment_against_receipt"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_payroll_disbursement"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_payroll_disbursement"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_payroll_disbursement"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_po_completion_on_advance_application"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_po_completion_on_advance_application"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_po_completion_on_advance_application"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_po_completion_on_cash_bank"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_po_completion_on_cash_bank"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_po_completion_on_cash_bank"() TO "service_role";



GRANT ALL ON TABLE "public"."purchase_orders" TO "anon";
GRANT ALL ON TABLE "public"."purchase_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."purchase_orders" TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_purchase_order_manually"("p_purchase_order_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_purchase_order_manually"("p_purchase_order_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_purchase_order_manually"("p_purchase_order_id" "uuid", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."confirm_po_delivered"("p_purchase_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."confirm_po_delivered"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."confirm_po_delivered"("p_purchase_order_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."access_requests" TO "anon";
GRANT ALL ON TABLE "public"."access_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."access_requests" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_access_request"("p_resource" "text", "p_access_level" "text", "p_justification" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_access_request"("p_resource" "text", "p_access_level" "text", "p_justification" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_access_request"("p_resource" "text", "p_access_level" "text", "p_justification" "text") TO "service_role";



GRANT ALL ON TABLE "public"."assets" TO "anon";
GRANT ALL ON TABLE "public"."assets" TO "authenticated";
GRANT ALL ON TABLE "public"."assets" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_asset"("p_type" "text", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_date" "date", "p_purchase_cost" numeric, "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_asset"("p_type" "text", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_date" "date", "p_purchase_cost" numeric, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_asset"("p_type" "text", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_date" "date", "p_purchase_cost" numeric, "p_notes" "text") TO "service_role";



GRANT ALL ON TABLE "public"."asset_requests" TO "anon";
GRANT ALL ON TABLE "public"."asset_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."asset_requests" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_asset_request"("p_asset_type" "text", "p_item_description" "text", "p_justification" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_asset_request"("p_asset_type" "text", "p_item_description" "text", "p_justification" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_asset_request"("p_asset_type" "text", "p_item_description" "text", "p_justification" "text") TO "service_role";



GRANT ALL ON TABLE "public"."faqs" TO "anon";
GRANT ALL ON TABLE "public"."faqs" TO "authenticated";
GRANT ALL ON TABLE "public"."faqs" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_faq"("p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_faq"("p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_faq"("p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."user_groups" TO "anon";
GRANT ALL ON TABLE "public"."user_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."user_groups" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_group"("p_name" "text", "p_description" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_group"("p_name" "text", "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_group"("p_name" "text", "p_description" "text") TO "service_role";



GRANT ALL ON TABLE "public"."kb_articles" TO "anon";
GRANT ALL ON TABLE "public"."kb_articles" TO "authenticated";
GRANT ALL ON TABLE "public"."kb_articles" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_kb_article"("p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_kb_article"("p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_kb_article"("p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."licenses" TO "anon";
GRANT ALL ON TABLE "public"."licenses" TO "authenticated";
GRANT ALL ON TABLE "public"."licenses" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_license"("p_asset_id" "uuid", "p_seats_total" integer, "p_license_key" "text", "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_license"("p_asset_id" "uuid", "p_seats_total" integer, "p_license_key" "text", "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_license"("p_asset_id" "uuid", "p_seats_total" integer, "p_license_key" "text", "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_payroll_run"("p_period" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_payroll_run"("p_period" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_payroll_run"("p_period" "text") TO "service_role";



GRANT ALL ON TABLE "public"."problems" TO "anon";
GRANT ALL ON TABLE "public"."problems" TO "authenticated";
GRANT ALL ON TABLE "public"."problems" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_problem"("p_title" "text", "p_description" "text", "p_category" "text", "p_priority" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_problem"("p_title" "text", "p_description" "text", "p_category" "text", "p_priority" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_problem"("p_title" "text", "p_description" "text", "p_category" "text", "p_priority" "text") TO "service_role";



GRANT ALL ON TABLE "public"."support_teams" TO "anon";
GRANT ALL ON TABLE "public"."support_teams" TO "authenticated";
GRANT ALL ON TABLE "public"."support_teams" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_support_team"("p_name" "text", "p_description" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_support_team"("p_name" "text", "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_support_team"("p_name" "text", "p_description" "text") TO "service_role";



GRANT ALL ON TABLE "public"."ticket_categories" TO "anon";
GRANT ALL ON TABLE "public"."ticket_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_categories" TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_ticket_category"("p_code" "text", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_ticket_category"("p_code" "text", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_ticket_category"("p_code" "text", "p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."decide_access_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."decide_access_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decide_access_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."decide_asset_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."decide_asset_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decide_asset_request"("p_request_id" "uuid", "p_decision" "text", "p_notes" "text") TO "service_role";



GRANT ALL ON TABLE "public"."po_edits" TO "anon";
GRANT ALL ON TABLE "public"."po_edits" TO "authenticated";
GRANT ALL ON TABLE "public"."po_edits" TO "service_role";



REVOKE ALL ON FUNCTION "public"."edit_purchase_order"("p_purchase_order_id" "uuid", "p_vendor_name" "text", "p_amount" numeric, "p_reason" "text", "p_initial_po_number" "text", "p_currency" "text", "p_delivery_date" "date", "p_project_sap_no" "text", "p_payment_conditions" "text", "p_terms_of_delivery" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."edit_purchase_order"("p_purchase_order_id" "uuid", "p_vendor_name" "text", "p_amount" numeric, "p_reason" "text", "p_initial_po_number" "text", "p_currency" "text", "p_delivery_date" "date", "p_project_sap_no" "text", "p_payment_conditions" "text", "p_terms_of_delivery" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."edit_purchase_order"("p_purchase_order_id" "uuid", "p_vendor_name" "text", "p_amount" numeric, "p_reason" "text", "p_initial_po_number" "text", "p_currency" "text", "p_delivery_date" "date", "p_project_sap_no" "text", "p_payment_conditions" "text", "p_terms_of_delivery" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."end_impersonation"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."end_impersonation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."end_impersonation"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fulfill_asset_request"("p_request_id" "uuid", "p_asset_id" "uuid", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fulfill_asset_request"("p_request_id" "uuid", "p_asset_id" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fulfill_asset_request"("p_request_id" "uuid", "p_asset_id" "uuid", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_bd_lead_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_bd_lead_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_bd_lead_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_bd_opportunity_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_bd_opportunity_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_bd_opportunity_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_bd_proposal_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_bd_proposal_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_bd_proposal_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_bd_tender_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_bd_tender_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_bd_tender_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_hr_employee_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_hr_employee_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_hr_employee_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_hr_leave_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_hr_leave_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_hr_leave_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_law_case_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_law_case_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_law_case_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_law_compliance_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_law_compliance_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_law_compliance_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_law_contract_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_law_contract_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_law_contract_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_machine_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_machine_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_machine_no"() TO "service_role";



GRANT ALL ON TABLE "public"."hr_payroll_items" TO "anon";
GRANT ALL ON TABLE "public"."hr_payroll_items" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_payroll_items" TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_payroll_items"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_payroll_items"("p_run_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_payroll_items"("p_run_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."generate_pmo_project_no"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_pmo_project_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_pmo_project_no"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_access_requests"("p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_access_requests"("p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_access_requests"("p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_active_impersonation"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_active_impersonation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_active_impersonation"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_all_tickets"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_all_tickets"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_tickets"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_asset_assignments"("p_active_only" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_asset_assignments"("p_active_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_asset_assignments"("p_active_only" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_asset_requests"("p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_asset_requests"("p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_asset_requests"("p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_assets"("p_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_assets"("p_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_assets"("p_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_companies_overview"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_companies_overview"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_companies_overview"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_company_analytics"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_company_analytics"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_company_analytics"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_faqs"("p_category" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_faqs"("p_category" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_faqs"("p_category" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_group_members"("p_group_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_group_members"("p_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_group_members"("p_group_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_groups"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_groups"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_groups"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_kb_articles"("p_category" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_kb_articles"("p_category" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_kb_articles"("p_category" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_licenses"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_licenses"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_licenses"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_access_requests"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_access_requests"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_access_requests"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_approval_queue"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_approval_queue"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_approval_queue"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_asset_requests"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_asset_requests"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_asset_requests"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_invoice_approval_queue"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_invoice_approval_queue"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_invoice_approval_queue"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_procurement_orders"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_procurement_orders"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_procurement_orders"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_purchase_orders"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_purchase_orders"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_purchase_orders"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_tenant_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_tenant_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_tenant_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_tenant_status"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_tenant_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_tenant_status"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_tickets"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_tickets"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_tickets"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_offer_detail"("p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_offer_detail"("p_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_offer_detail"("p_request_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_pending_material_request_batches"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_pending_material_request_batches"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_material_request_batches"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_pending_ticket_approvals"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_pending_ticket_approvals"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_ticket_approvals"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_platform_dashboard_stats"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_platform_dashboard_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_platform_dashboard_stats"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_po_detail"("p_purchase_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_po_detail"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_po_detail"("p_purchase_order_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_po_edit_history"("po_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_po_edit_history"("po_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_po_edit_history"("po_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_po_pdf_data"("p_purchase_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_po_pdf_data"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_po_pdf_data"("p_purchase_order_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."priority_levels" TO "anon";
GRANT ALL ON TABLE "public"."priority_levels" TO "authenticated";
GRANT ALL ON TABLE "public"."priority_levels" TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_priority_levels"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_priority_levels"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_priority_levels"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_problem_tickets"("p_problem_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_problem_tickets"("p_problem_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_problem_tickets"("p_problem_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_problems"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_problems"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_problems"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_procurement_info"("p_organization_id" "uuid", "p_initial_po_number" "text", "p_company" "text", "p_purchaser" "text", "p_mr_number" "text", "p_po_number" "text", "p_po_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_procurement_info"("p_organization_id" "uuid", "p_initial_po_number" "text", "p_company" "text", "p_purchaser" "text", "p_mr_number" "text", "p_po_number" "text", "p_po_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_procurement_info"("p_organization_id" "uuid", "p_initial_po_number" "text", "p_company" "text", "p_purchaser" "text", "p_mr_number" "text", "p_po_number" "text", "p_po_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_request_tracking"("p_organization_id" "uuid", "p_mr_number" "text", "p_po_number" "text", "p_company" "text", "p_description" "text", "p_subcontractor" "text", "p_mr_originator" "text", "p_pending_authority" "text", "p_status" "text", "p_cost_code" "text", "p_place_of_use" "text", "p_mr_date_from" "date", "p_mr_date_to" "date", "p_po_date_from" "date", "p_po_date_to" "date", "p_delivery_date_from" "date", "p_delivery_date_to" "date", "p_market_offer_date_from" "date", "p_market_offer_date_to" "date", "p_closing_date_from" "date", "p_closing_date_to" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_request_tracking"("p_organization_id" "uuid", "p_mr_number" "text", "p_po_number" "text", "p_company" "text", "p_description" "text", "p_subcontractor" "text", "p_mr_originator" "text", "p_pending_authority" "text", "p_status" "text", "p_cost_code" "text", "p_place_of_use" "text", "p_mr_date_from" "date", "p_mr_date_to" "date", "p_po_date_from" "date", "p_po_date_to" "date", "p_delivery_date_from" "date", "p_delivery_date_to" "date", "p_market_offer_date_from" "date", "p_market_offer_date_to" "date", "p_closing_date_from" "date", "p_closing_date_to" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_request_tracking"("p_organization_id" "uuid", "p_mr_number" "text", "p_po_number" "text", "p_company" "text", "p_description" "text", "p_subcontractor" "text", "p_mr_originator" "text", "p_pending_authority" "text", "p_status" "text", "p_cost_code" "text", "p_place_of_use" "text", "p_mr_date_from" "date", "p_mr_date_to" "date", "p_po_date_from" "date", "p_po_date_to" "date", "p_delivery_date_from" "date", "p_delivery_date_to" "date", "p_market_offer_date_from" "date", "p_market_offer_date_to" "date", "p_closing_date_from" "date", "p_closing_date_to" "date") TO "service_role";



GRANT ALL ON TABLE "public"."sla_policies" TO "anon";
GRANT ALL ON TABLE "public"."sla_policies" TO "authenticated";
GRANT ALL ON TABLE "public"."sla_policies" TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_sla_policies"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_sla_policies"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sla_policies"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_support_team_members"("p_team_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_support_team_members"("p_team_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_support_team_members"("p_team_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_support_teams"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_support_teams"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_support_teams"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_tenant_modules"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_tenant_modules"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tenant_modules"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_tenant_workflow_stages"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_tenant_workflow_stages"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tenant_workflow_stages"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_ticket_categories"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_ticket_categories"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_ticket_categories"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_vendor_evaluation"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_vendor_evaluation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_vendor_evaluation"() TO "service_role";



GRANT ALL ON TABLE "public"."approval_delegations" TO "anon";
GRANT ALL ON TABLE "public"."approval_delegations" TO "authenticated";
GRANT ALL ON TABLE "public"."approval_delegations" TO "service_role";



REVOKE ALL ON FUNCTION "public"."grant_delegation"("p_delegate_user_id" "uuid", "p_workflow_stage_id" "uuid", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."grant_delegation"("p_delegate_user_id" "uuid", "p_workflow_stage_id" "uuid", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."grant_delegation"("p_delegate_user_id" "uuid", "p_workflow_stage_id" "uuid", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."handle_updated_at_generic"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_updated_at_generic"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_updated_at_generic"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."has_module_role"("p_module" "text", "p_roles" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_module_role"("p_module" "text", "p_roles" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_module_role"("p_module" "text", "p_roles" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."has_po_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_po_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_po_access"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."has_receipt_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_receipt_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_receipt_access"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_any_module_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_any_module_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_any_module_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_business_dev"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_business_dev"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_business_dev"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_finance_team_member"("p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_finance_team_member"("p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_finance_team_member"("p_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_hr_team_member"("p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_hr_team_member"("p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_hr_team_member"("p_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_it_support"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_it_support"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_it_support"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_payroll_approver"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_payroll_approver"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_payroll_approver"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_platform_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_platform_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_platform_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."link_ticket_to_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."link_ticket_to_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."link_ticket_to_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."link_vendor_account_on_offer"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."link_vendor_account_on_offer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."link_vendor_account_on_offer"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_receipt_assignees"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_receipt_assignees"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_receipt_assignees"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_asset_tag"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_asset_tag"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_asset_tag"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_doc_number"("p_tenant_id" "uuid", "p_doc_type" "text", "p_prefix" "text", "p_pad" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_doc_number"("p_tenant_id" "uuid", "p_doc_type" "text", "p_prefix" "text", "p_pad" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_doc_number"("p_tenant_id" "uuid", "p_doc_type" "text", "p_prefix" "text", "p_pad" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_material_catalog_code"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_material_catalog_code"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_material_catalog_code"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_mr_number"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_mr_number"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_mr_number"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_problem_number"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_problem_number"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_problem_number"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_ticket_number"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_ticket_number"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_ticket_number"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."platform_has_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."platform_has_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."platform_has_admin"() TO "service_role";
GRANT ALL ON FUNCTION "public"."platform_has_admin"() TO "anon";



REVOKE ALL ON FUNCTION "public"."post_issue_items_to_stock"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."post_issue_items_to_stock"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."post_issue_items_to_stock"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."post_receipt_to_stock"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."post_receipt_to_stock"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."post_receipt_to_stock"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."prevent_invoice_organization_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prevent_invoice_organization_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_invoice_organization_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."protect_delegation_immutable_fields"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."protect_delegation_immutable_fields"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."protect_delegation_immutable_fields"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."protect_po_immutable_fields"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."protect_po_immutable_fields"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."protect_po_immutable_fields"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_approval_decision"("p_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid", "p_selected_offer_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_approval_decision"("p_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid", "p_selected_offer_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_approval_decision"("p_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid", "p_selected_offer_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."hr_employee_compensation" TO "anon";
GRANT ALL ON TABLE "public"."hr_employee_compensation" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_employee_compensation" TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_employee_compensation"("p_employee_id" "uuid", "p_basic_salary" numeric, "p_effective_date" "date", "p_contract_reference" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_employee_compensation"("p_employee_id" "uuid", "p_basic_salary" numeric, "p_effective_date" "date", "p_contract_reference" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_employee_compensation"("p_employee_id" "uuid", "p_basic_salary" numeric, "p_effective_date" "date", "p_contract_reference" "text", "p_note" "text") TO "service_role";



GRANT ALL ON TABLE "public"."goods_issues" TO "anon";
GRANT ALL ON TABLE "public"."goods_issues" TO "authenticated";
GRANT ALL ON TABLE "public"."goods_issues" TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_goods_issue"("p_warehouse_id" "uuid", "p_project_label" "text", "p_voucher_no" "text", "p_received_by_name" "text", "p_approved_by_name" "text", "p_items" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_goods_issue"("p_warehouse_id" "uuid", "p_project_label" "text", "p_voucher_no" "text", "p_received_by_name" "text", "p_approved_by_name" "text", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_goods_issue"("p_warehouse_id" "uuid", "p_project_label" "text", "p_voucher_no" "text", "p_received_by_name" "text", "p_approved_by_name" "text", "p_items" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_invoice_approval_decision"("p_invoice_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_invoice_approval_decision"("p_invoice_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_invoice_approval_decision"("p_invoice_request_id" "uuid", "p_decision" "text", "p_comment" "text", "p_acting_on_behalf_of" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_warehouse_id" "uuid", "p_voucher_no" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_warehouse_id" "uuid", "p_voucher_no" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_line_item_receipt"("p_line_item_id" "uuid", "p_received_qty" numeric, "p_warehouse_id" "uuid", "p_voucher_no" "text", "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_po_pdf"("p_purchase_order_id" "uuid", "p_storage_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_po_pdf"("p_purchase_order_id" "uuid", "p_storage_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_po_pdf"("p_purchase_order_id" "uuid", "p_storage_path" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_ticket_approval"("p_ticket_id" "uuid", "p_decision" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_ticket_approval"("p_ticket_id" "uuid", "p_decision" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_ticket_approval"("p_ticket_id" "uuid", "p_decision" "text", "p_notes" "text") TO "service_role";



GRANT ALL ON TABLE "public"."material_request_items" TO "anon";
GRANT ALL ON TABLE "public"."material_request_items" TO "authenticated";
GRANT ALL ON TABLE "public"."material_request_items" TO "service_role";



REVOKE ALL ON FUNCTION "public"."reject_all_material_request_items"("p_batch_id" "uuid", "p_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reject_all_material_request_items"("p_batch_id" "uuid", "p_message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_all_material_request_items"("p_batch_id" "uuid", "p_message" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reject_material_request_item"("p_item_id" "uuid", "p_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reject_material_request_item"("p_item_id" "uuid", "p_message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_material_request_item"("p_item_id" "uuid", "p_message" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reject_payroll_run"("p_run_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reject_payroll_run"("p_run_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_payroll_run"("p_run_id" "uuid", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."remove_group_member"("p_group_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remove_group_member"("p_group_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_group_member"("p_group_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."remove_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remove_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."resolve_or_create_vendor_account"("p_tenant_id" "uuid", "p_vendor_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resolve_or_create_vendor_account"("p_tenant_id" "uuid", "p_vendor_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_or_create_vendor_account"("p_tenant_id" "uuid", "p_vendor_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."return_asset"("p_assignment_id" "uuid", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."return_asset"("p_assignment_id" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."return_asset"("p_assignment_id" "uuid", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."revoke_receipt_access"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revoke_receipt_access"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_receipt_access"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."seed_tenant_defaults"("p_tenant_id" "uuid", "p_industry_template" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."seed_tenant_defaults"("p_tenant_id" "uuid", "p_industry_template" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."seed_tenant_defaults"("p_tenant_id" "uuid", "p_industry_template" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_account_category_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_account_category_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_account_category_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_asset_tag"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_asset_tag"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_asset_tag"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_cash_bank_transaction_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_cash_bank_transaction_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_cash_bank_transaction_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_cost_center_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_cost_center_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_cost_center_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_department_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_department_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_department_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_expenditure_slip_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_expenditure_slip_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_expenditure_slip_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_invoice_request_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_invoice_request_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_invoice_request_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_material_lookup_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_material_lookup_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_material_lookup_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_material_request_batch_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_material_request_batch_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_material_request_batch_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_material_request_item_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_material_request_item_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_material_request_item_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_organization_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_organization_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_organization_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_petty_cash_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_petty_cash_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_petty_cash_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_problem_number"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_problem_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_problem_number"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_receivable_invoice_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_receivable_invoice_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_receivable_invoice_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_request_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_request_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_request_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_request_mr_number"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_request_mr_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_request_mr_number"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_sap_payment_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_sap_payment_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_sap_payment_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_supplier_invoice_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_supplier_invoice_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_supplier_invoice_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_tenant_modules"("p_tenant_id" "uuid", "p_modules" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_tenant_modules"("p_tenant_id" "uuid", "p_modules" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_tenant_modules"("p_tenant_id" "uuid", "p_modules" "text"[]) TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "anon";
GRANT ALL ON TABLE "public"."tenants" TO "authenticated";
GRANT ALL ON TABLE "public"."tenants" TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_tenant_status"("p_tenant_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_tenant_status"("p_tenant_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_tenant_status"("p_tenant_id" "uuid", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_ticket_number"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_ticket_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_ticket_number"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_warehouse_defaults"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_warehouse_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_warehouse_defaults"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."share_purchase_order"("p_purchase_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."share_purchase_order"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."share_purchase_order"("p_purchase_order_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."impersonation_sessions" TO "anon";
GRANT ALL ON TABLE "public"."impersonation_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."impersonation_sessions" TO "service_role";



REVOKE ALL ON FUNCTION "public"."start_impersonation"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."start_impersonation"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."start_impersonation"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."requests" TO "anon";
GRANT ALL ON TABLE "public"."requests" TO "authenticated";
GRANT ALL ON TABLE "public"."requests" TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_offers_for_approval"("p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_offers_for_approval"("p_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_offers_for_approval"("p_request_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_payroll_run"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_payroll_run"("p_run_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_payroll_run"("p_run_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_request_with_line_items"("p_item_description" "text", "p_quantity" integer, "p_cost_center_id" "uuid", "p_delivery_date" "date", "p_subcontractor" "text", "p_line_items" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_request_with_line_items"("p_item_description" "text", "p_quantity" integer, "p_cost_center_id" "uuid", "p_delivery_date" "date", "p_subcontractor" "text", "p_line_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_request_with_line_items"("p_item_description" "text", "p_quantity" integer, "p_cost_center_id" "uuid", "p_delivery_date" "date", "p_subcontractor" "text", "p_line_items" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."supplier_invoice_outstanding"("p_invoice_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."supplier_invoice_outstanding"("p_invoice_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."supplier_invoice_outstanding"("p_invoice_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."supplier_invoice_payable_now"("p_invoice_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."supplier_invoice_payable_now"("p_invoice_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."supplier_invoice_payable_now"("p_invoice_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."supplier_invoice_receipt_cap"("p_invoice_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."supplier_invoice_receipt_cap"("p_invoice_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."supplier_invoice_receipt_cap"("p_invoice_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."touch_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."try_complete_po"("p_purchase_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."try_complete_po"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."try_complete_po"("p_purchase_order_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."unlink_ticket_from_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unlink_ticket_from_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unlink_ticket_from_problem"("p_problem_id" "uuid", "p_ticket_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."app_users" TO "anon";
GRANT ALL ON TABLE "public"."app_users" TO "authenticated";
GRANT ALL ON TABLE "public"."app_users" TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_app_user"("p_user_id" "uuid", "p_department_id" "uuid", "p_role_title" "text", "p_is_platform_admin" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_app_user"("p_user_id" "uuid", "p_department_id" "uuid", "p_role_title" "text", "p_is_platform_admin" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_app_user"("p_user_id" "uuid", "p_department_id" "uuid", "p_role_title" "text", "p_is_platform_admin" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_asset"("p_asset_id" "uuid", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_cost" numeric, "p_status" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_asset"("p_asset_id" "uuid", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_cost" numeric, "p_status" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_asset"("p_asset_id" "uuid", "p_name" "text", "p_category" "text", "p_serial_number" "text", "p_vendor" "text", "p_purchase_cost" numeric, "p_status" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_faq"("p_faq_id" "uuid", "p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_faq"("p_faq_id" "uuid", "p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_faq"("p_faq_id" "uuid", "p_question" "text", "p_answer" "text", "p_category" "text", "p_sort_order" integer, "p_is_published" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_kb_article"("p_article_id" "uuid", "p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_kb_article"("p_article_id" "uuid", "p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_kb_article"("p_article_id" "uuid", "p_title" "text", "p_content" "text", "p_category" "text", "p_is_published" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_license"("p_license_id" "uuid", "p_license_key" "text", "p_seats_total" integer, "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_license"("p_license_id" "uuid", "p_license_key" "text", "p_seats_total" integer, "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_license"("p_license_id" "uuid", "p_license_key" "text", "p_seats_total" integer, "p_vendor" "text", "p_expiry_date" "date", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_payroll_item"("p_item_id" "uuid", "p_allowances" numeric, "p_deductions" numeric, "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_payroll_item"("p_item_id" "uuid", "p_allowances" numeric, "p_deductions" numeric, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_payroll_item"("p_item_id" "uuid", "p_allowances" numeric, "p_deductions" numeric, "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_priority_level"("p_code" "text", "p_label" "text", "p_color" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_priority_level"("p_code" "text", "p_label" "text", "p_color" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_priority_level"("p_code" "text", "p_label" "text", "p_color" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_problem"("p_problem_id" "uuid", "p_status" "text", "p_root_cause" "text", "p_assigned_to" "uuid", "p_title" "text", "p_description" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_problem"("p_problem_id" "uuid", "p_status" "text", "p_root_cause" "text", "p_assigned_to" "uuid", "p_title" "text", "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_problem"("p_problem_id" "uuid", "p_status" "text", "p_root_cause" "text", "p_assigned_to" "uuid", "p_title" "text", "p_description" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_support_team"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_support_team"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_support_team"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_is_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_ticket_category"("p_id" "uuid", "p_name" "text", "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_ticket_category"("p_id" "uuid", "p_name" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_ticket_category"("p_id" "uuid", "p_name" "text", "p_is_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_ticket_status"("p_ticket_id" "uuid", "p_status" "text", "p_resolution_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_ticket_status"("p_ticket_id" "uuid", "p_status" "text", "p_resolution_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_ticket_status"("p_ticket_id" "uuid", "p_status" "text", "p_resolution_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_workflow_stage_threshold"("p_stage_id" "uuid", "p_threshold_amount" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_workflow_stage_threshold"("p_stage_id" "uuid", "p_threshold_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_workflow_stage_threshold"("p_stage_id" "uuid", "p_threshold_amount" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."upsert_sla_policy"("p_priority" "text", "p_target_hours" integer, "p_description" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upsert_sla_policy"("p_priority" "text", "p_target_hours" integer, "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_sla_policy"("p_priority" "text", "p_target_hours" integer, "p_description" "text") TO "service_role";



GRANT ALL ON TABLE "public"."account_categories" TO "anon";
GRANT ALL ON TABLE "public"."account_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."account_categories" TO "service_role";



GRANT ALL ON TABLE "public"."accounts" TO "anon";
GRANT ALL ON TABLE "public"."accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."accounts" TO "service_role";



GRANT ALL ON TABLE "public"."advance_payment_applications" TO "anon";
GRANT ALL ON TABLE "public"."advance_payment_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."advance_payment_applications" TO "service_role";



GRANT ALL ON TABLE "public"."advance_payments" TO "anon";
GRANT ALL ON TABLE "public"."advance_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."advance_payments" TO "service_role";



GRANT ALL ON TABLE "public"."approval_actions" TO "anon";
GRANT ALL ON TABLE "public"."approval_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."approval_actions" TO "service_role";



GRANT ALL ON TABLE "public"."approval_assignments" TO "anon";
GRANT ALL ON TABLE "public"."approval_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."approval_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."bd_activities" TO "anon";
GRANT ALL ON TABLE "public"."bd_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_activities" TO "service_role";



GRANT ALL ON TABLE "public"."bd_client_categories" TO "anon";
GRANT ALL ON TABLE "public"."bd_client_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_client_categories" TO "service_role";



GRANT ALL ON TABLE "public"."bd_clients" TO "anon";
GRANT ALL ON TABLE "public"."bd_clients" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_clients" TO "service_role";



GRANT ALL ON TABLE "public"."bd_contacts" TO "anon";
GRANT ALL ON TABLE "public"."bd_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_contacts" TO "service_role";



GRANT ALL ON TABLE "public"."bd_lead_sources" TO "anon";
GRANT ALL ON TABLE "public"."bd_lead_sources" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_lead_sources" TO "service_role";



GRANT ALL ON TABLE "public"."bd_lead_statuses" TO "anon";
GRANT ALL ON TABLE "public"."bd_lead_statuses" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_lead_statuses" TO "service_role";



GRANT ALL ON TABLE "public"."bd_leads" TO "anon";
GRANT ALL ON TABLE "public"."bd_leads" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_leads" TO "service_role";



GRANT ALL ON TABLE "public"."bd_opportunities" TO "anon";
GRANT ALL ON TABLE "public"."bd_opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_opportunities" TO "service_role";



GRANT ALL ON TABLE "public"."bd_opportunity_stages" TO "anon";
GRANT ALL ON TABLE "public"."bd_opportunity_stages" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_opportunity_stages" TO "service_role";



GRANT ALL ON TABLE "public"."bd_proposal_statuses" TO "anon";
GRANT ALL ON TABLE "public"."bd_proposal_statuses" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_proposal_statuses" TO "service_role";



GRANT ALL ON TABLE "public"."bd_proposal_templates" TO "anon";
GRANT ALL ON TABLE "public"."bd_proposal_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_proposal_templates" TO "service_role";



GRANT ALL ON TABLE "public"."bd_proposal_types" TO "anon";
GRANT ALL ON TABLE "public"."bd_proposal_types" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_proposal_types" TO "service_role";



GRANT ALL ON TABLE "public"."bd_proposals" TO "anon";
GRANT ALL ON TABLE "public"."bd_proposals" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_proposals" TO "service_role";



GRANT ALL ON TABLE "public"."bd_tender_types" TO "anon";
GRANT ALL ON TABLE "public"."bd_tender_types" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_tender_types" TO "service_role";



GRANT ALL ON TABLE "public"."bd_tenders" TO "anon";
GRANT ALL ON TABLE "public"."bd_tenders" TO "authenticated";
GRANT ALL ON TABLE "public"."bd_tenders" TO "service_role";



GRANT ALL ON TABLE "public"."cash_bank_transactions" TO "anon";
GRANT ALL ON TABLE "public"."cash_bank_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."cash_bank_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."cost_centers" TO "anon";
GRANT ALL ON TABLE "public"."cost_centers" TO "authenticated";
GRANT ALL ON TABLE "public"."cost_centers" TO "service_role";



GRANT ALL ON TABLE "public"."departments" TO "anon";
GRANT ALL ON TABLE "public"."departments" TO "authenticated";
GRANT ALL ON TABLE "public"."departments" TO "service_role";



GRANT ALL ON TABLE "public"."doc_sequences" TO "anon";
GRANT ALL ON TABLE "public"."doc_sequences" TO "authenticated";
GRANT ALL ON TABLE "public"."doc_sequences" TO "service_role";



GRANT ALL ON TABLE "public"."expenditure_slips" TO "anon";
GRANT ALL ON TABLE "public"."expenditure_slips" TO "authenticated";
GRANT ALL ON TABLE "public"."expenditure_slips" TO "service_role";



GRANT ALL ON TABLE "public"."external_material_groups" TO "anon";
GRANT ALL ON TABLE "public"."external_material_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."external_material_groups" TO "service_role";



GRANT ALL ON TABLE "public"."finance_team_members" TO "anon";
GRANT ALL ON TABLE "public"."finance_team_members" TO "authenticated";
GRANT ALL ON TABLE "public"."finance_team_members" TO "service_role";



GRANT ALL ON TABLE "public"."fuel_logs" TO "anon";
GRANT ALL ON TABLE "public"."fuel_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."fuel_logs" TO "service_role";



GRANT ALL ON TABLE "public"."goods_issue_items" TO "anon";
GRANT ALL ON TABLE "public"."goods_issue_items" TO "authenticated";
GRANT ALL ON TABLE "public"."goods_issue_items" TO "service_role";



GRANT ALL ON TABLE "public"."hr_appraisals" TO "anon";
GRANT ALL ON TABLE "public"."hr_appraisals" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_appraisals" TO "service_role";



GRANT ALL ON TABLE "public"."hr_attendance" TO "anon";
GRANT ALL ON TABLE "public"."hr_attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_attendance" TO "service_role";



GRANT ALL ON TABLE "public"."hr_employee_current_compensation" TO "anon";
GRANT ALL ON TABLE "public"."hr_employee_current_compensation" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_employee_current_compensation" TO "service_role";



GRANT ALL ON TABLE "public"."hr_employees" TO "anon";
GRANT ALL ON TABLE "public"."hr_employees" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_employees" TO "service_role";



GRANT ALL ON TABLE "public"."hr_job_applications" TO "anon";
GRANT ALL ON TABLE "public"."hr_job_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_job_applications" TO "service_role";



GRANT ALL ON TABLE "public"."hr_job_postings" TO "anon";
GRANT ALL ON TABLE "public"."hr_job_postings" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_job_postings" TO "service_role";



GRANT ALL ON TABLE "public"."hr_leave_requests" TO "anon";
GRANT ALL ON TABLE "public"."hr_leave_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_leave_requests" TO "service_role";



GRANT ALL ON TABLE "public"."hr_leave_types" TO "anon";
GRANT ALL ON TABLE "public"."hr_leave_types" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_leave_types" TO "service_role";



GRANT ALL ON TABLE "public"."hr_positions" TO "anon";
GRANT ALL ON TABLE "public"."hr_positions" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_positions" TO "service_role";



GRANT ALL ON TABLE "public"."hr_team_members" TO "anon";
GRANT ALL ON TABLE "public"."hr_team_members" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_team_members" TO "service_role";



GRANT ALL ON TABLE "public"."hr_trainings" TO "anon";
GRANT ALL ON TABLE "public"."hr_trainings" TO "authenticated";
GRANT ALL ON TABLE "public"."hr_trainings" TO "service_role";



GRANT ALL ON TABLE "public"."impersonation_logs" TO "anon";
GRANT ALL ON TABLE "public"."impersonation_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."impersonation_logs" TO "service_role";



GRANT ALL ON TABLE "public"."invitations" TO "anon";
GRANT ALL ON TABLE "public"."invitations" TO "authenticated";
GRANT ALL ON TABLE "public"."invitations" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_requests" TO "anon";
GRANT ALL ON TABLE "public"."invoice_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_requests" TO "service_role";



GRANT ALL ON TABLE "public"."law_case_hearings" TO "anon";
GRANT ALL ON TABLE "public"."law_case_hearings" TO "authenticated";
GRANT ALL ON TABLE "public"."law_case_hearings" TO "service_role";



GRANT ALL ON TABLE "public"."law_case_types" TO "anon";
GRANT ALL ON TABLE "public"."law_case_types" TO "authenticated";
GRANT ALL ON TABLE "public"."law_case_types" TO "service_role";



GRANT ALL ON TABLE "public"."law_cases" TO "anon";
GRANT ALL ON TABLE "public"."law_cases" TO "authenticated";
GRANT ALL ON TABLE "public"."law_cases" TO "service_role";



GRANT ALL ON TABLE "public"."law_compliance_register" TO "anon";
GRANT ALL ON TABLE "public"."law_compliance_register" TO "authenticated";
GRANT ALL ON TABLE "public"."law_compliance_register" TO "service_role";



GRANT ALL ON TABLE "public"."law_contract_types" TO "anon";
GRANT ALL ON TABLE "public"."law_contract_types" TO "authenticated";
GRANT ALL ON TABLE "public"."law_contract_types" TO "service_role";



GRANT ALL ON TABLE "public"."law_contracts" TO "anon";
GRANT ALL ON TABLE "public"."law_contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."law_contracts" TO "service_role";



GRANT ALL ON TABLE "public"."law_regulatory_filings" TO "anon";
GRANT ALL ON TABLE "public"."law_regulatory_filings" TO "authenticated";
GRANT ALL ON TABLE "public"."law_regulatory_filings" TO "service_role";



GRANT ALL ON TABLE "public"."request_line_items" TO "anon";
GRANT ALL ON TABLE "public"."request_line_items" TO "authenticated";
GRANT ALL ON TABLE "public"."request_line_items" TO "service_role";



GRANT ALL ON TABLE "public"."line_item_receipt_status" TO "anon";
GRANT ALL ON TABLE "public"."line_item_receipt_status" TO "authenticated";
GRANT ALL ON TABLE "public"."line_item_receipt_status" TO "service_role";



GRANT ALL ON TABLE "public"."machine_assignments" TO "anon";
GRANT ALL ON TABLE "public"."machine_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."machine_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."machine_types" TO "anon";
GRANT ALL ON TABLE "public"."machine_types" TO "authenticated";
GRANT ALL ON TABLE "public"."machine_types" TO "service_role";



GRANT ALL ON TABLE "public"."machines" TO "anon";
GRANT ALL ON TABLE "public"."machines" TO "authenticated";
GRANT ALL ON TABLE "public"."machines" TO "service_role";



GRANT ALL ON TABLE "public"."maintenance_requests" TO "anon";
GRANT ALL ON TABLE "public"."maintenance_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."maintenance_requests" TO "service_role";



GRANT ALL ON TABLE "public"."maintenance_types" TO "anon";
GRANT ALL ON TABLE "public"."maintenance_types" TO "authenticated";
GRANT ALL ON TABLE "public"."maintenance_types" TO "service_role";



GRANT ALL ON TABLE "public"."material_groups" TO "anon";
GRANT ALL ON TABLE "public"."material_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."material_groups" TO "service_role";



GRANT ALL ON TABLE "public"."material_request_batches" TO "anon";
GRANT ALL ON TABLE "public"."material_request_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."material_request_batches" TO "service_role";



GRANT ALL ON TABLE "public"."material_types" TO "anon";
GRANT ALL ON TABLE "public"."material_types" TO "authenticated";
GRANT ALL ON TABLE "public"."material_types" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."oif_sequences" TO "anon";
GRANT ALL ON TABLE "public"."oif_sequences" TO "authenticated";
GRANT ALL ON TABLE "public"."oif_sequences" TO "service_role";



GRANT ALL ON TABLE "public"."operation_logs" TO "anon";
GRANT ALL ON TABLE "public"."operation_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."operation_logs" TO "service_role";



GRANT ALL ON TABLE "public"."organizations" TO "anon";
GRANT ALL ON TABLE "public"."organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations" TO "service_role";



GRANT ALL ON TABLE "public"."payroll_approvers" TO "anon";
GRANT ALL ON TABLE "public"."payroll_approvers" TO "authenticated";
GRANT ALL ON TABLE "public"."payroll_approvers" TO "service_role";



GRANT ALL ON TABLE "public"."petty_cash_floats" TO "anon";
GRANT ALL ON TABLE "public"."petty_cash_floats" TO "authenticated";
GRANT ALL ON TABLE "public"."petty_cash_floats" TO "service_role";



GRANT ALL ON TABLE "public"."petty_cash_replenishments" TO "anon";
GRANT ALL ON TABLE "public"."petty_cash_replenishments" TO "authenticated";
GRANT ALL ON TABLE "public"."petty_cash_replenishments" TO "service_role";



GRANT ALL ON TABLE "public"."petty_cash_float_balances" TO "anon";
GRANT ALL ON TABLE "public"."petty_cash_float_balances" TO "authenticated";
GRANT ALL ON TABLE "public"."petty_cash_float_balances" TO "service_role";



GRANT ALL ON TABLE "public"."platform_settings" TO "anon";
GRANT ALL ON TABLE "public"."platform_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_settings" TO "service_role";



GRANT ALL ON TABLE "public"."pmo_milestones" TO "anon";
GRANT ALL ON TABLE "public"."pmo_milestones" TO "authenticated";
GRANT ALL ON TABLE "public"."pmo_milestones" TO "service_role";



GRANT ALL ON TABLE "public"."pmo_project_categories" TO "anon";
GRANT ALL ON TABLE "public"."pmo_project_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."pmo_project_categories" TO "service_role";



GRANT ALL ON TABLE "public"."pmo_projects" TO "anon";
GRANT ALL ON TABLE "public"."pmo_projects" TO "authenticated";
GRANT ALL ON TABLE "public"."pmo_projects" TO "service_role";



GRANT ALL ON TABLE "public"."pmo_resource_allocations" TO "anon";
GRANT ALL ON TABLE "public"."pmo_resource_allocations" TO "authenticated";
GRANT ALL ON TABLE "public"."pmo_resource_allocations" TO "service_role";



GRANT ALL ON TABLE "public"."pmo_task_types" TO "anon";
GRANT ALL ON TABLE "public"."pmo_task_types" TO "authenticated";
GRANT ALL ON TABLE "public"."pmo_task_types" TO "service_role";



GRANT ALL ON TABLE "public"."pmo_tasks" TO "anon";
GRANT ALL ON TABLE "public"."pmo_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."pmo_tasks" TO "service_role";



GRANT ALL ON SEQUENCE "public"."po_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."po_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."po_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."problem_tickets" TO "anon";
GRANT ALL ON TABLE "public"."problem_tickets" TO "authenticated";
GRANT ALL ON TABLE "public"."problem_tickets" TO "service_role";



GRANT ALL ON TABLE "public"."receivable_invoices" TO "anon";
GRANT ALL ON TABLE "public"."receivable_invoices" TO "authenticated";
GRANT ALL ON TABLE "public"."receivable_invoices" TO "service_role";



GRANT ALL ON TABLE "public"."request_offers" TO "anon";
GRANT ALL ON TABLE "public"."request_offers" TO "authenticated";
GRANT ALL ON TABLE "public"."request_offers" TO "service_role";



GRANT ALL ON TABLE "public"."sap_payments" TO "anon";
GRANT ALL ON TABLE "public"."sap_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."sap_payments" TO "service_role";



GRANT ALL ON TABLE "public"."staff_roles" TO "anon";
GRANT ALL ON TABLE "public"."staff_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."staff_roles" TO "service_role";



GRANT ALL ON TABLE "public"."stock_balances" TO "anon";
GRANT ALL ON TABLE "public"."stock_balances" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_balances" TO "service_role";



GRANT ALL ON TABLE "public"."stock_movements" TO "anon";
GRANT ALL ON TABLE "public"."stock_movements" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_movements" TO "service_role";



GRANT ALL ON TABLE "public"."supplier_invoices" TO "anon";
GRANT ALL ON TABLE "public"."supplier_invoices" TO "authenticated";
GRANT ALL ON TABLE "public"."supplier_invoices" TO "service_role";



GRANT ALL ON TABLE "public"."support_team_members" TO "anon";
GRANT ALL ON TABLE "public"."support_team_members" TO "authenticated";
GRANT ALL ON TABLE "public"."support_team_members" TO "service_role";



GRANT ALL ON TABLE "public"."sustainability_audits" TO "anon";
GRANT ALL ON TABLE "public"."sustainability_audits" TO "authenticated";
GRANT ALL ON TABLE "public"."sustainability_audits" TO "service_role";



GRANT ALL ON TABLE "public"."sustainability_certifications" TO "anon";
GRANT ALL ON TABLE "public"."sustainability_certifications" TO "authenticated";
GRANT ALL ON TABLE "public"."sustainability_certifications" TO "service_role";



GRANT ALL ON TABLE "public"."sustainability_initiative_categories" TO "anon";
GRANT ALL ON TABLE "public"."sustainability_initiative_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."sustainability_initiative_categories" TO "service_role";



GRANT ALL ON TABLE "public"."sustainability_initiatives" TO "anon";
GRANT ALL ON TABLE "public"."sustainability_initiatives" TO "authenticated";
GRANT ALL ON TABLE "public"."sustainability_initiatives" TO "service_role";



GRANT ALL ON TABLE "public"."sustainability_metric_types" TO "anon";
GRANT ALL ON TABLE "public"."sustainability_metric_types" TO "authenticated";
GRANT ALL ON TABLE "public"."sustainability_metric_types" TO "service_role";



GRANT ALL ON TABLE "public"."sustainability_metrics" TO "anon";
GRANT ALL ON TABLE "public"."sustainability_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."sustainability_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_modules" TO "anon";
GRANT ALL ON TABLE "public"."tenant_modules" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_modules" TO "service_role";



GRANT ALL ON TABLE "public"."user_group_members" TO "anon";
GRANT ALL ON TABLE "public"."user_group_members" TO "authenticated";
GRANT ALL ON TABLE "public"."user_group_members" TO "service_role";



GRANT ALL ON TABLE "public"."v_account_ledger" TO "anon";
GRANT ALL ON TABLE "public"."v_account_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."v_account_ledger" TO "service_role";



GRANT ALL ON TABLE "public"."v_advance_payments" TO "anon";
GRANT ALL ON TABLE "public"."v_advance_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."v_advance_payments" TO "service_role";



GRANT ALL ON TABLE "public"."v_cost_transactions_inquiry" TO "anon";
GRANT ALL ON TABLE "public"."v_cost_transactions_inquiry" TO "authenticated";
GRANT ALL ON TABLE "public"."v_cost_transactions_inquiry" TO "service_role";



GRANT ALL ON TABLE "public"."v_durations" TO "anon";
GRANT ALL ON TABLE "public"."v_durations" TO "authenticated";
GRANT ALL ON TABLE "public"."v_durations" TO "service_role";



GRANT ALL ON TABLE "public"."v_payment_plan" TO "anon";
GRANT ALL ON TABLE "public"."v_payment_plan" TO "authenticated";
GRANT ALL ON TABLE "public"."v_payment_plan" TO "service_role";



GRANT ALL ON TABLE "public"."workflow_stages" TO "anon";
GRANT ALL ON TABLE "public"."workflow_stages" TO "authenticated";
GRANT ALL ON TABLE "public"."workflow_stages" TO "service_role";



GRANT ALL ON TABLE "public"."v_request_tracking" TO "anon";
GRANT ALL ON TABLE "public"."v_request_tracking" TO "authenticated";
GRANT ALL ON TABLE "public"."v_request_tracking" TO "service_role";



GRANT ALL ON TABLE "public"."v_trial_balance" TO "anon";
GRANT ALL ON TABLE "public"."v_trial_balance" TO "authenticated";
GRANT ALL ON TABLE "public"."v_trial_balance" TO "service_role";



GRANT ALL ON TABLE "public"."v_vat_report" TO "anon";
GRANT ALL ON TABLE "public"."v_vat_report" TO "authenticated";
GRANT ALL ON TABLE "public"."v_vat_report" TO "service_role";



GRANT ALL ON TABLE "public"."v_vendor_evaluation" TO "anon";
GRANT ALL ON TABLE "public"."v_vendor_evaluation" TO "authenticated";
GRANT ALL ON TABLE "public"."v_vendor_evaluation" TO "service_role";



GRANT ALL ON TABLE "public"."warehouses" TO "anon";
GRANT ALL ON TABLE "public"."warehouses" TO "authenticated";
GRANT ALL ON TABLE "public"."warehouses" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";

SET search_path TO "public";





