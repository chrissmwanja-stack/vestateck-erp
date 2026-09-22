// Pure helpers behind the Companies list (search / filter / sort / CSV).
// Kept out of CompaniesConsole.tsx so they can be unit-tested without
// rendering the screen, and so nothing about the list's semantics is
// buried inside a 900-line component.

export interface Tenant {
  id: string;
  name: string;
  status: 'pending' | 'active' | 'suspended';
  created_at: string;
  // Populated from get_companies_overview() (platform-admin-gated RPC).
  // Optional so the type still fits results from a plain `tenants`
  // select if that ever needs to be used as a fallback.
  member_count?: number;
  module_count?: number;
  request_count_30d?: number;
  pending_request_count?: number;
  plan?: string;
  subscription_status?: string;
  seat_limit?: number | null;
  trial_ends_at?: string | null;
  read_only?: boolean;
  contact_email?: string | null;
  last_activity_at?: string | null;
}

export type SortKey = 'name' | 'status' | 'plan' | 'created_at' | 'last_activity_at' | 'member_count' | 'request_count_30d';

export interface CompanyFilters {
  q: string;
  status: '' | 'pending' | 'active' | 'suspended';
  plan: string;
  subscription: string;
  flag: '' | 'read_only' | 'trial_ending' | 'quiet' | 'seats_full';
}

export const EMPTY_FILTERS: CompanyFilters = { q: '', status: '', plan: '', subscription: '', flag: '' };

const DAY = 86_400_000;

export function applyCompanyFilters(rows: Tenant[], f: CompanyFilters, now: number = Date.now()): Tenant[] {
  const q = f.q.trim().toLowerCase();
  return rows.filter((r) => {
    if (q && !r.name.toLowerCase().includes(q) && !(r.contact_email ?? '').toLowerCase().includes(q)) return false;
    if (f.status && r.status !== f.status) return false;
    if (f.plan && r.plan !== f.plan) return false;
    if (f.subscription && r.subscription_status !== f.subscription) return false;
    switch (f.flag) {
      case 'read_only':
        return !!r.read_only;
      case 'trial_ending': {
        if (r.subscription_status !== 'trialing' || !r.trial_ends_at) return false;
        return new Date(r.trial_ends_at).getTime() - now <= 14 * DAY;
      }
      case 'quiet': {
        // No sign-in or request in 30 days (or never), and not pending.
        if (r.status === 'pending') return false;
        if (!r.last_activity_at) return true;
        return now - new Date(r.last_activity_at).getTime() > 30 * DAY;
      }
      case 'seats_full':
        return r.seat_limit != null && (r.member_count ?? 0) >= r.seat_limit;
      default:
        return true;
    }
  });
}

export function sortCompanies(rows: Tenant[], key: SortKey, dir: 'asc' | 'desc'): Tenant[] {
  const mul = dir === 'asc' ? 1 : -1;
  const val = (r: Tenant): string | number => {
    switch (key) {
      case 'created_at':
      case 'last_activity_at': {
        const v = r[key];
        return v ? new Date(v).getTime() : 0;
      }
      case 'member_count':
      case 'request_count_30d':
        return r[key] ?? 0;
      case 'plan':
        return r.plan ?? '';
      default:
        return String(r[key] ?? '').toLowerCase();
    }
  };
  return [...rows].sort((a, b) => {
    const av = val(a);
    const bv = val(b);
    if (av < bv) return -1 * mul;
    if (av > bv) return 1 * mul;
    return a.name.localeCompare(b.name);
  });
}

function csvEscape(v: unknown): string {
  if (v === null || v === undefined) return '';
  const s = String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function companiesToCsv(rows: Tenant[]): string {
  const header = [
    'name', 'status', 'plan', 'subscription_status', 'read_only', 'contact_email',
    'members', 'seat_limit', 'modules', 'requests_30d', 'pending_requests',
    'trial_ends_at', 'last_activity_at', 'created_at', 'tenant_id',
  ];
  const lines = rows.map((r) =>
    [
      r.name, r.status, r.plan, r.subscription_status, r.read_only ? 'yes' : 'no', r.contact_email,
      r.member_count, r.seat_limit, r.module_count, r.request_count_30d, r.pending_request_count,
      r.trial_ends_at, r.last_activity_at, r.created_at, r.id,
    ]
      .map(csvEscape)
      .join(',')
  );
  return [header.join(','), ...lines].join('\n');
}

export function downloadCsv(filename: string, text: string) {
  const blob = new Blob([text], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export const PLAN_LABELS: Record<string, string> = {
  trial: 'Trial', starter: 'Starter', standard: 'Standard', enterprise: 'Enterprise', internal: 'Internal',
};

