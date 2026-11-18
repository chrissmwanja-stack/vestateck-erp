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
