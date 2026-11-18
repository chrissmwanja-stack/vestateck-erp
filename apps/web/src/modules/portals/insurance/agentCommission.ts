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

// ---------------------------------------------------------------------------
// Payment authorisation (stage 4)
// ---------------------------------------------------------------------------
// An agent payment is proposed by one manager, approved by a SECOND, then
// released. These helpers hold the rules in one place so the screen cannot drift
// from the server, which remains the enforcement point: every function here is a
// mirror of a refusal the RPCs make, never a substitute for one.
//
// The authorisation is on the PAYMENT, not on the accrual. Whether the agent is
// owed the money and whether a payment is authorised are different questions.

export type AgentPaymentStatus = 'prepared' | 'approved' | 'paid' | 'rejected' | 'cancelled';

export interface AgentPayment {
  id: string;
  accrual_id: string;
  bank_account_id: string;
  currency: string;
  /** Frozen at preparing. The approver agrees to THIS number. */
  gross_amount: number;
  wht_amount: number;
  net_amount: number;
  /** The approved rate and its character, frozen with the figure. */
  wht_rate_pct: number | null;
  wht_is_final: boolean | null;
  wht_parameter_ref: string | null;
  paid_on: string;
  note: string | null;
  status: AgentPaymentStatus;
  prepared_by: string;
  prepared_at: string;
  approved_by: string | null;
  approved_at: string | null;
  payment_journal_entry_id: string | null;
}

export const AGENT_PAYMENT_STATUS_LABEL: Record<AgentPaymentStatus, string> = {
  prepared: 'Awaiting a second approver',
  approved: 'Approved, not yet released',
  paid: 'Paid',
  rejected: 'Declined',
  cancelled: 'Withdrawn',
};

/** Only a prepared payment is waiting on somebody, which is what a queue is. */
export const isActionable = (p: Pick<AgentPayment, 'status'>): boolean =>
  p.status === 'prepared' || p.status === 'approved';

/**
 * May this user approve this payment?
 *
 * The server refuses self-approval with INS_AGENT_SELF_APPROVAL and the table
 * carries the same rule as a constraint, so this only decides whether to OFFER
 * the button. Offering it and letting the server say no would be a worse
 * experience than not offering it -- and worse still, it would teach whoever
 * presses it that the control is advisory.
 */
export function canApprovePayment(
  p: Pick<AgentPayment, 'status' | 'prepared_by'>,
  userId: string | null,
  canManage: boolean,
): boolean {
  return canManage && p.status === 'prepared' && userId !== null && p.prepared_by !== userId;
}

/** Releasing needs an approval first; the server refuses anything else. */
export function canReleasePayment(
  p: Pick<AgentPayment, 'status'>,
  canManage: boolean,
): boolean {
  return canManage && p.status === 'approved';
}

/** The preparer may withdraw their own proposal; anybody else declines it. */
export function canCancelPayment(
  p: Pick<AgentPayment, 'status' | 'prepared_by'>,
  userId: string | null,
  canManage: boolean,
): boolean {
  return canManage && p.status === 'prepared' && userId !== null && p.prepared_by === userId;
}

/** Any manager may decline a proposal that is still open, including their own. */
export function canRejectPayment(p: Pick<AgentPayment, 'status'>, canManage: boolean): boolean {
  return canManage && p.status === 'prepared';
}

/**
 * Why a payment cannot be approved, in words, for the person looking at it.
 * Returns null when nothing is wrong. A disabled button with no explanation is
 * how people conclude the system is broken rather than that they are the wrong
 * person to press it.
 */
export function approvalBlockedReason(
  p: Pick<AgentPayment, 'status' | 'prepared_by'>,
  userId: string | null,
  canManage: boolean,
): string | null {
  if (!canManage) return 'Only an insurance manager can approve a payment.';
  if (p.status === 'paid') return 'This payment has already been released.';
  if (p.status === 'approved') return 'Already approved; it is ready to release.';
  if (p.status === 'rejected') return 'This proposal was declined. Prepare a new one.';
  if (p.status === 'cancelled') return 'This proposal was withdrawn.';
  if (userId !== null && p.prepared_by === userId) {
    return 'You prepared this payment, so somebody else has to approve it.';
  }
  return null;
}

export interface PaymentQueueTotals {
  /** Waiting on a second signature: the amount still to be authorised. */
  prepared: CurrencyTotals;
  /** Authorised but not yet released: committed cash. */
  approved: CurrencyTotals;
  /** Already out of the door. */
  paid: CurrencyTotals;
}

