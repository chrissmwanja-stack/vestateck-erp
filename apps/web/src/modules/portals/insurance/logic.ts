import type {
  BulkRenewalResult, ClaimPaymentKind, ClaimPaymentMode, ClaimStatus, CommissionEntry, CommissionStatement, CommissionStatementRow,
  CommissionStatus, Policy, PolicyStatus, RenewalOutcome, StatementCommissionStatus,
} from './types';

// Pure helpers for the insurance screens. Nothing here touches the database.
// The server (ins_* RPCs and guards) is the source of truth. These mirror it so
// the UI can explain a result before the user submits.

/** Claim lifecycle. Mirrors the state map in ins_transition_claim(). */
export const CLAIM_TRANSITIONS: Record<ClaimStatus, ClaimStatus[]> = {
  notified: ['assessing', 'repudiated'],
  assessing: ['approved', 'repudiated'],
  approved: ['settled', 'assessing'],
  settled: ['closed'],
  repudiated: ['closed'],
  closed: [],
};

/** Decisions that need admin or manager rights on the server. */
export const CLAIM_DECISION_STATUSES: ClaimStatus[] = ['approved', 'settled', 'repudiated', 'closed'];

/** Segregation of duties: the person who registered a claim cannot approve it. The server enforces this too. */
export function isClaimApprovalBlockedFor(claim: { created_by?: string | null }, userId: string | null): boolean {
  return !!claim.created_by && userId !== null && claim.created_by === userId;
}

/** Un-approval is a manager decision, and only before anything is recognised or paid. */
export function canUnapproveClaim(
  claim: { status: ClaimStatus; recognised_at?: string | null; paid_amount: number },
  canManage: boolean,
): boolean {
  return canManage && claim.status === 'approved' && !claim.recognised_at && claim.paid_amount === 0;
}

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

export const CLAIM_PAYMENT_MODE_LABEL: Record<ClaimPaymentMode, string> = {
  insurer_direct: 'Insurer pays the client',
  via_broker: 'Brokerage pays the client',
};

export const CLAIM_PAYMENT_MODE_HELP: Record<ClaimPaymentMode, string> = {
  insurer_direct:
    'The insurer pays the client directly. Record each payment the insurer confirms. Nothing is posted to the ledger because the brokerage never holds the money.',
  via_broker:
    'The insurer pays the brokerage and the brokerage pays the client, both through a client-money bank account. Each step is posted to the ledger. The brokerage cannot pay the client ahead of the insurer.',
};

export const CLAIM_PAYMENT_KIND_LABEL: Record<ClaimPaymentKind, string> = {
  insurer_direct: 'Paid by insurer to client',
  insurer_receipt: 'Received from insurer',
  client_payout: 'Paid to client',
};

/** What is still unpaid on an approved claim (insurer-direct), floored at zero. */
export function claimRemainingToPay(approved: number | null, paid: number): number {
  return Math.max(0, Math.round(((approved ?? 0) - paid) * 100) / 100);
}

export type ClaimMoneyKind = 'direct' | 'receipt' | 'payout';

/**
 * Client-side checks that match ins_record_claim_payment / _receipt / _payout.
 * `max` is what the server will accept: the unpaid balance (direct), what the
 * insurer still owes (receipt) or what is held for the client (payout).
 */
export function validateClaimMoneyInput(input: {
  kind: ClaimMoneyKind;
  amount: number;
  max: number;
  currency: string;
  date: string;
  todayIso: string;
  notifiedIso: string;
  reference: string;
  bankId: string;
}): string[] {
  const errors: string[] = [];
  if (!(input.amount > 0)) errors.push('Enter an amount above zero.');
  else if (input.amount > input.max) {
    const cap = formatMoney(input.max, input.currency);
    errors.push(
      input.kind === 'direct' ? `Only ${cap} is still unpaid on this claim.`
        : input.kind === 'receipt' ? `The insurer owes only ${cap} on this claim.`
        : `Only ${cap} has been received from the insurer and not yet paid out.`,
    );
  }
  if (!input.date) errors.push('Choose a date.');
  else if (input.date > input.todayIso) errors.push('The date cannot be in the future.');
  else if (input.date < input.notifiedIso) errors.push('The date cannot be before the claim was notified.');
  if (input.kind === 'direct' && !input.reference.trim()) errors.push("Enter the insurer's payment reference.");
  if (input.kind !== 'direct' && !input.bankId) errors.push('Choose a client-money bank account.');
  return errors;
}

