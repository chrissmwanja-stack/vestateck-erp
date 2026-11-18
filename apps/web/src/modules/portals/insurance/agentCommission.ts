// Agent commission: what the brokerage owes its sub-agents and referral partners.
// Distinct from the brokerage's own commission from insurers (logic.ts / CommissionPage).
//
// All money rules live in the database RPCs. This file only groups and labels rows
// for display; it never recalculates commission or withholding.

export type AgentAccrualStatus = 'accrued' | 'eligible' | 'paid' | 'reversed';

export interface AgentAccrual {
  id: string;
  policy_id: string;
  intermediary_id: string;
  basis: string;
  gross_amount: number;
  wht_amount: number;
  net_amount: number | null;
  currency: string;
  status: AgentAccrualStatus;
  eligible_on: string | null;
  paid_at: string | null;
  created_at: string;
  updated_at: string;
}

export const AGENT_ACCRUAL_STATUS_LABEL: Record<AgentAccrualStatus, string> = {
  accrued: 'Accrued',
  eligible: 'Eligible for payment',
  paid: 'Paid',
  reversed: 'Reversed',
};

export const AGENT_BASIS_LABEL: Record<string, string> = {
  none: 'No commission (insurer-appointed)',
  pct_of_broker_commission: '% of brokerage commission',
  pct_of_gross_premium: '% of gross premium',
  flat_amount_per_policy: 'Fixed amount per policy',
  tiered_pct_of_broker_commission: 'Tiered % of brokerage commission',
};

export type CurrencyTotals = Record<string, number>;

/** What the intermediary is actually paid: the stored net, else gross less withholding. */
export const netOf = (a: Pick<AgentAccrual, 'gross_amount' | 'wht_amount' | 'net_amount'>): number =>
  a.net_amount ?? Math.round((a.gross_amount - a.wht_amount) * 100) / 100;

function addTo(totals: CurrencyTotals, currency: string, amount: number) {
  totals[currency] = Math.round(((totals[currency] ?? 0) + amount) * 100) / 100;
}

export interface AgentCommissionSummary {
  accrued: CurrencyTotals;      // gross, status accrued
  eligible: CurrencyTotals;     // gross, status eligible
  paid: CurrencyTotals;         // gross, status paid
  outstanding: CurrencyTotals;  // net still owed to agents (accrued + eligible)
  withholding: CurrencyTotals;  // tax withheld on non-reversed accruals
}

/** Currencies are never added together; reversed accruals count nowhere. */
export function summariseAccruals(accruals: AgentAccrual[]): AgentCommissionSummary {
  const s: AgentCommissionSummary = { accrued: {}, eligible: {}, paid: {}, outstanding: {}, withholding: {} };
  for (const a of accruals) {
    if (a.status === 'reversed') continue;
    if (a.status === 'accrued') addTo(s.accrued, a.currency, a.gross_amount);
    if (a.status === 'eligible') addTo(s.eligible, a.currency, a.gross_amount);
    if (a.status === 'paid') addTo(s.paid, a.currency, a.gross_amount);
    if (a.status === 'accrued' || a.status === 'eligible') addTo(s.outstanding, a.currency, netOf(a));
    if (a.wht_amount > 0) addTo(s.withholding, a.currency, a.wht_amount);
  }
  return s;
}

/** Newest activity first, by last change. */
export const recentAccruals = (accruals: AgentAccrual[], limit = 10): AgentAccrual[] =>
  [...accruals].sort((x, y) => y.updated_at.localeCompare(x.updated_at)).slice(0, limit);

// ---------------------------------------------------------------------------
// Commission terms (ins_intermediary_terms)
// ---------------------------------------------------------------------------
// How an intermediary is paid, in force over a date window. Terms are versioned, never
// edited: to change an arrangement, end-date the current term and enter a new one, so
// accruals already made keep the figures they were made with. These checks mirror the
// server (ins_set_intermediary_term / the table constraints) so the form can explain a
// problem early. The server stays the enforcement point.

export type AgentTermBasis =
  | 'none' | 'pct_of_broker_commission' | 'pct_of_gross_premium'
  | 'flat_amount_per_policy' | 'tiered_pct_of_broker_commission';
export type AgentTermStatus = 'draft' | 'approved' | 'withdrawn' | 'expired';

export interface AgentTerm {
  id: string;
  intermediary_id: string;
  basis: AgentTermBasis;
  rate_pct: number | null;
  fixed_amount: number | null;
  tier_from_amount: number | null;
  tier_to_amount: number | null;
  product_line_id: string | null;
  currency: string | null;
  effective_from: string;
  effective_to: string | null;
  source_ref: string | null;
  status: AgentTermStatus;
  entered_by: string | null;
  approved_by: string | null;
  approved_at: string | null;
  withdrawn_reason: string | null;
  created_at: string;
}

