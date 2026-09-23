// Pure helpers for the item-7 operator screens: industry templates,
// announcements, feature flags and the health page. No React/MUI so they
// can be unit-tested; the shapes mirror the RPCs in
// 20260923090000_templates_announcements_flags_health.sql.

import type { Json } from '@erp-platform/shared';

// ---------------------------------------------------------------------
// Industry templates
// ---------------------------------------------------------------------
export type TemplateItemKind = 'department' | 'module' | 'workflow_stage';

export interface StagePayload {
  approver_role: string;
  threshold_amount?: number | null;
  next_low?: number | null; // sort_order of the target stage
  next_high?: number | null;
  requires_offer_entry?: boolean;
  blocks_offer_submitter_approval?: boolean;
  is_finance_terminal_stage?: boolean;
  requires_offer_selection?: boolean;
}

export interface TemplateItem {
  kind: TemplateItemKind;
  sort_order: number;
  name: string;
  payload: Json;
}

export interface TemplateRow {
  key: string;
  name: string;
  description: string | null;
  is_active: boolean;
  is_default: boolean;
  sort_order: number;
  updated_at: string;
  department_count: number;
  module_count: number;
  stage_count: number;
  tenants_using: number;
  items: Json;
}

export interface StageDraft {
  sort_order: number;
  name: string;
  approver_role: string;
  threshold_amount: string; // form text; '' = none
  next_low: number | null;
  next_high: number | null;
  is_finance_terminal_stage: boolean;
  requires_offer_entry: boolean;
  requires_offer_selection: boolean;
  blocks_offer_submitter_approval: boolean;
}

export interface TemplateDraft {
  key: string;
  name: string;
  description: string;
  is_active: boolean;
  departments: string[];
  modules: string[];
  stages: StageDraft[];
}

export const TEMPLATE_MODULES: { value: string; label: string }[] = [
  { value: 'hr', label: 'HR' },
  { value: 'legal', label: 'Law & Compliance' },
  { value: 'bd', label: 'Business Development' },
  { value: 'it', label: 'IT Support' },
  { value: 'pmo', label: 'PMO' },
  { value: 'procurement', label: 'Purchasing Extras' },
  { value: 'machine_operation', label: 'Machine Operation' },
  { value: 'sustainability', label: 'Sustainability' },
];

export const TEMPLATE_KEY_RE = /^[a-z][a-z0-9_]{1,39}$/;

export function slugifyTemplateKey(name: string): string {
  const s = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .replace(/^[^a-z]+/, '')
    .slice(0, 40);
  return s.length >= 2 ? s : '';
}

function asItems(items: Json): TemplateItem[] {
  if (!Array.isArray(items)) return [];
  return (items as Array<Record<string, Json>>)
    .filter((i) => i && typeof i === 'object' && typeof i.kind === 'string' && typeof i.name === 'string')
    .map((i) => ({
      kind: i.kind as TemplateItemKind,
      sort_order: typeof i.sort_order === 'number' ? i.sort_order : 0,
      name: i.name as string,
      payload: (i.payload ?? {}) as Json,
    }));
}

export function emptyStage(sort_order: number): StageDraft {
  return {
    sort_order,
    name: '',
    approver_role: '',
    threshold_amount: '',
    next_low: null,
    next_high: null,
    is_finance_terminal_stage: false,
    requires_offer_entry: false,
    requires_offer_selection: false,
    blocks_offer_submitter_approval: false,
  };
}

export function emptyTemplateDraft(): TemplateDraft {
  return { key: '', name: '', description: '', is_active: true, departments: [], modules: [], stages: [] };
}

