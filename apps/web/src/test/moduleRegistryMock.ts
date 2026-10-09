import type { PlatformModule, ModuleRegistryState } from '../lib/useModuleRegistry';

// Mirrors the rows seeded by 20261008061315_platform_modules_registry.sql.
// Screens that call useModuleRegistry() mock the hook with this fixture so
// they render the same module list and registry names as production.
const row = (
  key: string,
  name: string,
  tier: PlatformModule['tier'],
  sort_order: number,
  extra: Partial<PlatformModule> = {},
): PlatformModule => ({
  key,
  name,
  tier,
  vertical: null,
  route_base: null,
  depends_on: [],
  tenant_entitled: true,
  is_active: true,
  sort_order,
  ...extra,
});

export const REGISTRY_FIXTURE: PlatformModule[] = [
  row('finance', 'Finance & GL', 'core', 10, { tenant_entitled: false }),
  row('hr', 'Human Resources', 'core', 20),
  row('procurement', 'Procurement', 'optional', 30),
  row('legal', 'Law & Compliance', 'optional', 40),
  row('it', 'IT Support', 'optional', 50),
  row('bd', 'Business Development', 'optional', 60),
  row('pmo', 'Project Management', 'vertical', 70, { vertical: 'construction' }),
  row('machine_operation', 'Machine Operation', 'vertical', 80, { vertical: 'construction' }),
  row('sustainability', 'Sustainability', 'vertical', 90, { vertical: 'construction' }),
  row('insurance', 'Insurance Brokerage', 'vertical', 100, { vertical: 'insurance', route_base: '/insurance' }),
];

export function registryState(modules: PlatformModule[] = REGISTRY_FIXTURE): ModuleRegistryState {
  return {
    loading: false,
    error: null,
    modules,
    entitledModules: modules.filter((m) => m.tenant_entitled),
    labelFor: (key: string) => modules.find((m) => m.key === key)?.name ?? key,
  };
}