export const AGENT_TERM_STATUS_LABEL: Record<AgentTermStatus, string> = {
  draft: 'Draft (awaiting approval)',
  approved: 'Approved',
  withdrawn: 'Withdrawn',
  expired: 'Expired',
};

/** Bases a brokerage-paid intermediary (sub-agent, referral partner) can have. */
export const PAID_BASES: AgentTermBasis[] = [
  'pct_of_broker_commission', 'pct_of_gross_premium', 'flat_amount_per_policy', 'tiered_pct_of_broker_commission',
];

/**
 * Which bases may be entered for a category. An insurer-appointed agent is paid by the insurer,
 * so the only record is 'none'. An independent broker is a co-broker, which the server refuses.
 */
export function basesForCategory(category: string): AgentTermBasis[] {
  if (category === 'insurer_appointed_agent') return ['none'];
  if (category === 'sub_agent' || category === 'referral_partner') return PAID_BASES;
  return [];
}

export interface TermFormInput {
  basis: AgentTermBasis | '';
  rate_pct: string;
  fixed_amount: string;
  tier_from_amount: string;
  tier_to_amount: string;
  effective_from: string;
  effective_to: string;
}

const num = (v: string): number | null => (v.trim() === '' || Number.isNaN(Number(v)) ? null : Number(v));

/** Returns a message for the first problem, or null if the form is fit to send. */
export function validateTermInput(i: TermFormInput): string | null {
  if (!i.basis) return 'Choose how this intermediary is paid.';
  if (!i.effective_from) return 'Enter the date the term starts.';
  if (i.effective_to && i.effective_to < i.effective_from) return 'The end date must be on or after the start date.';
  const rate = num(i.rate_pct);
  const fixed = num(i.fixed_amount);
  if (i.basis === 'none') return null;
  if (i.basis === 'flat_amount_per_policy') {
    if (fixed === null || fixed <= 0) return 'Enter a fixed amount greater than zero.';
    return null;
  }
  if (rate === null || rate < 0 || rate > 100) return 'Enter a percentage between 0 and 100.';
  if (i.basis === 'tiered_pct_of_broker_commission') {
    const from = num(i.tier_from_amount);
    const to = num(i.tier_to_amount);
    if (from === null || to === null) return 'A tier needs both a from and a to amount.';
    if (to <= from) return 'The tier\'s "to" amount must be greater than its "from" amount.';
  }
  return null;
}

/** The figure a term pays, in words: "30% of ...", "UGX 50,000 per policy", "none". */
export function termFigure(t: Pick<AgentTerm, 'basis' | 'rate_pct' | 'fixed_amount' | 'tier_from_amount' | 'tier_to_amount' | 'currency'>): string {
  const ccy = t.currency ?? 'UGX';
  const money = (n: number) => new Intl.NumberFormat('en-UG', { style: 'currency', currency: ccy, maximumFractionDigits: 2 }).format(n);
  switch (t.basis) {
    case 'none': return 'No commission';
    case 'flat_amount_per_policy': return t.fixed_amount === null ? '-' : `${money(t.fixed_amount)} per policy`;
    case 'pct_of_gross_premium': return `${t.rate_pct ?? '-'}% of gross premium`;
    case 'tiered_pct_of_broker_commission':
      return `${t.rate_pct ?? '-'}% on commission ${t.tier_from_amount === null ? '' : money(t.tier_from_amount)} to ${t.tier_to_amount === null ? '' : money(t.tier_to_amount)}`;
    default: return `${t.rate_pct ?? '-'}% of brokerage commission`;
  }
}

export type TermPhase = 'draft' | 'scheduled' | 'in_force' | 'ended' | 'withdrawn';

/** Where a term stands today: an approved term is scheduled, in force or ended by its dates. */
export function termPhase(t: Pick<AgentTerm, 'status' | 'effective_from' | 'effective_to'>, today: string): TermPhase {
  if (t.status === 'draft') return 'draft';
  if (t.status === 'withdrawn') return 'withdrawn';
  if (t.status === 'expired') return 'ended';
  if (t.effective_from > today) return 'scheduled';
  if (t.effective_to !== null && t.effective_to < today) return 'ended';
  return 'in_force';
}

export const TERM_PHASE_LABEL: Record<TermPhase, string> = {
  draft: 'Draft', scheduled: 'Scheduled', in_force: 'In force', ended: 'Ended', withdrawn: 'Withdrawn',
};

