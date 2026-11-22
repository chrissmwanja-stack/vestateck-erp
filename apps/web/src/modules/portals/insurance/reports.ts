// Pure logic behind the statement screens. ins_client_statement hands the
// screen one row per written policy; these helpers do the balance ageing.
// Everything here is pure so the tests can be table-driven.
//
// The Production Book no longer lives here: it is consolidated on the authoritative
// server-side report (ins_report_production), computed by the Production Book
// screen -- see pages/reports/ProductionBook.tsx.

export interface StatementRow {
  policy_id: string;
  policy_no: string | null;
  client_id: string | null;
  client_name: string | null;
  currency: string | null;
  billed_amount: number | null;
  received_amount: number | null;
  balance_amount: number | null;
  bound_date: string | null;
  expiry_date: string | null;
  status: string | null;
}

/** Balance age buckets, counted from the date the premium was billed (bound). */
export type AgingBucket = 'current' | 'd30' | 'd60' | 'd90' | 'over90';

export const AGING_BUCKETS: AgingBucket[] = ['current', 'd30', 'd60', 'd90', 'over90'];

export const AGING_LABEL: Record<AgingBucket, string> = {
  current: 'Not yet due',
  d30: '1–30 days',
  d60: '31–60 days',
  d90: '61–90 days',
  over90: 'Over 90 days',
};

export function daysSince(date: string, asOf: string): number {
  return Math.floor((new Date(asOf).getTime() - new Date(date).getTime()) / 86400000);
}

export function agingBucket(boundDate: string | null, asOf: string): AgingBucket {
  if (!boundDate) return 'current';
  const age = daysSince(boundDate, asOf);
  if (age <= 30) return 'current';
  if (age <= 60) return 'd30';
  if (age <= 90) return 'd90';
  return 'over90';
}

export interface ClientAging {
  client: string;
  currency: string;
  buckets: Record<AgingBucket, number>;
  total: number;
}

/** Aged subsidiary balances: outstanding premium per client and bucket (per currency). */
export function agedBalances(rows: StatementRow[], asOf: string): ClientAging[] {
  const map = new Map<string, ClientAging>();
  for (const r of rows) {
    const balance = Number(r.balance_amount ?? 0);
    if (balance <= 0) continue;
    const key = `${r.client_name ?? r.client_id ?? '-'}|${r.currency || 'UGX'}`;
    let a = map.get(key);
    if (!a) {
      a = { client: r.client_name ?? r.client_id ?? '-', currency: r.currency || 'UGX', buckets: { current: 0, d30: 0, d60: 0, d90: 0, over90: 0 }, total: 0 };
      map.set(key, a);
    }
    a.buckets[agingBucket(r.bound_date, asOf)] += balance;
    a.total += balance;
  }
  return Array.from(map.values()).sort((x, y) => y.total - x.total);
}