export const POLICY_STATUS_LABEL: Record<PolicyStatus, string> = {
  draft: 'Draft',
  active: 'Active',
  renewed: 'Renewed',
  reversed: 'Reversed',
  cancelled: 'Cancelled',
};

export const COMMISSION_STATUS_LABEL: Record<CommissionStatus, string> = {
  deferred: 'Deferred',
  earned: 'Earned',
  transferred: 'Transferred',
};

export function isTransferable(entry: CommissionEntry): boolean {
  return entry.status === 'earned' && !entry.cancellation_id;
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

/**
 * A policy is in force while it is active and its expiry date has not passed.
 * There is no "expired" status: an active policy past its expiry date keeps the
 * status 'active' until it is renewed, so status alone overstates what is in force.
 */
export function isInForce(policy: { status: PolicyStatus; expiry_date: string }, todayIso: string): boolean {
  return policy.status === 'active' && policy.expiry_date.slice(0, 10) >= todayIso;
}

/**
 * What to show for a policy's status. The stored status never becomes 'expired'
 * (the server only moves a policy on renewal, cancellation or reversal), so an
 * active policy whose expiry date has passed is shown as 'expired' until it is
 * renewed. This is a display state only: nothing is written to the database.
 */
export type PolicyDisplayStatus = PolicyStatus | 'expired';

export function isExpired(policy: { status: PolicyStatus; expiry_date: string }, todayIso: string): boolean {
  return policy.status === 'active' && policy.expiry_date.slice(0, 10) < todayIso;
}

export function policyDisplayStatus(policy: { status: PolicyStatus; expiry_date: string }, todayIso: string): PolicyDisplayStatus {
  return isExpired(policy, todayIso) ? 'expired' : policy.status;
}

export const POLICY_DISPLAY_STATUS_LABEL: Record<PolicyDisplayStatus, string> = {
  ...POLICY_STATUS_LABEL,
  expired: 'Expired',
};

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

export const RENEWAL_OUTCOME_LABEL: Record<RenewalOutcome, string> = {
  lost: 'Lost to another broker or insurer',
  declined: 'Client declined to renew',
  lapsed: 'No response, allowed to lapse',
};

export const RENEWAL_OUTCOMES: RenewalOutcome[] = ['lost', 'declined', 'lapsed'];

/** A pipeline row is open until a renewal outcome is recorded for it. */
export function isRenewalOpen(row: { renewal_outcome: RenewalOutcome | null }): boolean {
  return row.renewal_outcome === null;
}

/** A renewal can be started when the policy is open and has no draft yet. The server checks both again. */
export function canStartRenewal(row: { renewal_outcome: RenewalOutcome | null; renewal_draft_id: string | null }): boolean {
  return isRenewalOpen(row) && row.renewal_draft_id === null;
}

export function validateRenewalOutcome(outcome: RenewalOutcome | '', reason: string): string[] {
  const errors: string[] = [];
  if (!outcome) errors.push('Choose what happened.');
  if (reason.trim().length < 5) errors.push('Give a reason of at least 5 characters.');
  return errors;
}

/** Counts a bulk renewal's results and lists the refusals, with the server's code prefix removed. */
export function summariseBulkRenewal(results: BulkRenewalResult[]): {
  created: number;
  failed: { policy_no: string; message: string }[];
} {
  const failed = results
    .filter((r) => !r.ok)
    .map((r) => ({ policy_no: r.policy_no ?? 'Unknown policy', message: friendlyError(r.error ?? 'Could not start the renewal.') }));
  return { created: results.filter((r) => r.ok).length, failed };
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

/**
 * Adds amounts up per currency. Currencies are never added together: 5,000 USD and
 * 1,000,000 UGX are two totals, not one. A missing currency counts as `fallback`.
 */
export function sumByCurrency<T>(
  items: T[],
  currencyOf: (item: T) => string | null | undefined,
  amountOf: (item: T) => number | string | null | undefined,
  fallback = 'UGX',
): Record<string, number> {
  const totals: Record<string, number> = {};
  for (const item of items) {
    const currency = currencyOf(item) || fallback;
    const amount = Number(amountOf(item) ?? 0);
    totals[currency] = Math.round(((totals[currency] ?? 0) + (Number.isFinite(amount) ? amount : 0)) * 100) / 100;
  }
  return totals;
}

/**
 * One line per currency, the company's own currency first and the rest A to Z.
 * With no amounts at all it shows zero in the company's currency.
 */
export function formatMoneyByCurrency(totals: Record<string, number>, functionalCurrency = 'UGX'): string {
  const currencies = Object.keys(totals).sort((a, b) =>
    a === functionalCurrency ? -1 : b === functionalCurrency ? 1 : a.localeCompare(b),
  );
  if (currencies.length === 0) return formatMoney(0, functionalCurrency);
  return currencies.map((c) => formatMoney(totals[c], c)).join('\n');
}

/** Strips the server's error code prefix (e.g. "INS_NOT_DRAFT: ...") for display. */
export function friendlyError(message: string): string {
  return message.replace(/^[A-Z][A-Z_]+:\s*/, '');
}

export const STATEMENT_STATUS_LABEL: Record<StatementCommissionStatus, string> = {
  ...COMMISSION_STATUS_LABEL,
  legacy: 'Legacy (income at bind)',
  reversed: 'Reversed (original amounts; no outstanding premium)',
};

const money = (value: number | null | undefined): number => Math.round(Number(value ?? 0) * 100) / 100;

/**
 * Builds one insurer's commission statement from its bound policies and the
 * commission ledger. A policy is on the statement when it was bound within the
 * period (inclusive, by bound date). Policies bound before commission deferral
 * have no ledger entry; they appear as 'legacy' so the statement still adds up
 * to every bound policy. Caller passes only the chosen insurer's policies and
 * a single currency; mixed currencies are refused so totals are never summed
 * across currencies.
 */
export function buildCommissionStatement(
  policies: Policy[],
  ledger: CommissionEntry[],
  period: { from: string; to: string },
  /** Build the statement for one currency. Without it, a period that mixes currencies is refused rather than totalled. */
  currency?: string,
): CommissionStatement {
  const byPolicy = new Map(ledger.map((entry) => [entry.policy_id, entry]));
  const allRows: CommissionStatementRow[] = policies
    .filter((p) => p.status !== 'draft' && p.bound_at)
    .map((p) => ({ policy: p, boundOn: (p.bound_at as string).slice(0, 10) }))
    .filter(({ boundOn }) => boundOn >= period.from && boundOn <= period.to)
    .sort((a, b) => a.boundOn.localeCompare(b.boundOn) || a.policy.policy_no.localeCompare(b.policy.policy_no))
    .map(({ policy: p, boundOn }) => {
      const entry = byPolicy.get(p.id);
      return {
        policy_id: p.id,
        policy_no: p.policy_no,
        client_name: p.ins_clients?.bd_clients?.name ?? '-',
        bound_on: boundOn,
        currency: p.currency,
        gross_premium: money(p.gross_premium),
        net_premium: money(p.net_premium_to_insurer),
        commission: money(entry ? entry.amount : p.commission_amount),
        status: p.status === 'reversed' ? 'reversed' as const : entry ? entry.status : 'legacy',
        earned_on: entry?.earned_on ?? null,
        transfer_no: entry?.transfer_no ?? null,
        transfer_date: entry?.transfer_date ?? null,
      };
    });

  const rows = currency ? allRows.filter((r) => r.currency === currency) : allRows;
  if (new Set(rows.map((r) => r.currency)).size > 1) {
    throw new Error('This insurer has policies in more than one currency in this period. Choose a currency.');
  }

  const totals = rows.reduce(
    (acc, r) => {
      acc.policies += 1;
      if (r.status === 'reversed') {
        acc.reversed += r.commission;
        return acc;
      }
      acc.gross_premium += r.gross_premium;
      acc.net_premium += r.net_premium;
      acc.commission += r.commission;
      acc[r.status] += r.commission;
      return acc;
    },
    { policies: 0, gross_premium: 0, net_premium: 0, commission: 0, deferred: 0, earned: 0, transferred: 0, legacy: 0, reversed: 0 },
  );
  for (const key of Object.keys(totals) as (keyof typeof totals)[]) totals[key] = money(totals[key]);
  return { rows, totals };
}

/** The currencies of the policies a statement would list for the period, the most used first. */
export function statementCurrencies(policies: Policy[], period: { from: string; to: string }): string[] {
  const counts = new Map<string, number>();
  for (const p of policies) {
    if (p.status === 'draft' || !p.bound_at) continue;
    const boundOn = p.bound_at.slice(0, 10);
    if (boundOn < period.from || boundOn > period.to) continue;
    counts.set(p.currency, (counts.get(p.currency) ?? 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([c]) => c);
}

export function validateStatementPeriod(from: string, to: string): string | null {
  if (!from || !to) return 'Choose both a start and an end date.';
  if (from > to) return 'The start date is after the end date.';
  return null;
}