/** Approve: a manager, on a draft, who did not enter it (the server enforces the same rule). */
export const canApproveTerm = (t: Pick<AgentTerm, 'status' | 'entered_by'>, userId: string | null, canManage: boolean): boolean =>
  canManage && t.status === 'draft' && userId !== null && t.entered_by !== userId;

/** End-dating applies to an approved term that has no end date yet or one still ahead. */
export const canEndTerm = (t: Pick<AgentTerm, 'status' | 'effective_to'>, today: string, canManage: boolean): boolean =>
  canManage && t.status === 'approved' && (t.effective_to === null || t.effective_to >= today);

// ---------------------------------------------------------------------------
// Accrual register (stage 3)
// ---------------------------------------------------------------------------
// One row per policy and intermediary: the share of brokerage commission owed to a
// sub-agent or referral partner. The full row, including the columns the detail
// dialog shows, is the table's own shape -- nothing here is derived money.

export interface AgentAccrualDetail extends AgentAccrual {
  term_id: string | null;
  rate_pct: number | null;
  fixed_amount: number | null;
  commission_base: number;
  reversal_reason: string | null;
  journal_entry_id: string | null;
  payment_journal_entry_id: string | null;
  /** The approved rate row the withholding was copied from. Copied, not joined. */
  wht_rate_pct: number | null;
  /** Whether the withholding settled the agent's liability on that date (s.139(aa)). */
  wht_is_final: boolean | null;
  wht_parameter_ref: string | null;
}

export type AgentEventKind = 'accrued' | 'eligible' | 'paid' | 'reversed';

export interface AgentAccrualEvent {
  id: string;
  accrual_id: string;
  event: AgentEventKind | string;
  amount: number | null;
  journal_entry_id: string | null;
  note: string | null;
  actor_id: string | null;
  created_at: string;
}

export const AGENT_EVENT_LABEL: Record<string, string> = {
  accrued: 'Accrued',
  eligible: 'Marked eligible',
  paid: 'Paid',
  reversed: 'Reversed',
};

/**
 * What the amount on an event means, which is NOT the same thing for every event.
 * A paid event carries the NET handed over, a reversal carries the GROSS unwound.
 * Labelling both "amount" invites reading 270,000 and 300,000 as a discrepancy.
 */
export const AGENT_EVENT_AMOUNT_LABEL: Record<string, string> = {
  accrued: 'gross share',
  eligible: 'gross share',
  paid: 'net paid',
  reversed: 'gross reversed',
};

/** The date the share is attributed to: when it was recognised, and paid if it was paid. */
export const accrualDate = (a: Pick<AgentAccrualDetail, 'created_at'>): string => isoDate(a.created_at);

const isoDate = (iso: string): string => iso.slice(0, 10);

/**
 * Eligibility in words. "Eligible" on its own reads like "paid", and the difference
 * between the two is the whole point of the lifecycle.
 */
export function eligibilityLabel(a: Pick<AgentAccrualDetail, 'status' | 'eligible_on'>): string {
  if (a.status === 'eligible') return a.eligible_on ? `Eligible since ${a.eligible_on}` : 'Eligible, not yet paid';
  if (a.status === 'paid') return 'Paid';
  if (a.status === 'reversed') return 'Reversed, not payable';
  return 'Waiting for the brokerage commission to be earned';
}

/**
 * How much withholding, and what it MEANS, for one accrual.
 *
 * Since withholding moved to the payment event, an unpaid share carries none: the
 * tax is taken when the agent is paid, and the character is settled by the law in
 * force on that payment date. So "0.00" on an accrued row must read as "not yet
 * determined", not as "no tax" -- otherwise a reviewer concludes the agent owes
 * nothing when the deduction has simply not happened yet.
 *
 * This describes rows written BEFORE that change too, where tax was taken at
 * accrual: those carry a rate and a character and are described on their own terms.
 */
export function withholdingNote(a: Pick<AgentAccrualDetail, 'status' | 'wht_amount' | 'wht_rate_pct' | 'wht_is_final'>): string {
  if (a.status === 'reversed') return 'nothing to withhold, the share was reversed';
  if (a.wht_amount > 0) {
    const rate = a.wht_rate_pct === null ? 'the approved rate' : `${a.wht_rate_pct}%`;
    if (a.wht_is_final === true) return `final tax at ${rate}`;
    if (a.wht_is_final === false) return `on account at ${rate}, the agent still declares the income`;
    return `withheld at ${rate}`;
  }
  if (a.status === 'paid') return 'nothing withheld on this share';
  return 'determined when the agent is paid';
}

