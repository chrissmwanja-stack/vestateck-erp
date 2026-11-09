-- Phase 1, step 4b of the Insurance Brokerage vertical work: register the
-- 'insurance' module in the platform_modules registry (decision D1).
--
-- Additive: one registry row, no schema change. tenant_modules, staff_roles and
-- platform_module_activity_sources reference the registry by FK, so after this
-- 'insurance' becomes a valid key everywhere, and save_industry_template() /
-- apply_template() can use it as a template module item.
--
-- tier = 'vertical', vertical = 'insurance' (same convention as the
-- construction modules: vertical = the industry template key).
-- tenant_entitled = true: it must be entitlable to a tenant to be usable.
-- depends_on is left empty: 'finance' is core and not entitled per tenant, and
-- the registry does not yet enforce depends_on.
insert into public.platform_modules
  (key, name, tier, vertical, route_base, depends_on, tenant_entitled, is_active, sort_order)
values
  ('insurance', 'Insurance Brokerage', 'vertical', 'insurance', '/insurance', '{}', true, true, 100)
on conflict (key) do nothing;
