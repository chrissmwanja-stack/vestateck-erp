-- Migration: New Material Card module (reuses request/approval patterns)
-- Minimal: material_catalog (optional reference) + material_requests (new request type)

-- Material catalog (optional reference table for standard materials)
CREATE TABLE IF NOT EXISTS public.material_catalog (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  name text NOT NULL,
  code text,
  unit text DEFAULT 'Unit',
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.material_catalog ENABLE ROW LEVEL SECURITY;

-- Material request (similar to requests but for material card workflow)
CREATE TABLE IF NOT EXISTS public.material_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  requester_id uuid NOT NULL REFERENCES public.app_users(id) ON DELETE SET NULL,
  department_id uuid REFERENCES public.departments(id) ON DELETE SET NULL,
  cost_center_id uuid REFERENCES public.cost_centers(id) ON DELETE SET NULL,
  current_stage_id uuid REFERENCES public.workflow_stages(id),
  item_description text NOT NULL,
  quantity int NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','rejected','closed')),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.material_requests ENABLE ROW LEVEL SECURITY;

-- Trigger: set default stage and status on insert (same pattern as requests)
CREATE OR REPLACE FUNCTION set_material_request_defaults()
RETURNS trigger AS $$
BEGIN
  NEW.status := 'open';
  IF NEW.current_stage_id IS NULL THEN
    SELECT id INTO NEW.current_stage_id FROM workflow_stages WHERE tenant_id = NEW.tenant_id ORDER BY sequence_order ASC LIMIT 1;
  END IF;
  IF NEW.department_id IS NULL THEN
    SELECT department_id INTO NEW.department_id FROM app_users WHERE id = NEW.requester_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS material_request_defaults ON public.material_requests;
CREATE TRIGGER material_request_defaults
BEFORE INSERT ON public.material_requests
FOR EACH ROW EXECUTE FUNCTION set_material_request_defaults();
