// Pure helpers for the Overview's health section (onboarding funnel,
// stalled companies, quiet companies, module usage) and the matching
// bits on Company Detail. No React/MUI so they can be unit-tested; the
// shapes mirror the jsonb keys added to get_platform_dashboard_stats()
// and get_company_analytics() in 20260922220000.

export type StageKey =
  | 'created'
  | 'admin_invited'
  | 'admin_joined'
  | 'modules_enabled'
  | 'team_invited'
  | 'first_activity'
  | 'live';

export const STAGE_ORDER: StageKey[] = [
  'created',
  'admin_invited',
  'admin_joined',
  'modules_enabled',
  'team_invited',
  'first_activity',
  'live',
];

export const STAGE_LABELS: Record<StageKey, string> = {
  created: 'Created',
  admin_invited: 'Admin invited',
  admin_joined: 'Admin joined',
  modules_enabled: 'Modules on',
  team_invited: 'Team invited',
  first_activity: 'Used, not live',
  live: 'Live',
};

// Short, operator-facing meaning of each stage for tooltips.
export const STAGE_HINTS: Record<StageKey, string> = {
  created: 'Company exists; nobody has been invited yet.',
  admin_invited: 'A company-admin invitation is out (or an account exists) but no admin has joined.',
  admin_joined: 'An admin has an account; no modules are switched on yet.',
  modules_enabled: 'Modules are on; nobody else has been invited.',
  team_invited: 'Team invited; nothing has been created in any module yet.',
  first_activity: 'Has been used, but is not live: still pending/suspended, or quiet for 30+ days.',
  live: 'Active, with activity in the last 30 days.',
};

export interface FunnelRow {
  stage: number;
  stage_key: StageKey;
  count: number;
}

export interface StalledRow {
  id: string;
  name: string;
  status: string;
  stage: number;
  stage_key: StageKey;
  next_step: string | null;
  days_in_stage: number;
  created_at: string;
  contact_email: string | null;
}

export interface QuietRow {
  id: string;
  name: string;
  plan: string;
  subscription_status: string;
  member_count: number;
  last_activity_at: string | null;
  days_quiet: number;
  contact_email: string | null;
}

export interface ModuleUsageRow {
  module: string;
  tenants_enabled: number;
  tenants_active_30d: number;
  events_30d: number;
  events_prev_30d: number;
}

export interface TrialRow {
  id: string;
  name: string;
  trial_ends_at: string;
  days_left: number;
  stage_key: StageKey;
  member_count: number;
  contact_email: string | null;
}

// Per-company shape from get_company_analytics().module_usage
export interface CompanyModuleUsage {
  module: string;
  enabled: boolean;
  events_30d: number;
  events_prev_30d: number;
  first_event_at: string | null;
  last_event_at: string | null;
}

export const MODULE_LABEL: Record<string, string> = {
  procurement: 'Purchasing+',
  finance: 'Finance',
  hr: 'HR',
  legal: 'Law & Compliance',
  bd: 'Business Dev',
  it: 'IT Support',
  pmo: 'PMO',
  machine_operation: 'Machine Ops',
  sustainability: 'Sustainability',
};

// Fill any stage the server did not return (older RPC) with 0 and keep
// canonical order, so the UI never renders a partial funnel.
export function normaliseFunnel(rows: FunnelRow[] | null | undefined): FunnelRow[] {
  const byKey = new Map((rows ?? []).map((r) => [r.stage_key, r]));
  return STAGE_ORDER.map((k, i) => ({ stage: i, stage_key: k, count: byKey.get(k)?.count ?? 0 }));
}

// Companies in setup (stages 0-4) vs used-but-not-live vs live -- the
// three numbers worth a KPI card.
export function funnelSummary(rows: FunnelRow[]): { inSetup: number; notLive: number; live: number; total: number } {
  const f = normaliseFunnel(rows);
  const inSetup = f.filter((r) => r.stage <= 4).reduce((s, r) => s + r.count, 0);
  const notLive = f.find((r) => r.stage_key === 'first_activity')?.count ?? 0;
  const live = f.find((r) => r.stage_key === 'live')?.count ?? 0;
  return { inSetup, notLive, live, total: inSetup + notLive + live };
}

export type Trend = 'up' | 'down' | 'flat' | 'new' | 'none';

// Compare this window with the previous one. Small absolute numbers are
// noisy, so anything under 5 events either side reads as flat unless it
// went from zero to something ("new") or something to zero ("down").
export function trendOf(now: number, prev: number): Trend {
  if (now === 0 && prev === 0) return 'none';
  if (prev === 0) return 'new';
  if (now === 0) return 'down';
  if (now < 5 && prev < 5) return 'flat';
  const ratio = now / prev;
  if (ratio >= 1.2) return 'up';
  if (ratio <= 0.8) return 'down';
  return 'flat';
}

export function trendLabel(now: number, prev: number): string {
  switch (trendOf(now, prev)) {
    case 'new':
      return 'new this month';
    case 'none':
      return 'no activity';
    case 'down':
      return prev > 0 ? `↓ ${Math.round((1 - now / prev) * 100)}% vs previous 30d` : '↓';
    case 'up':
      return `↑ ${Math.round((now / prev - 1) * 100)}% vs previous 30d`;
    default:
      return 'steady';
  }
}

// "Enabled but unused" is the sales-and-support signal: paid for, not
// adopted. Returns modules where at least one company has it on but
// fewer than half of those companies touched it in 30 days.
export function underusedModules(rows: ModuleUsageRow[]): ModuleUsageRow[] {
  return rows.filter((r) => r.tenants_enabled > 0 && r.tenants_active_30d * 2 < r.tenants_enabled);
}

// Sort helpers for the stalled list: longest-stuck first, then earliest stage.
export function sortStalled(rows: StalledRow[]): StalledRow[] {
  return [...rows].sort((a, b) => b.days_in_stage - a.days_in_stage || a.stage - b.stage || a.name.localeCompare(b.name));
}

// Per-company: split modules into on+used / on+unused / off+used(!) / off.
export function classifyCompanyModules(rows: CompanyModuleUsage[]): {
  used: CompanyModuleUsage[];
  enabledUnused: CompanyModuleUsage[];
  usedButOff: CompanyModuleUsage[];
  off: CompanyModuleUsage[];
} {
  const used: CompanyModuleUsage[] = [];
  const enabledUnused: CompanyModuleUsage[] = [];
  const usedButOff: CompanyModuleUsage[] = [];
  const off: CompanyModuleUsage[] = [];
  for (const r of rows) {
    const touched = r.events_30d > 0 || r.events_prev_30d > 0 || !!r.last_event_at;
    if (r.enabled && touched) used.push(r);
    else if (r.enabled) enabledUnused.push(r);
    else if (touched) usedButOff.push(r);
    else off.push(r);
  }
  return { used, enabledUnused, usedButOff, off };
}