// ---- Filters -----------------------------------------------------------------

export interface AccrualFilters {
  text: string;
  agentId: string;
  status: '' | AgentAccrualStatus;
  basis: string;
  currency: string;
  accruedFrom: string;
  accruedTo: string;
}

/** Typed as Record<string,string> so countActive() can read it without a cast. */
export const EMPTY_ACCRUAL_FILTERS: AccrualFilters = {
  text: '', agentId: '', status: '', basis: '', currency: '', accruedFrom: '', accruedTo: '',
};

export type AccrualSort = 'newest' | 'oldest' | 'gross_desc' | 'agent_az' | 'policy_az';

export const ACCRUAL_SORT_LABEL: Record<AccrualSort, string> = {
  newest: 'Newest first',
  oldest: 'Oldest first',
  gross_desc: 'Largest gross first',
  agent_az: 'Agent A to Z',
  policy_az: 'Policy A to Z',
};

export interface AccrualLabels {
  agent: (a: { intermediary_id: string }) => string;
  policy: (a: { policy_id: string }) => string;
  client: (a: { policy_id: string }) => string;
}

/** A date-only comparison, so a time zone cannot move a row into or out of a range. */
function inRange(day: string, from: string, to: string): boolean {
  if (from && day < from) return false;
  if (to && day > to) return false;
  return true;
}

export function filterAccruals(
  accruals: readonly AgentAccrualDetail[],
  f: AccrualFilters,
  labels: AccrualLabels,
): AgentAccrualDetail[] {
  const words = fold(f.text).split(/\s+/).filter(Boolean);
  return accruals.filter((a) => {
    if (f.agentId && a.intermediary_id !== f.agentId) return false;
    if (f.status && a.status !== f.status) return false;
    if (f.basis && a.basis !== f.basis) return false;
    if (f.currency && a.currency !== f.currency) return false;
    if (!inRange(accrualDate(a), f.accruedFrom, f.accruedTo)) return false;
    if (words.length === 0) return true;
    const haystack = fold([labels.agent(a), labels.policy(a), labels.client(a)].join(' '));
    return words.every((w) => haystack.includes(w));
  });
}

export function sortAccruals(
  accruals: readonly AgentAccrualDetail[],
  sort: AccrualSort,
  labels: AccrualLabels,
): AgentAccrualDetail[] {
  const byAgent = (x: AgentAccrualDetail, y: AgentAccrualDetail) =>
    labels.agent(x).localeCompare(labels.agent(y));
  const byDate = (x: AgentAccrualDetail, y: AgentAccrualDetail) =>
    x.created_at.localeCompare(y.created_at) || x.id.localeCompare(y.id);
  const out = [...accruals];
  switch (sort) {
    case 'oldest': return out.sort(byDate);
    case 'gross_desc': return out.sort((x, y) => y.gross_amount - x.gross_amount || byDate(y, x));
    case 'agent_az': return out.sort((x, y) => byAgent(x, y) || byDate(y, x));
    case 'policy_az': return out.sort((x, y) => labels.policy(x).localeCompare(labels.policy(y)) || byDate(y, x));
    default: return out.sort((x, y) => byDate(y, x));
  }
}

/** Chronological, and stable when two events share a timestamp. */
export const sortEvents = (events: readonly AgentAccrualEvent[]): AgentAccrualEvent[] =>
  [...events].sort((x, y) => x.created_at.localeCompare(y.created_at) || x.id.localeCompare(y.id));

export interface RegisterTotals {
  gross: CurrencyTotals;
  withholding: CurrencyTotals;
  net: CurrencyTotals;
}

/**
 * Totals for the rows on screen, reversed shares left out, each currency separate.
 *
 * Net is the stored net where there is one and gross less withholding otherwise,
 * which under the payment-event rule means an accrued row contributes its gross:
 * nothing has been withheld, so nothing has been deducted from what the agent is
 * owed. That is the correct reading, and it is why this must not "helpfully"
 * apply a tax rate to an unpaid share.
 */
export function registerTotals(accruals: readonly AgentAccrualDetail[]): RegisterTotals {
  const t: RegisterTotals = { gross: {}, withholding: {}, net: {} };
  for (const a of accruals) {
    if (a.status === 'reversed') continue;
    addTo(t.gross, a.currency, a.gross_amount);
    if (a.wht_amount > 0) addTo(t.withholding, a.currency, a.wht_amount);
    addTo(t.net, a.currency, netOf(a));
  }
  return t;
}

/** Same accent- and case-insensitive fold the rest of the insurance lists use. */
function fold(v: unknown): string {
  return String(v ?? '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
}
