// Pure helpers for the global user directory (/admin/users) and the
// platform team screen (/admin/team). Kept free of React/MUI so they can
// be unit-tested directly; the screens import from here.

import type { Json } from '@erp-platform/shared';

export interface DirectoryUser {
  user_id: string;
  name: string;
  email: string;
  role_title: string | null;
  tenant_id: string;
  tenant_name: string;
  tenant_status: string;
  is_platform_admin: boolean;
  is_company_admin: boolean;
  modules: Json;
  finance_role: string | null;
  mfa_enrolled: boolean;
  last_sign_in_at: string | null;
  created_at: string;
  total_count: number;
}

export interface PlatformAdminRow {
  user_id: string;
  name: string;
  email: string;
  tenant_id: string;
  tenant_name: string;
  mfa_enrolled: boolean;
  last_sign_in_at: string | null;
  created_at: string;
  granted_at: string | null;
  granted_by_email: string | null;
  is_self: boolean;
}

export type UserKind = '' | 'platform_admin' | 'company_admin' | 'finance' | 'member';

export const USER_KIND_LABELS: Record<Exclude<UserKind, ''>, string> = {
  platform_admin: 'Platform admins',
  company_admin: 'Company admins',
  finance: 'Finance team',
  member: 'Members',
};

export const MODULE_LABELS: Record<string, string> = {
  hr: 'HR',
  legal: 'Legal',
  bd: 'Business Dev',
  it: 'IT',
  pmo: 'PMO',
  machine_operation: 'Machines',
  sustainability: 'Sustainability',
  procurement: 'Procurement',
};

export const MODULE_KEYS = Object.keys(MODULE_LABELS);

export interface ModuleRole {
  module: string;
  role: string;
}

// The RPC returns modules as jsonb; be defensive about shape.
export function parseModules(value: Json | null | undefined): ModuleRole[] {
  if (!Array.isArray(value)) return [];
  const out: ModuleRole[] = [];
  for (const item of value) {
    if (item && typeof item === 'object' && !Array.isArray(item)) {
      const m = (item as Record<string, Json | undefined>).module;
      const r = (item as Record<string, Json | undefined>).role;
      if (typeof m === 'string' && typeof r === 'string') out.push({ module: m, role: r });
    }
  }
  return out.sort((a, b) => a.module.localeCompare(b.module));
}

// One-line access summary: "Company admin · HR admin, Procurement member · Finance"
export function summariseAccess(u: Pick<DirectoryUser, 'is_platform_admin' | 'is_company_admin' | 'modules' | 'finance_role'>): string {
  const parts: string[] = [];
  if (u.is_platform_admin) parts.push('Platform admin');
  if (u.is_company_admin) parts.push('Company admin');
  const mods = parseModules(u.modules).map((m) => `${MODULE_LABELS[m.module] ?? m.module} ${m.role}`);
  if (mods.length) parts.push(mods.join(', '));
  if (u.finance_role) parts.push(u.finance_role === 'finance' ? 'Finance' : 'Cost control');
  return parts.length ? parts.join(' · ') : 'No access granted';
}

export function daysSince(iso: string | null | undefined, now: number = Date.now()): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  return Math.floor((now - t) / 86_400_000);
}

// "never" / "today" / "3 days ago" / "45 days ago"
export function lastSeenLabel(iso: string | null | undefined, now: number = Date.now()): string {
  const d = daysSince(iso, now);
  if (d === null) return 'never';
  if (d <= 0) return 'today';
  if (d === 1) return 'yesterday';
  return `${d} days ago`;
}

export function usersToCsv(rows: DirectoryUser[]): string {
  const header = [
    'name', 'email', 'company', 'company_status', 'role_title', 'platform_admin', 'company_admin',
    'modules', 'finance_role', 'mfa_enrolled', 'last_sign_in_at', 'created_at', 'user_id', 'tenant_id',
  ];
  const esc = (v: unknown) => {
    const s = v === null || v === undefined ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = rows.map((r) =>
    [
      r.name, r.email, r.tenant_name, r.tenant_status, r.role_title, r.is_platform_admin, r.is_company_admin,
      parseModules(r.modules).map((m) => `${m.module}:${m.role}`).join(' '),
      r.finance_role, r.mfa_enrolled, r.last_sign_in_at, r.created_at, r.user_id, r.tenant_id,
    ].map(esc).join(','),
  );
  return [header.join(','), ...lines].join('\n');
}

// Platform-team risk flags surfaced on /admin/team.
export function teamWarnings(rows: PlatformAdminRow[], now: number = Date.now()): string[] {
  const out: string[] = [];
  const noMfa = rows.filter((r) => !r.mfa_enrolled);
  if (noMfa.length) {
    out.push(
      `${noMfa.length === 1 ? '1 platform admin has' : `${noMfa.length} platform admins have`} no authenticator enrolled: ${noMfa.map((r) => r.email).join(', ')}. Until they enrol, a password alone reaches this console.`,
    );
  }
  const stale = rows.filter((r) => {
    const d = daysSince(r.last_sign_in_at, now);
    return d === null || d >= 60;
  });
  if (stale.length && rows.length > 1) {
    out.push(
      `${stale.map((r) => r.email).join(', ')} ${stale.length === 1 ? 'has' : 'have'} not signed in for 60+ days. Consider removing access that is no longer used.`,
    );
  }
  if (rows.length === 1) {
    out.push('Only one platform admin exists. If that account is lost, nobody can operate the console — add a second operator.');
  }
  return out;
}