/** Server row -> editable draft. */
export function draftFromTemplate(row: TemplateRow): TemplateDraft {
  const items = asItems(row.items);
  const by = (kind: TemplateItemKind) => items.filter((i) => i.kind === kind).sort((a, b) => a.sort_order - b.sort_order);
  return {
    key: row.key,
    name: row.name,
    description: row.description ?? '',
    is_active: row.is_active,
    departments: by('department').map((i) => i.name),
    modules: by('module').map((i) => i.name),
    stages: by('workflow_stage').map((i) => {
      const p = (i.payload ?? {}) as Partial<StagePayload>;
      return {
        sort_order: i.sort_order,
        name: i.name,
        approver_role: p.approver_role ?? '',
        threshold_amount: p.threshold_amount == null ? '' : String(p.threshold_amount),
        next_low: p.next_low ?? null,
        next_high: p.next_high ?? null,
        is_finance_terminal_stage: !!p.is_finance_terminal_stage,
        requires_offer_entry: !!p.requires_offer_entry,
        requires_offer_selection: !!p.requires_offer_selection,
        blocks_offer_submitter_approval: !!p.blocks_offer_submitter_approval,
      };
    }),
  };
}

/** Draft -> the p_items array save_industry_template() expects. */
export function itemsFromDraft(d: TemplateDraft): TemplateItem[] {
  const out: TemplateItem[] = [];
  d.departments.map((s) => s.trim()).filter(Boolean).forEach((name, i) => out.push({ kind: 'department', sort_order: i + 1, name, payload: {} }));
  d.modules.forEach((name, i) => out.push({ kind: 'module', sort_order: i + 1, name, payload: {} }));
  d.stages.forEach((s, i) => {
    const payload: Record<string, Json> = { approver_role: s.approver_role.trim() };
    const th = s.threshold_amount.trim();
    if (th !== '' && !Number.isNaN(Number(th))) payload.threshold_amount = Number(th);
    if (s.next_low != null) payload.next_low = s.next_low;
    if (s.next_high != null) payload.next_high = s.next_high;
    if (s.is_finance_terminal_stage) payload.is_finance_terminal_stage = true;
    if (s.requires_offer_entry) payload.requires_offer_entry = true;
    if (s.requires_offer_selection) payload.requires_offer_selection = true;
    if (s.blocks_offer_submitter_approval) payload.blocks_offer_submitter_approval = true;
    out.push({ kind: 'workflow_stage', sort_order: i + 1, name: s.name.trim(), payload });
  });
  return out;
}

/** Client-side mirror of the server checks so the dialog can explain before submitting. */
export function validateTemplateDraft(d: TemplateDraft): string[] {
  const errors: string[] = [];
  if (!TEMPLATE_KEY_RE.test(d.key)) errors.push('Key must be 2–40 chars: lowercase letters, digits or underscores, starting with a letter.');
  if (!d.name.trim()) errors.push('Give the template a name.');
  const depts = d.departments.map((s) => s.trim()).filter(Boolean);
  if (depts.length === 0) errors.push('Add at least one department.');
  if (new Set(depts.map((s) => s.toLowerCase())).size !== depts.length) errors.push('Department names must be unique.');
  if (d.stages.length === 0) errors.push('Add at least one approval stage (requests cannot be submitted without one).');
  const orders = new Set(d.stages.map((_, i) => i + 1));
  d.stages.forEach((s, i) => {
    const n = i + 1;
    if (!s.name.trim()) errors.push(`Stage ${n} needs a name.`);
    if (!s.approver_role.trim()) errors.push(`Stage ${n} (${s.name || 'unnamed'}) needs an approver role.`);
    if (s.threshold_amount.trim() !== '' && (Number.isNaN(Number(s.threshold_amount)) || Number(s.threshold_amount) < 0)) {
      errors.push(`Stage ${n} threshold must be a non-negative number.`);
    }
    if (s.threshold_amount.trim() !== '' && s.next_high == null) errors.push(`Stage ${n} has a threshold but no "above threshold" next stage.`);
    if (s.next_low != null && (!orders.has(s.next_low) || s.next_low === n)) errors.push(`Stage ${n} routes to a stage that does not exist.`);
    if (s.next_high != null && (!orders.has(s.next_high) || s.next_high === n)) errors.push(`Stage ${n} routes (above threshold) to a stage that does not exist.`);
  });
  return errors;
}

