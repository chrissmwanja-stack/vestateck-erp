-- Fix: request_line_items.total was a plain writable numeric column that
-- submit_request_with_line_items() populated from client-supplied JSON
-- (v_item->>'total'), which the frontend never actually sent -- so every
-- line item ever created (100% of existing rows) has total = null.
-- Converting total to a generated column removes the possibility of this
-- happening again regardless of which insert path is used in future, and
-- backfills every existing row's total from its own quantity/unit_price
-- automatically (Postgres computes STORED generated columns for existing
-- rows at ADD COLUMN time).

ALTER TABLE request_line_items DROP COLUMN total;

ALTER TABLE request_line_items
  ADD COLUMN total numeric GENERATED ALWAYS AS (quantity * unit_price) STORED;

-- submit_request_with_line_items must no longer supply an explicit value
-- for total -- Postgres rejects explicit INSERTs into generated columns.
-- Removed from both the column list and the VALUES tuple; every other
-- field is unchanged from the original function.
CREATE OR REPLACE FUNCTION public.submit_request_with_line_items(
  p_item_description text,
  p_quantity integer,
  p_cost_center_id uuid,
  p_delivery_date date,
  p_subcontractor text,
  p_line_items jsonb
)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
$function$;
