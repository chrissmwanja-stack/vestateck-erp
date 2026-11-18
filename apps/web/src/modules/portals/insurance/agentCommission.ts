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