/**
 * What is waiting, by stage, per currency. Cancelled and declined are left out
 * because they are not money anybody is going to pay.
 */
export function paymentQueueTotals(payments: readonly AgentPayment[]): PaymentQueueTotals {
  const t: PaymentQueueTotals = { prepared: {}, approved: {}, paid: {} };
  for (const p of payments) {
    if (p.status === 'prepared') addTo(t.prepared, p.currency, p.net_amount);
    if (p.status === 'approved') addTo(t.approved, p.currency, p.net_amount);
    if (p.status === 'paid') addTo(t.paid, p.currency, p.net_amount);
  }
  return t;
}

/**
 * Oldest open item first.
 *
 * A queue is worked from the top, and the thing that has been waiting longest is
 * the thing somebody is chasing. Settled rows sink to the bottom however recent
 * they are, because "paid yesterday" is history, not work.
 */
export const sortPayments = (payments: readonly AgentPayment[]): AgentPayment[] =>
  [...payments].sort((x, y) => {
    const ax = isActionable(x) ? 0 : 1;
    const ay = isActionable(y) ? 0 : 1;
    return ax - ay || x.prepared_at.localeCompare(y.prepared_at) || x.id.localeCompare(y.id);
  });

/**
 * The figure the approver is being asked to accept, in words. The withholding and
 * its character travel with the number, because approving a net without knowing
 * whether the tax was final is approving something you cannot describe afterwards.
 */
export function paymentSummary(
  p: Pick<AgentPayment, 'gross_amount' | 'wht_amount' | 'net_amount' | 'wht_rate_pct' | 'wht_is_final' | 'currency'>,
): string {
  const money = (n: number) => new Intl.NumberFormat('en-UG', {
    style: 'currency', currency: p.currency, maximumFractionDigits: 2,
  }).format(n);
  if (p.wht_amount <= 0) return `${money(p.net_amount)}, with nothing withheld`;
  const rate = p.wht_rate_pct === null ? 'the approved rate' : `${p.wht_rate_pct}%`;
  const character = p.wht_is_final === true
    ? 'a final tax'
    : p.wht_is_final === false
      ? 'a payment on account the agent still declares'
      : 'withheld';
  return `${money(p.gross_amount)} less ${money(p.wht_amount)} at ${rate} (${character}) = ${money(p.net_amount)}`;
}

// ---------------------------------------------------------------------------
// WHT remittances (ins_wht_remittances)
// ---------------------------------------------------------------------------
// The tax withheld from agents is not the brokerage's money. It sits as a liability
// until it goes to URA on a period return. Everything here is display: the position
// figures and the return amounts come from ins_wht_position() and the remittance RPCs,
// which are the only places that decide what is owed.

export type WhtRemittanceStatus = 'prepared' | 'approved' | 'paid' | 'void';

export const WHT_REMITTANCE_STATUS_LABEL: Record<WhtRemittanceStatus, string> = {
  prepared: 'Prepared, waiting for a second approver',
  approved: 'Approved, not yet paid to URA',
  paid: 'Paid to URA',
  void: 'Voided',
};

export interface WhtRemittance {
  id: string;
  remittance_no: string;
  /** The period the tax was withheld IN, not the month it is paid. */
  period_start: string;
  period_end: string;
  currency: string;
  amount: number;
  status: WhtRemittanceStatus;
  paid_on: string | null;
  payment_reference: string | null;
  prepared_by?: string | null;
  approved_by?: string | null;
  approved_at?: string | null;
  created_at?: string;
}

/** What ins_wht_position() returns. Amounts are not per currency: the RPC does not split them yet. */
export interface WhtPosition {
  withheld_total: number;
  reported_total: number;
  paid_total: number;
  /** Withheld and not on any return at all. The number the accountant chases. */
  unreported: number;
  /** On a return but not yet paid over. */
  awaiting_payment: number;
  /** Unreported with the sign removed: the figure to show when the backlog is real. */
  unreported_open?: number;
  /** Tax on a return that is no longer withheld. */
  over_reported?: number;
  /** The same figures split by currency. Absent from an older server. */
  by_currency?: WhtCurrencyLine[];
  remittances: Pick<WhtRemittance, 'remittance_no' | 'period_start' | 'period_end' | 'currency' | 'amount' | 'status' | 'paid_on'>[];
}