/** "Stage 4 → Finance (≤ 5,000,000) / Project Manager (>)" style one-liners for the list. */
export function describeStage(s: StageDraft, all: StageDraft[]): string {
  const nameOf = (o: number | null) => (o == null ? 'end' : all[o - 1]?.name || `stage ${o}`);
  if (s.threshold_amount.trim() !== '' && s.next_high != null) {
    return `${s.name}: ≤ ${Number(s.threshold_amount).toLocaleString()} → ${nameOf(s.next_low)}, above → ${nameOf(s.next_high)}`;
  }
  return `${s.name} → ${nameOf(s.next_low)}`;
}

/** Re-number after a stage is removed/moved so next_* keep pointing at the same stage. */
export function reindexStages(stages: StageDraft[], removedIndex?: number): StageDraft[] {
  // map old order -> new order
  const map = new Map<number, number>();
  let n = 0;
  stages.forEach((s) => {
    n += 1;
    map.set(s.sort_order, n);
  });
  return stages.map((s, i) => ({
    ...s,
    sort_order: i + 1,
    next_low: s.next_low == null ? null : removedIndex != null && s.next_low === removedIndex + 1 ? null : (map.get(s.next_low) ?? null),
    next_high: s.next_high == null ? null : removedIndex != null && s.next_high === removedIndex + 1 ? null : (map.get(s.next_high) ?? null),
  }));
}

// ---------------------------------------------------------------------
// Announcements
// ---------------------------------------------------------------------
export type AnnouncementSeverity = 'info' | 'warning' | 'critical';
export type AnnouncementState = 'scheduled' | 'live' | 'ended' | 'disabled';

export interface AnnouncementRow {
  id: string;
  title: string;
  body: string;
  severity: string;
  tenant_id: string | null;
  tenant_name: string | null;
  starts_at: string;
  ends_at: string | null;
  dismissible: boolean;
  link_url: string | null;
  link_label: string | null;
  is_active: boolean;
  state: string;
  dismissals: number;
  created_at: string;
  created_by_email: string | null;
}

export interface AnnouncementDraft {
  id: string | null;
  title: string;
  body: string;
  severity: AnnouncementSeverity;
  tenant_id: string | null;
  starts_at: string; // datetime-local value ('' = now)
  ends_at: string; // '' = open-ended
  dismissible: boolean;
  link_url: string;
  link_label: string;
  is_active: boolean;
}

export function emptyAnnouncementDraft(): AnnouncementDraft {
  return { id: null, title: '', body: '', severity: 'info', tenant_id: null, starts_at: '', ends_at: '', dismissible: true, link_url: '', link_label: '', is_active: true };
}

