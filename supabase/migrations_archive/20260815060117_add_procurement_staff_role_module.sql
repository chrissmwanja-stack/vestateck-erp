-- Extend staff_roles.module to allow 'procurement', mirroring the other
-- 7 module-scoped portals (hr, legal, bd, it, pmo, machine_operation,
-- sustainability). Procurement previously had no module-based gating at
-- all -- any authenticated tenant user could reach every procurement
-- screen. has_module_role() already works generically against
-- staff_roles.module, so no function changes are needed -- only the
-- CHECK constraint needs to widen.

ALTER TABLE public.staff_roles DROP CONSTRAINT staff_roles_module_check;

ALTER TABLE public.staff_roles ADD CONSTRAINT staff_roles_module_check
  CHECK (module = ANY (ARRAY[
    'hr'::text,
    'legal'::text,
    'bd'::text,
    'it'::text,
    'pmo'::text,
    'machine_operation'::text,
    'sustainability'::text,
    'procurement'::text
  ]));