/**
 * The position with over-reported tax taken out of the unreported figure.
 *
 * A return can cover tax that was later reversed out of the withheld total -- the
 * return stays as filed, because a filed return is a fact about the past, but the
 * tax it claims is no longer withheld. The server reports the raw arithmetic, so
 * `unreported` can go negative. A negative "not yet reported" is not a smaller
 * backlog, it is an over-report that has to be resolved with URA, and saying so is
 * more useful than printing minus thirty thousand.
 */
/** One currency's worth of the position. */
export interface WhtCurrencyLine {
  currency: string;
  withheld_total: number;
  reported_total: number;
  paid_total: number;
  unreported: number;
  unreported_open: number;
  over_reported: number;
  awaiting_payment: number;
}

export interface WhtPositionView extends WhtPosition {
  /** Over-reported: tax on a return that is no longer withheld. Zero when there is none. */
  over_reported: number;
  /** Unreported, floored at zero, so the tile never shows a negative backlog. */
  unreported_clear: number;
}

export function whtPositionView(p: WhtPosition): WhtPositionView {
  const over = Math.max(0, Math.round((-p.unreported) * 100) / 100);
  return { ...p, over_reported: over, unreported_clear: Math.max(0, p.unreported) };
}

/**
 * The position split by currency, falling back to one line built from the flat
 * figures.
 *
 * The server answers properly now, but the flat fields are still in the response
 * and a tenant that works in one currency should never see a currency label just
 * because the function learned to split. Adding 500 USD to 900,000 UGX is the one
 * arithmetic this module refuses to do.
 */
export function whtCurrencyLines(p: WhtPosition): WhtCurrencyLine[] {
  if (p.by_currency && p.by_currency.length > 0) return p.by_currency;
  const over = Math.max(0, Math.round((-p.unreported) * 100) / 100);
  return [{
    currency: 'UGX',
    withheld_total: p.withheld_total,
    reported_total: p.reported_total,
    paid_total: p.paid_total,
    unreported: p.unreported,
    unreported_open: Math.max(0, p.unreported),
    over_reported: over,
    awaiting_payment: p.awaiting_payment,
  }];
}

/** A period return can be worked on until it is paid; voiding is how it stops. */
export const isOpenRemittance = (r: Pick<WhtRemittance, 'status'>): boolean =>
  r.status === 'prepared' || r.status === 'approved';

export function canApproveRemittance(
  r: Pick<WhtRemittance, 'status' | 'prepared_by'>,
  userId: string | null,
  canManage: boolean,
): boolean {
  return canManage && r.status === 'prepared' && userId !== null && r.prepared_by !== userId;
}

export function canPayRemittance(r: Pick<WhtRemittance, 'status'>, canManage: boolean): boolean {
  return canManage && r.status === 'approved';
}

export function canVoidRemittance(r: Pick<WhtRemittance, 'status'>, canManage: boolean): boolean {
  return canManage && isOpenRemittance(r);
}

export function remittanceBlockedReason(
  r: Pick<WhtRemittance, 'status' | 'prepared_by'>,
  userId: string | null,
  canManage: boolean,
): string | null {
  if (!canManage) return 'Only an insurance manager can approve a return.';
  if (r.status === 'paid') return 'This return has already been paid to URA.';
  if (r.status === 'approved') return 'Already approved; it is ready to pay.';
  if (r.status === 'void') return 'This return was voided.';
  if (userId !== null && r.prepared_by === userId) {
    return 'You prepared this return, so somebody else has to approve it.';
  }
  return null;
}

/**
 * Remittance rows, oldest period first.
 *
 * A tax ledger is read forwards: you are looking for what has not been dealt with,
 * and that is at the beginning of the year, not the end. Open returns come before
 * settled ones for the same reason as the payment queue -- the work first.
 */
export const sortRemittances = (rows: readonly WhtRemittance[]): WhtRemittance[] =>
  [...rows].sort((x, y) => {
    const ax = isOpenRemittance(x) ? 0 : 1;
    const ay = isOpenRemittance(y) ? 0 : 1;
    return ax - ay || x.period_start.localeCompare(y.period_start) || x.remittance_no.localeCompare(y.remittance_no);
  });

/**
 * The first day of the month a date falls in, as YYYY-MM-DD.
 *
 * The tab defaults to the month just ended, because a return is filed for a period
 * that has closed. Computed from parts rather than by subtracting days, so the
 * answer does not depend on the local timezone or the length of the month.
 */
