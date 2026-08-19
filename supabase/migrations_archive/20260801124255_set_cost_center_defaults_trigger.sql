CREATE OR REPLACE FUNCTION set_cost_center_defaults()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.tenant_id := get_my_tenant_id();

  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'could not determine tenant_id for current user';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_set_cost_center_defaults
  BEFORE INSERT ON cost_centers
  FOR EACH ROW
  EXECUTE FUNCTION set_cost_center_defaults();
