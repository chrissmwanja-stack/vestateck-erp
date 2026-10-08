import { useEffect, useState } from 'react';
import { supabase } from './supabaseClient';

// Reads the platform_modules registry (D1, 20261008061315_platform_modules_registry).
// The registry is the single source of truth for valid module keys and their
// display names: tenant_modules, staff_roles and platform_module_activity_sources
// all reference it by foreign key, and invite-user validates against it.
//
// The table is readable by any signed-in user (platform_modules_select), has no
// tenant data in it, and changes only via migrations, so it is fetched once per
// page load and shared by every screen that needs a module list.

export interface PlatformModule {
  key: string;
  name: string;
  tier: 'core' | 'optional' | 'vertical';
  vertical: string | null;
  route_base: string | null;
  depends_on: string[];
  tenant_entitled: boolean;
  is_active: boolean;
  sort_order: number;
}

const COLUMNS = 'key, name, tier, vertical, route_base, depends_on, tenant_entitled, is_active, sort_order';

let cache: PlatformModule[] | null = null;
let inflight: Promise<PlatformModule[]> | null = null;

export async function loadModuleRegistry(): Promise<PlatformModule[]> {
  if (cache) return cache;
  if (!inflight) {
    inflight = (async () => {
      // platform_modules is not in the generated Database types yet (types were
      // last regenerated before the registry migration). Drop the cast once
      // packages/shared/src/database.types.ts is regenerated.
      const { data, error } = await supabase
        .from('platform_modules' as never)
        .select(COLUMNS)
        .eq('is_active', true)
        .order('sort_order', { ascending: true });
      if (error) throw new Error(error.message);
      const rows = (data ?? []) as unknown as PlatformModule[];
      cache = rows;
      return rows;
    })().finally(() => {
      inflight = null;
    });
  }
  return inflight;
}

/** Test helper: forget the cached registry. */
export function resetModuleRegistryCache(): void {
  cache = null;
  inflight = null;
}

export interface ModuleRegistryState {
  loading: boolean;
  error: string | null;
  /** Every active module, in registry order. */
  modules: PlatformModule[];
  /** Modules that can be granted to a tenant or a staff member (excludes e.g. finance). */
  entitledModules: PlatformModule[];
  /** Registry name for a key; falls back to the raw key for unknown keys. */
  labelFor: (key: string) => string;
}

export function useModuleRegistry(): ModuleRegistryState {
  const [modules, setModules] = useState<PlatformModule[]>(cache ?? []);
  const [loading, setLoading] = useState(cache === null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (cache) {
      setModules(cache);
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    loadModuleRegistry()
      .then((rows) => {
        if (cancelled) return;
        setModules(rows);
        setError(null);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : 'Failed to load modules');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const entitledModules = modules.filter((m) => m.tenant_entitled);
  const labelFor = (key: string) => modules.find((m) => m.key === key)?.name ?? key;

  return { loading, error, modules, entitledModules, labelFor };
}
