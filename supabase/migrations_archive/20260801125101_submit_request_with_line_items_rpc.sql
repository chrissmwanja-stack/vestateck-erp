CREATE OR REPLACE FUNCTION submit_request_with_line_items(
  p_item_description text,
  p_quantity integer,
  p_cost_center_id uuid,
  p_delivery_date date,
  p_subcontractor text,
  p_line_items jsonb
)
RETURNS uuid
LANGUAGE plpgsql
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
      quantity, unit_price, total, currency
    )
    VALUES (
      v_request_id,
      v_item->>'material_service',
      NULLIF(v_item->>'cost_code', ''),
      NULLIF(v_item->>'group_code', ''),
      NULLIF(v_item->>'place_of_use', ''),
      (v_item->>'quantity')::numeric,
      NULLIF(v_item->>'unit_price', '')::numeric,
      NULLIF(v_item->>'total', '')::numeric,
      COALESCE(NULLIF(v_item->>'currency', ''), 'UGX')
    );
  END LOOP;

  RETURN v_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION submit_request_with_line_items(text, integer, uuid, date, text, jsonb) TO authenticated;