/** ISO -> value for <input type="datetime-local"> in the browser's local zone. */
export function toLocalInput(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function fromLocalInput(v: string): string | null {
  if (!v) return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export function announcementDraftFrom(row: AnnouncementRow): AnnouncementDraft {
  return {
    id: row.id,
    title: row.title,
    body: row.body,
    severity: (['info', 'warning', 'critical'].includes(row.severity) ? row.severity : 'info') as AnnouncementSeverity,
    tenant_id: row.tenant_id,
    starts_at: toLocalInput(row.starts_at),
    ends_at: toLocalInput(row.ends_at),
    dismissible: row.dismissible,
    link_url: row.link_url ?? '',
    link_label: row.link_label ?? '',
    is_active: row.is_active,
  };
}

export function validateAnnouncement(d: AnnouncementDraft): string[] {
  const errors: string[] = [];
  if (!d.title.trim()) errors.push('Title is required.');
  if (!d.body.trim()) errors.push('Body is required.');
  const s = fromLocalInput(d.starts_at);
  const e = fromLocalInput(d.ends_at);
  if (d.starts_at && !s) errors.push('Start time is not a valid date.');
  if (d.ends_at && !e) errors.push('End time is not a valid date.');
  if (s && e && e <= s) errors.push('End must be after start.');
  if (!s && e && new Date(e).getTime() <= Date.now()) errors.push('End must be in the future.');
  if (d.link_url.trim() && !/^(https?:\/\/|\/)/i.test(d.link_url.trim())) errors.push('Link must start with https:// or /.');
  if (d.link_url.trim() && !d.link_label.trim()) errors.push('Give the link a label.');
  return errors;
}

export const ANNOUNCEMENT_STATE_LABEL: Record<AnnouncementState, string> = {
  scheduled: 'Scheduled',
  live: 'Live',
  ended: 'Ended',
  disabled: 'Disabled',
};

/** Live first, then scheduled, ended, disabled; newest start first within each. */
export function sortAnnouncements(rows: AnnouncementRow[]): AnnouncementRow[] {
  const rank: Record<string, number> = { live: 0, scheduled: 1, ended: 2, disabled: 3 };
  return [...rows].sort((a, b) => (rank[a.state] ?? 9) - (rank[b.state] ?? 9) || b.starts_at.localeCompare(a.starts_at));
}

// ---------------------------------------------------------------------
// Feature flags
// ---------------------------------------------------------------------
export const FLAG_KEY_RE = /^[a-z][a-z0-9_.]{1,63}$/;

export interface FlagRow {
  key: string;
  description: string | null;
  default_enabled: boolean;
  updated_at: string;
  tenants_on: number;
  tenants_off: number;
  overrides: Json;
}

export interface FlagOverride {
  tenant_id: string;
  tenant_name: string;
  enabled: boolean;
  note: string | null;
  updated_at: string;
}

export function overridesOf(row: FlagRow): FlagOverride[] {
  if (!Array.isArray(row.overrides)) return [];
  return (row.overrides as Array<Record<string, Json>>).map((o) => ({
    tenant_id: String(o.tenant_id ?? ''),
    tenant_name: String(o.tenant_name ?? ''),
    enabled: !!o.enabled,
    note: (o.note as string | null) ?? null,
    updated_at: String(o.updated_at ?? ''),
  }));
}

export interface TenantFlagRow {
  key: string;
  description: string | null;
  default_enabled: boolean;
  override: boolean | null;
  effective: boolean;
  note: string | null;
  updated_at: string | null;
}

export type FlagChoice = 'default' | 'on' | 'off';

export function choiceOf(row: Pick<TenantFlagRow, 'override'>): FlagChoice {
  return row.override == null ? 'default' : row.override ? 'on' : 'off';
}

export function enabledFromChoice(c: FlagChoice): boolean | null {
  return c === 'default' ? null : c === 'on';
}

/** "on (default)" / "on (override)" / "off (override)" for chips. */
export function describeFlag(row: TenantFlagRow): string {
  return `${row.effective ? 'on' : 'off'} (${row.override == null ? 'default' : 'override'})`;
}

// ---------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------
export interface HealthJob {
  job: string;
  last_run_at: string | null;
  last_status: 'ok' | 'error' | string;
  last_affected: number | null;
  last_detail: string | null;
  runs_7d: number;
  errors_7d: number;
  tenants_7d: number;
}

export interface HealthCronJob {
  jobname: string;
  schedule: string;
  active: boolean;
  last_status: string | null;
  last_start: string | null;
  last_end: string | null;
  last_message: string | null;
}

export interface HealthTenantCount {
  tenant_id: string;
  tenant_name: string;
  count: number;
  oldest_days: number;
}

export interface HealthBucket {
  bucket: string;
  objects: number;
  bytes: number;
}

export interface PlatformHealth {
  checked_at: string;
  database: { version: string; size_bytes: number; connections: number; max_connections: number };
  migrations: { latest: string | null; count: number };
  cron: { installed: boolean; jobs: HealthCronJob[] };
  jobs: HealthJob[];
  digest: { last_generated_at: string | null; failed_7d: number; pending: number };
  stuck_approvals: HealthTenantCount[];
  stale_invites: HealthTenantCount[];
  read_only_tenants: number;
  open_impersonations: number;
  storage: { available: boolean; buckets: HealthBucket[] };
  announcements_live: number;
  feature_flags: number;
}

export const JOB_LABEL: Record<string, string> = {
  machine_maintenance_overdue_sweep: 'Maintenance overdue sweep',
  sustainability_cert_expiry_sweep: 'Certification expiry sweep',
  operator_digest: 'Operator digest',
};

// What "healthy" means per job. The two sweeps are "cronless": they run
// when a customer opens the relevant page, so their cadence follows
// usage and a quiet week is not an incident. The digest is scheduled
// daily, so >36h without a run is.
export const JOB_EXPECTED_HOURS: Record<string, number | null> = {
  machine_maintenance_overdue_sweep: null,
  sustainability_cert_expiry_sweep: null,
  operator_digest: 36,
};

export type HealthLevel = 'ok' | 'warn' | 'error' | 'unknown';

export function jobLevel(j: HealthJob, now: Date = new Date()): HealthLevel {
  if (j.last_status === 'error' || j.errors_7d > 0) return 'error';
  if (!j.last_run_at) return 'unknown';
  const expected = JOB_EXPECTED_HOURS[j.job];
  if (expected == null) return 'ok';
  const ageH = (now.getTime() - new Date(j.last_run_at).getTime()) / 36e5;
  return ageH > expected ? 'warn' : 'ok';
}

export function cronLevel(c: HealthCronJob): HealthLevel {
  if (!c.active) return 'warn';
  if (c.last_status == null) return 'unknown';
  return c.last_status === 'succeeded' ? 'ok' : 'error';
}

/** Roll-up for the page header: worst of everything we can judge. */
export function overallLevel(h: PlatformHealth, now: Date = new Date()): HealthLevel {
  const levels: HealthLevel[] = [];
  h.jobs.forEach((j) => levels.push(jobLevel(j, now)));
  h.cron.jobs.forEach((c) => levels.push(cronLevel(c)));
  if (h.digest.failed_7d > 0) levels.push('error');
  if (h.stuck_approvals.length > 0) levels.push('warn');
  if (h.database.max_connections > 0 && h.database.connections / h.database.max_connections > 0.8) levels.push('warn');
  if (!h.cron.installed) levels.push('warn');
  if (levels.includes('error')) return 'error';
  if (levels.includes('warn')) return 'warn';
  return levels.length ? 'ok' : 'unknown';
}

export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '—';
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v < 10 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

export function hoursAgo(iso: string | null, now: Date = new Date()): string {
  if (!iso) return 'never';
  const ms = now.getTime() - new Date(iso).getTime();
  if (ms < 60e3) return 'just now';
  if (ms < 36e5) return `${Math.round(ms / 60e3)} min ago`;
  if (ms < 48 * 36e5) return `${Math.round(ms / 36e5)} h ago`;
  return `${Math.round(ms / 864e5)} d ago`;
}

/** Defensive parse of the jsonb blob; missing arrays become empty so the page never crashes on an older server. */
export function normaliseHealth(raw: Json): PlatformHealth {
  const r = (raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}) as Record<string, Json>;
  const obj = (v: Json): Record<string, Json> => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, Json>) : {});
  const arr = <T,>(v: Json): T[] => (Array.isArray(v) ? (v as unknown as T[]) : []);
  const num = (v: Json, d = 0) => (typeof v === 'number' ? v : Number(v ?? d) || d);
  const db = obj(r.database);
  const mig = obj(r.migrations);
  const cron = obj(r.cron);
  const digest = obj(r.digest);
  const storage = obj(r.storage);
  return {
    checked_at: String(r.checked_at ?? new Date().toISOString()),
    database: {
      version: String(db.version ?? '?'),
      size_bytes: num(db.size_bytes),
      connections: num(db.connections),
      max_connections: num(db.max_connections),
    },
    migrations: { latest: (mig.latest as string | null) ?? null, count: num(mig.count) },
    cron: { installed: !!cron.installed, jobs: arr<HealthCronJob>(cron.jobs) },
    jobs: arr<HealthJob>(r.jobs),
    digest: { last_generated_at: (digest.last_generated_at as string | null) ?? null, failed_7d: num(digest.failed_7d), pending: num(digest.pending) },
    stuck_approvals: arr<HealthTenantCount>(r.stuck_approvals),
    stale_invites: arr<HealthTenantCount>(r.stale_invites),
    read_only_tenants: num(r.read_only_tenants),
    open_impersonations: num(r.open_impersonations),
    storage: { available: !!storage.available, buckets: arr<HealthBucket>(storage.buckets) },
    announcements_live: num(r.announcements_live),
    feature_flags: num(r.feature_flags),
  };
}
