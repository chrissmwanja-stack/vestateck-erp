// Pure logic behind the production reports. The views (ins_production_book,
// ins_client_statement) hand the screens one row per written policy; these
// helpers do the grouping, the currency-safe totals and the balance ageing.
// Everything here is a pure function so the tests can be table-driven.

export interface ProductionRow {
  policy_id: string;
  policy_no: string | null;
  client_id: string | null;
  client_name: string | null;
  insurer_id: string | null;
  insurer_name: string | null;
  product_line_id: string | null;
  product_line_name: string | null;
  branch_id: string | null;
  branch_name: string | null;
  agent_id: string | null;
  agent_name: string | null;
  transaction_type: string | null;
  status: string | null;
  bound_date: string | null;
  currency: string | null;
  gross_premium: number | null;
  commission_amount: number | null;
  net_premium_to_insurer: number | null;
}

export type ProductionGroupBy = 'client' | 'insurer' | 'branch' | 'agent' | 'product' | 'transaction_type' | 'status' | 'month';

const SHORT_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** '2026-09' -> 'Sep 2026', without touching Intl (test environments vary). */
export function shortMonth(month: string): string {
  const [y, m] = month.split('-');
  const idx = Number(m) - 1;
  return `${SHORT_MONTHS[idx] ?? m} ${y}`;
}

export const PRODUCTION_GROUPERS: Record<ProductionGroupBy, { label: string; of: (r: ProductionRow) => string }> = {
  client: { label: 'Client', of: (r) => r.client_name ?? r.client_id ?? '-' },
  insurer: { label: 'Insurer', of: (r) => r.insurer_name ?? r.insurer_id ?? '-' },
  branch: { label: 'Branch', of: (r) => r.branch_name ?? 'No branch' },
  agent: { label: 'Agent', of: (r) => r.agent_name ?? 'No agent' },
  product: { label: 'Product line', of: (r) => r.product_line_name ?? r.product_line_id ?? '-' },
  transaction_type: { label: 'Transaction type', of: (r) => r.transaction_type ?? '-' },
  status: { label: 'Status', of: (r) => r.status ?? '-' },
  month: { label: 'Month', of: (r) => (r.bound_date ?? '').slice(0, 7) || 'No date' },
};

export interface ProductionGroup {
  key: string;
  count: number;
  gross: Record<string, number>;
  commission: Record<string, number>;
  net: Record<string, number>;
}

/** Groups written policies and totals money per currency within each group. */
export function groupProduction(rows: ProductionRow[], groupBy: ProductionGroupBy): ProductionGroup[] {
  const grouper = PRODUCTION_GROUPERS[groupBy];
  const map = new Map<string, ProductionGroup>();
  for (const r of rows) {
    const key = grouper.of(r);
    let g = map.get(key);
    if (!g) {
      g = { key, count: 0, gross: {}, commission: {}, net: {} };
      map.set(key, g);
    }
    g.count += 1;
    addInto(g.gross, r.currency, r.gross_premium);
    addInto(g.commission, r.currency, r.commission_amount);
    addInto(g.net, r.currency, r.net_premium_to_insurer);
  }
  return Array.from(map.values()).sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));
}

function addInto(totals: Record<string, number>, currency: string | null, amount: number | null): void {
  const cur = currency || 'UGX';
  totals[cur] = (totals[cur] ?? 0) + Number(amount ?? 0);
}

export interface TrendMonth {
  /** 'YYYY-MM', ascending. */
  month: string;
  count: number;
  /** Gross written premium per currency -- currencies are never merged. */
  gross: Record<string, number>;
}

/** The premiums-written trend: gross written premium per month, per currency, oldest first. */
export function premiumTrend(rows: ProductionRow[]): TrendMonth[] {
  const map = new Map<string, TrendMonth>();
  for (const r of rows) {
    const month = (r.bound_date ?? '').slice(0, 7);
    if (!month) continue;
    let t = map.get(month);
    if (!t) {
      t = { month, count: 0, gross: {} };
      map.set(month, t);
    }
    t.count += 1;
    addInto(t.gross, r.currency, r.gross_premium);
  }
  return Array.from(map.values()).sort((a, b) => a.month.localeCompare(b.month));
}

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
