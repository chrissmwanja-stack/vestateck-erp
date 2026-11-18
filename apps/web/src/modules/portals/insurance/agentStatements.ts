// ---------------------------------------------------------------------------
// Agent commission statements
// ---------------------------------------------------------------------------
// What one intermediary earned, what was withheld, and what has been paid. The
// figures come from ins_agent_commission_statement(); nothing here recalculates
// money, and the per-currency block is the answer rather than the flat totals,
// which add unlike currencies together.

import type { CurrencyTotals } from './agentCommission';

export interface AgentStatementLine {
  accrual_id: string;
  policy_no: string | null;
  currency: string;
  accrued_on: string;
  paid_on: string | null;
  /** The date this line is reported under: the payment date, else the accrual date. */
  statement_date: string;
  basis: string;
  gross_amount: number;
  wht_rate_pct: number | null;
  wht_amount: number;
  wht_is_final: boolean | null;
  net_amount: number | null;
  status: string;
}

export interface AgentStatementCurrency {
  currency: string;
  gross_commission: number;
  wht_withheld: number;
  net_commission: number;
  paid: number;
  outstanding: number;
  lines: number;
}

export interface AgentStatement {
  intermediary_id: string;
  name: string;
  category: string;
  from: string | null;
  to: string | null;
  gross_commission: number;
  wht_withheld: number;
  net_commission: number;
  paid: number;
  outstanding: number;
  by_currency: AgentStatementCurrency[];
  lines: AgentStatementLine[];
}

/** The net a line pays: the stored net, else gross less tax. */
export const statementLineNet = (l: Pick<AgentStatementLine, 'gross_amount' | 'wht_amount' | 'net_amount'>): number =>
  l.net_amount ?? Math.round((l.gross_amount - l.wht_amount) * 100) / 100;

/**
 * The currency blocks, falling back to one built from the flat figures.
 *
 * The server splits properly now. The fallback exists because the flat fields are
 * still in the response for older callers, and because a single-currency agent
 * should never be shown a currency label merely because the function learned to
 * split: two currencies and one currency are different questions.
 */
export function statementCurrencies(s: AgentStatement): AgentStatementCurrency[] {
  if (s.by_currency && s.by_currency.length > 0) return s.by_currency;
  return [{
    currency: 'UGX',
    gross_commission: s.gross_commission,
    wht_withheld: s.wht_withheld,
    net_commission: s.net_commission,
    paid: s.paid,
    outstanding: s.outstanding,
    lines: s.lines.length,
  }];
}

/** Totals per currency for the lines a statement carries, for the table footer. */
export function lineTotals(lines: readonly AgentStatementLine[]): CurrencyTotals {
  const out: CurrencyTotals = {};
  for (const l of lines) {
    out[l.currency] = Math.round(((out[l.currency] ?? 0) + statementLineNet(l)) * 100) / 100;
  }
  return out;
}

/**
 * A period preset, as explicit dates.
 *
 * The statement's window runs on the PAYMENT date, so "this month" means the
 * month being invoiced, not the month the paperwork was typed. Presets are built
 * from parts so the answer does not depend on the local timezone.
 */
export type StatementPeriod = 'this_month' | 'last_month' | 'this_quarter' | 'this_year' | 'all';

export const STATEMENT_PERIOD_LABEL: Record<StatementPeriod, string> = {
  this_month: 'This month',
  last_month: 'Last month',
  this_quarter: 'This quarter',
  this_year: 'This year',
  all: 'All time',
};

const ymd = (d: Date): string => {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};

export function statementPeriodBounds(period: StatementPeriod, today: Date): { from: string | null; to: string | null } {
  const y = today.getFullYear();
  const m = today.getMonth();
  switch (period) {
    case 'this_month':
      return { from: ymd(new Date(y, m, 1)), to: ymd(new Date(y, m + 1, 0)) };
    case 'last_month':
      return { from: ymd(new Date(y, m - 1, 1)), to: ymd(new Date(y, m, 0)) };
    case 'this_quarter': {
      const q = Math.floor(m / 3) * 3;
      return { from: ymd(new Date(y, q, 1)), to: ymd(new Date(y, q + 3, 0)) };
    }
    case 'this_year':
      return { from: ymd(new Date(y, 0, 1)), to: ymd(new Date(y, 11, 31)) };
    case 'all':
      return { from: null, to: null };
  }
}

/** The window in words, for the header of a printed statement. */
export function statementPeriodLabel(s: Pick<AgentStatement, 'from' | 'to'>): string {
  const fmt = (d: string) => new Date(`${d}T00:00:00`).toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
  if (!s.from && !s.to) return 'All time';
  if (s.from && !s.to) return `From ${fmt(s.from)}`;
  if (!s.from && s.to) return `To ${fmt(s.to)}`;
  return `${fmt(s.from as string)} to ${fmt(s.to as string)}`;
}

/**
 * One sentence about the withholding on a statement, in the agent's terms.
 *
 * The distinction matters to the person reading it: final tax is money they will
 * never see again, on-account tax is money they still have to declare. Saying
 * "withheld" for both is the kind of vagueness that gets a brokerage a phone call
 * it cannot answer.
 */
export function statementWithholdingSentence(s: AgentStatement): string {
  const lines = s.lines.filter((l) => l.wht_amount > 0);
  if (lines.length === 0) {
    return 'No tax was withheld on this statement: withholding is taken when a share is paid, and no paid share in this period carried any.';
  }
  const total = lines.reduce((sum, l) => sum + l.wht_amount, 0);
  const finals = lines.filter((l) => l.wht_is_final === true);
  const onAccount = lines.filter((l) => l.wht_is_final === false);
  if (finals.length === 0 && onAccount.length > 0) {
    return `${lines.length === 1 ? 'One share carried' : `${onAccount.length} shares carried`} withholding that is a payment on account: the agent still declares this income.`;
  }
  if (onAccount.length === 0 && finals.length > 0) {
    return `Tax withheld here is a final tax: it is not declared again by the agent.`;
  }
  return `Tax is withheld at ${lines[0].wht_rate_pct ?? 'the approved rate'}% and mixes final and on-account amounts; where the character is on account, the agent still declares the income. (Total withheld ${total.toFixed(2)}.)`;
}