export function monthBounds(reference: Date): { start: string; end: string; label: string } {
  const y = reference.getFullYear();
  const m = reference.getMonth();
  const pad = (n: number) => String(n).padStart(2, '0');
  const lastDay = new Date(y, m + 1, 0).getDate();
  return {
    start: `${y}-${pad(m + 1)}-01`,
    end: `${y}-${pad(m + 1)}-${pad(lastDay)}`,
    label: reference.toLocaleString('en-GB', { month: 'long', year: 'numeric' }),
  };
}

/** The month before the one a date falls in. */
export const previousMonth = (reference: Date): Date =>
  new Date(reference.getFullYear(), reference.getMonth() - 1, 1);

/**
 * Whether a return's period is in the past.
 *
 * A return for the current month is prepared against figures that can still move --
 * a share paid on the 28th belongs on it. Saying so is not a prohibition, it is the
 * difference between filing a period and guessing at one.
 */
export const periodIsClosed = (periodEnd: string, today: Date): boolean => {
  const pad = (n: number) => String(n).padStart(2, '0');
  const t = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
  return periodEnd < t;
};

/** What to warn about before preparing a return, or null when there is nothing to say. */
export function prepareWarning(periodEnd: string, today: Date): string | null {
  return periodIsClosed(periodEnd, today)
    ? null
    : 'This period has not finished yet. Anything withheld after today will go on a later return, so the figure is not final.';
}

export interface WhtLineRef {
  accrual_id: string;
  amount: number;
  remittance_id: string;
}

/**
 * Tax still held, as opposed to tax ever withheld.
 *
 * The Overview used to show every shilling ever withheld as a liability, which
 * kept growing after the money had gone to URA and made the tile useless as a
 * measure of anything. What the brokerage actually owes is withheld tax that has
 * not been paid over yet; tax on a PAID return belongs to the revenue authority
 * and is no longer a liability of ours.
 *
 * A line on a prepared or approved return still counts: the money has not moved,
 * and a return waiting for a signature is exactly the kind of thing that gets
 * forgotten. Only payment clears it.
 */
export function whtStillHeld(
  accruals: readonly AgentAccrual[],
  lines: readonly WhtLineRef[],
  remittances: readonly Pick<WhtRemittance, 'id' | 'status'>[],
): CurrencyTotals {
  const paidReturn = new Set(remittances.filter((r) => r.status === 'paid').map((r) => r.id));
  const settled = new Set(lines.filter((l) => paidReturn.has(l.remittance_id)).map((l) => l.accrual_id));
  const held: CurrencyTotals = {};
  for (const a of accruals) {
    if (a.status === 'reversed' || a.wht_amount <= 0) continue;
    if (settled.has(a.id)) continue;
    addTo(held, a.currency, a.wht_amount);
  }
  return held;
}

// ---------------------------------------------------------------------------
// Manual accrual (item 6, bit 7)
// ---------------------------------------------------------------------------
// A manager may ask for a share to be accrued, and the server decides whether it
// is allowed. Nothing here computes a share: the figure shown in the dialog comes
// back from ins_agent_commission_blocked_reason(), which runs the same
// calculation the accrual will run. A preview that did its own arithmetic would
// eventually disagree with the ledger, and the disagreement would be found by an
// agent rather than by us.

export type AccrualBlockCode =
  | 'INS_AGENT_NO_AGENT'
  | 'INS_AGENT_INSURER_PAID'
  | 'INS_AGENT_UNKNOWN_CATEGORY'
  | 'INS_AGENT_ALREADY_ACCRUED'
  | 'INS_AGENT_NOT_RECOGNISED'
  | 'INS_AGENT_NOT_PAYABLE'
  | 'INS_AGENT_NOT_ACCRUABLE';

/** What each refusal means, in the manager's terms rather than the database's. */
export const ACCRUAL_BLOCK_LABEL: Record<AccrualBlockCode, string> = {
  INS_AGENT_NO_AGENT: 'No intermediary on this policy',
  INS_AGENT_INSURER_PAID: 'Paid by the insurer',
  INS_AGENT_UNKNOWN_CATEGORY: 'No commission treatment',
  INS_AGENT_ALREADY_ACCRUED: 'Already on the books',
  INS_AGENT_NOT_RECOGNISED: 'Commission not yet earned',
  INS_AGENT_NOT_PAYABLE: 'The agreement pays nothing',
  INS_AGENT_NOT_ACCRUABLE: 'Cannot be accrued',
};

