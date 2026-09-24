import type { Json } from '@erp-platform/shared';
import { ACTION_LABEL } from './Constants';
import type { ProfileDraft, TenantRow } from './Types';

export function actionLabel(action: string): string {
  return ACTION_LABEL[action] ?? action;
}

// Days until a timestamp; negative when past. Exported for tests.
export function daysUntil(iso: string | null, now: Date = new Date()): number | null {
  if (!iso) return null;
  return Math.ceil((new Date(iso).getTime() - now.getTime()) / 86_400_000);
}

export function fmtDate(iso: string | null | undefined): string {
  return iso ? new Date(iso).toLocaleDateString() : '—';
}

export function fmtDateTime(iso: string | null | undefined): string {
  return iso ? new Date(iso).toLocaleString() : '—';
}

// <input type="date"> wants yyyy-mm-dd in local time.
export function toDateInput(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function draftFrom(t: TenantRow): ProfileDraft {
  return {
    name: t.name,
    contact_name: t.contact_name ?? '',
    contact_email: t.contact_email ?? '',
    contact_phone: t.contact_phone ?? '',
    tax_id: t.tax_id ?? '',
    address: t.address ?? '',
    country: t.country ?? 'UG',
    plan: t.plan,
    subscription_status: t.subscription_status,
    seat_limit: t.seat_limit == null ? '' : String(t.seat_limit),
    trial_ends_at: toDateInput(t.trial_ends_at),
    renews_at: toDateInput(t.renews_at),
  };
}

// Build the minimal jsonb patch: only keys whose value differs from the
// saved row, so the audit diff stays honest. Exported for tests.
export function buildProfilePatch(saved: TenantRow, draft: ProfileDraft): Record<string, Json> {
  const base = draftFrom(saved);
  const patch: Record<string, Json> = {};
  (Object.keys(draft) as (keyof ProfileDraft)[]).forEach((k) => {
    if (draft[k] === base[k]) return;
    const v = draft[k].trim();
    if (k === 'seat_limit') {
      patch[k] = v === '' ? null : Number(v);
    } else if (k === 'trial_ends_at' || k === 'renews_at') {
      // Date-only input -> end of that local day, so "ends 30 Sep" means
      // the customer keeps access through the 30th.
      patch[k] = v === '' ? null : new Date(`${v}T23:59:59`).toISOString();
    } else {
      patch[k] = v === '' ? null : v;
    }
  });
  return patch;
}