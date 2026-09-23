// Pure helpers for the operator digest (item 6). The payload shape is
// produced by platform_operator_digest_payload() in
// 20260922240000_branding_and_operator_digest.sql.

export interface DigestCompanyRef {
  id: string;
  name: string;
  contact_email?: string | null;
}

export interface DigestPayload {
  period: { from: string; to: string };
  settings?: { pending_company_threshold_days: number };
  totals: { companies: number; active: number; pending: number; suspended: number; live: number; users: number };
  new_companies: (DigestCompanyRef & { plan: string; status: string; created_at: string })[];
  new_users: number;
  stalled: (DigestCompanyRef & { stage_key: string; next_step: string | null; days_in_stage: number })[];
  quiet: (DigestCompanyRef & { plan: string; days_quiet: number })[];
  trials_ending: (DigestCompanyRef & { trial_ends_at: string; days_left: number; stage_key: string })[];
  pending_over_threshold: (DigestCompanyRef & { stage_key: string; days_pending: number })[];
  open_impersonations: { admin_email: string | null; tenant_name: string; started_at: string; expires_at: string | null; reason: string | null }[];
  admins_without_mfa: string[];
  attention_count: number;
}

export interface DigestRow {
  id: string;
  period_start: string;
  period_end: string;
  generated_at: string;
  trigger: 'scheduled' | 'manual' | string;
  generated_by: string | null;
  attention_count: number;
  payload: DigestPayload;
  recipients: string[];
  delivery_status: 'pending' | 'sent' | 'failed' | 'skipped' | string;
  delivered_at: string | null;
  delivery_error: string | null;
}

export interface DigestSection {
  key: keyof Pick<DigestPayload, 'stalled' | 'trials_ending' | 'quiet' | 'pending_over_threshold' | 'admins_without_mfa' | 'open_impersonations'>;
  label: string;
  count: number;
  severity: 'error' | 'warning' | 'info';
}

// Sections in the order an operator should read them: revenue risk first
// (trials), then setup blockers, then retention, then hygiene.
export function digestSections(p: DigestPayload): DigestSection[] {
  const rows: DigestSection[] = [
    { key: 'trials_ending', label: 'Trials ending within 7 days', count: p.trials_ending?.length ?? 0, severity: 'error' },
    { key: 'stalled', label: 'Stalled in setup (7+ days)', count: p.stalled?.length ?? 0, severity: 'warning' },
    { key: 'pending_over_threshold', label: `Pending longer than ${p.settings?.pending_company_threshold_days ?? 2} days`, count: p.pending_over_threshold?.length ?? 0, severity: 'warning' },
    { key: 'quiet', label: 'Gone quiet (30+ days)', count: p.quiet?.length ?? 0, severity: 'warning' },
    { key: 'admins_without_mfa', label: 'Platform admins without MFA', count: p.admins_without_mfa?.length ?? 0, severity: 'error' },
    { key: 'open_impersonations', label: 'Open View-as sessions', count: p.open_impersonations?.length ?? 0, severity: 'info' },
  ];
  return rows.filter((r) => r.count > 0);
}

// Mirrors platform_digest_summary() so the UI can show the same line the
// notification carried without another round-trip.
export function digestSummary(p: DigestPayload): string {
  if (!p.attention_count) return 'All clear - nothing needs attention';
  const parts: string[] = [];
  if (p.stalled?.length) parts.push(`${p.stalled.length} stalled in setup`);
  if (p.trials_ending?.length) parts.push(`${p.trials_ending.length} trial(s) ending`);
  if (p.quiet?.length) parts.push(`${p.quiet.length} gone quiet`);
  if (p.pending_over_threshold?.length) parts.push(`${p.pending_over_threshold.length} pending too long`);
  if (p.admins_without_mfa?.length) parts.push(`${p.admins_without_mfa.length} admin(s) without MFA`);
  return parts.join(' · ');
}

export function deliveryLabel(row: Pick<DigestRow, 'delivery_status' | 'recipients' | 'delivery_error'>): { label: string; color: 'default' | 'success' | 'warning' | 'error' } {
  switch (row.delivery_status) {
    case 'sent':
      return { label: `Emailed to ${row.recipients.length}`, color: 'success' };
    case 'failed':
      return { label: `Email failed${row.delivery_error ? `: ${row.delivery_error}` : ''}`, color: 'error' };
    case 'skipped':
      return { label: 'In-app only (no recipients)', color: 'default' };
    default:
      return { label: 'Email pending', color: 'warning' };
  }
}

export function periodLabel(row: Pick<DigestRow, 'period_start' | 'period_end'>): string {
  const from = new Date(row.period_start);
  const to = new Date(row.period_end);
  const hours = Math.round((to.getTime() - from.getTime()) / 3_600_000);
  if (hours <= 36) return `Last ${hours}h`;
  return `Last ${Math.round(hours / 24)} days`;
}