export interface AccrualCheck {
  code: AccrualBlockCode | null;
  reason: string | null;
  intermediary_id?: string;
  name?: string;
  basis?: string;
  gross_amount?: number;
  currency?: string;
  recognition_mode?: string;
  accrual_id?: string;
  status?: string;
}

export interface AccrualPreviewLine {
  policy_id: string;
  policy_no: string | null;
  inception_date: string;
  currency: string;
  intermediary_id?: string;
  name?: string;
  basis?: string;
  gross_amount?: number;
}

export interface AccrualBlockedLine {
  policy_id: string;
  policy_no: string | null;
  inception_date: string;
  currency: string;
  code: AccrualBlockCode;
  reason: string;
}

export interface AccrualPreview {
  from: string;
  to: string;
  eligible: AccrualPreviewLine[];
  eligible_count: number;
  blocked: AccrualBlockedLine[];
  blocked_count: number;
  by_currency: { currency: string; count: number; gross_amount: number }[];
}

export interface AccrualRunResult {
  from: string;
  to: string;
  accrued: number;
  skipped: number;
  failed: number;
  failures: { policy_no: string | null; error: string }[];
  results: { policy_no: string | null; accrued: boolean; accrual_id?: string; gross_amount?: number; reason?: string; error?: string }[];
  blocked_before_run: number;
  by_currency: { currency: string; count: number; gross_amount: number }[];
}

/** Can this policy be accrued, and if not, why? `null` code means yes. */
export const accrualIsAllowed = (check: AccrualCheck | null): boolean => !check || check.code === null;

/**
 * The one sentence a manager reads. The server's reason wins because it knows
 * more than the code does; the label is only there so a reason that arrives
 * without context still has a heading.
 */
export const accrualRefusalText = (check: AccrualCheck | null): string => {
  if (!check || check.code === null) return '';
  const heading = ACCRUAL_BLOCK_LABEL[check.code] ?? 'Cannot be accrued';
  return check.reason ? `${heading}: ${check.reason}` : heading;
};

/**
 * Total a preview would post, per currency, never summed across currencies.
 * Formatted the same way the register formats money, so a figure in this sentence
 * and the same figure in the table cannot print differently.
 */
export const previewTotalsText = (preview: AccrualPreview | null): string => {
  if (!preview || preview.by_currency.length === 0) return 'nothing to accrue';
  return preview.by_currency
    .map((c) => {
      const money = new Intl.NumberFormat('en-UG', {
        style: 'currency', currency: c.currency, maximumFractionDigits: 2,
      }).format(c.gross_amount);
      return `${money} across ${c.count} ${c.count === 1 ? 'policy' : 'policies'}`;
    })
    .join(', ');
};

/**
 * The headline after a run. Says what happened rather than showing four numbers
 * to be interpreted: a run that accrued nothing and a run that failed everywhere
 * must not read the same.
 */
export const runResultText = (run: AccrualRunResult): string => {
  if (run.failed > 0) {
    return `Accrued ${run.accrued}, skipped ${run.skipped}, and ${run.failed} could not be accrued. Nothing is lost: fix the ${run.failed === 1 ? 'policy' : 'policies'} and run again.`;
  }
  if (run.accrued === 0) {
    return run.skipped > 0
      ? `Nothing new to accrue — ${run.skipped} ${run.skipped === 1 ? 'policy was' : 'policies were'} already on the books.`
      : 'Nothing to accrue in this period.';
  }
  return `Accrued ${run.accrued} ${run.accrued === 1 ? 'share' : 'shares'}${run.skipped > 0 ? `, skipped ${run.skipped} already on the books` : ''}.`;
};

/** Default period for a run: the current month, as a manager would expect. */
export const monthPeriod = (today = new Date()): { from: string; to: string } => {
  const y = today.getFullYear();
  const m = String(today.getMonth() + 1).padStart(2, '0');
  const last = new Date(y, today.getMonth() + 1, 0).getDate();
  return { from: `${y}-${m}-01`, to: `${y}-${m}-${String(last).padStart(2, '0')}` };
};

/** A run needs a period that exists. Returns null when the dates are unusable. */
export const periodProblem = (from: string, to: string): string | null => {
  if (!from || !to) return 'Choose both dates.';
  if (to < from) return 'The end of the period cannot be before its start.';
  return null;
};
