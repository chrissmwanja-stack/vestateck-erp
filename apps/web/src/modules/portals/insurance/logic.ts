import type { ClaimStatus, CommissionEntry, CommissionStatus, PolicyStatus } from './types';

// Pure helpers for the insurance screens. Nothing here touches the database.
// The server (ins_* RPCs and guards) is the source of truth. These mirror it so
// the UI can explain a result before the user submits.

/** Claim lifecycle. Mirrors the state map in ins_transition_claim(). */
export const CLAIM_TRANSITIONS: Record<ClaimStatus, ClaimStatus[]> = {
  notified: ['assessing', 'repudiated'],
  assessing: ['approved', 'repudiated'],
  approved: ['settled'],
  settled: ['closed'],
  repudiated: ['closed'],
  closed: [],
};

/** Decisions that need admin or manager rights on the server. */
export const CLAIM_DECISION_STATUSES: ClaimStatus[] = ['approved', 'settled', 'repudiated', 'closed'];

export function nextClaimStatuses(from: ClaimStatus): ClaimStatus[] {
  return CLAIM_TRANSITIONS[from] ?? [];
}

export function isClaimTransitionAllowed(from: ClaimStatus, to: ClaimStatus): boolean {
  return nextClaimStatuses(from).includes(to);
}

export const CLAIM_STATUS_LABEL: Record<ClaimStatus, string> = {
  notified: 'Notified',
  assessing: 'Assessing',
  approved: 'Approved',
  settled: 'Settled',
  repudiated: 'Repudiated',
  closed: 'Closed',
};

export const POLICY_STATUS_LABEL: Record<PolicyStatus, string> = {
  draft: 'Draft',
  active: 'Active',
  renewed: 'Renewed',
};

export const COMMISSION_STATUS_LABEL: Record<CommissionStatus, string> = {
  deferred: 'Deferred',
  earned: 'Earned',
  transferred: 'Transferred',
};

export function isTransferable(entry: CommissionEntry): boolean {
  return entry.status === 'earned';
}

export function sumAmounts(entries: CommissionEntry[]): number {
  return entries.reduce((total, entry) => total + Number(entry.amount), 0);
}

export function validateTransferInput(input: {
  fromId: string;
  toId: string;
  date: string;
  selected: CommissionEntry[];
  todayIso: string;
}): string[] {
  const errors: string[] = [];
  if (!input.fromId) errors.push('Choose a client-money account.');
  if (!input.toId) errors.push('Choose an operating account.');
  if (input.fromId && input.toId && input.fromId === input.toId) errors.push('Choose different bank accounts.');
  if (!input.date) errors.push('Choose a transfer date.');
  else if (daysBetween(input.todayIso, input.date) > 1) errors.push('Transfer date cannot be more than one day in the future.');
  if (input.selected.length === 0) errors.push('Select at least one earned commission entry.');
  const latestEarnedDate = input.selected.reduce<string | null>(
    (latest, entry) => entry.earned_on && (!latest || entry.earned_on > latest) ? entry.earned_on : latest,
    null,
  );
  if (input.date && latestEarnedDate && input.date < latestEarnedDate) {
    errors.push('Transfer date cannot be before commission was earned.');
  }
  return errors;
}

export function isValidVoidReason(reason: string): boolean {
  return reason.trim().length >= 5;
}

/** Open claims are those still being worked on (not settled, repudiated or closed). */
export function isClaimOpen(status: ClaimStatus): boolean {
  return status === 'notified' || status === 'assessing' || status === 'approved';
}

/**
 * Commission and net premium, rounded to 2dp the way ins_bind_policy() does it.
 * This is a preview. The server computes the stored amounts at bind.
 */
export function commissionSplit(gross: number, ratePct: number): { commission: number; net: number } {
  const commission = Math.round(((gross * ratePct) / 100) * 100) / 100;
  return { commission, net: Math.round((gross - commission) * 100) / 100 };
}

export type RenewalBucket = 'overdue' | 'd0_30' | 'd31_60' | 'd61_90' | 'd91_120' | 'later';

export const RENEWAL_BUCKET_LABEL: Record<RenewalBucket, string> = {
  overdue: 'Overdue',
  d0_30: '0 to 30 days',
  d31_60: '31 to 60 days',
  d61_90: '61 to 90 days',
  d91_120: '91 to 120 days',
  later: 'Later',
};

export function renewalBucket(daysToExpiry: number): RenewalBucket {
  if (daysToExpiry < 0) return 'overdue';
  if (daysToExpiry <= 30) return 'd0_30';
  if (daysToExpiry <= 60) return 'd31_60';
  if (daysToExpiry <= 90) return 'd61_90';
  if (daysToExpiry <= 120) return 'd91_120';
  return 'later';
}

/** Whole days between two ISO dates (YYYY-MM-DD), end minus start. */
export function daysBetween(startIso: string, endIso: string): number {
  const ms = Date.parse(`${endIso}T00:00:00Z`) - Date.parse(`${startIso}T00:00:00Z`);
  return Math.round(ms / 86_400_000);
}

/** Policy term in days, the same measure ins_create_renewal_draft() copies forward. */
export function policyTermDays(inceptionIso: string, expiryIso: string): number {
  return daysBetween(inceptionIso, expiryIso);
}

/** Client-side checks that match the server's own. Returns messages; empty means valid. */
export function validatePolicyInput(input: {
  clientId: string;
  insurerId: string;
  productLineId: string;
  inception: string;
  expiry: string;
  sumInsured: number;
  grossPremium: number;
  commissionRatePct: number;
}): string[] {
  const errors: string[] = [];
  if (!input.clientId) errors.push('Choose a client.');
  if (!input.insurerId) errors.push('Choose an insurer.');
  if (!input.productLineId) errors.push('Choose a product line.');
  if (!input.inception || !input.expiry || input.expiry <= input.inception) errors.push('Expiry must be after inception.');
  if (!(input.sumInsured >= 0)) errors.push('Sum insured cannot be negative.');
  if (!(input.grossPremium >= 0)) errors.push('Premium cannot be negative.');
  if (!(input.commissionRatePct >= 0 && input.commissionRatePct < 100)) errors.push('Commission must be at least 0% and below 100%.');
  return errors;
}

export function formatMoney(amount: number | null | undefined, currency = 'UGX'): string {
  if (amount === null || amount === undefined || Number.isNaN(amount)) return '-';
  return new Intl.NumberFormat('en-UG', { style: 'currency', currency, maximumFractionDigits: 2 }).format(amount);
}

/** Strips the server's error code prefix (e.g. "INS_NOT_DRAFT: ...") for display. */
export function friendlyError(message: string): string {
  return message.replace(/^[A-Z][A-Z_]+:\s*/, '');
}
