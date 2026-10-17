// Totals and display rules for the general ledger's base-currency columns.
// The server stores base_debit and base_credit on every journal line. A
// functional-currency line has rate 1 and base equal to the transaction amount.

export interface LedgerAmountRow {
  debit: number | string | null;
  credit: number | string | null;
  base_debit?: number | string | null;
  base_credit?: number | string | null;
  fx_rate?: number | string | null;
}

/** Base columns are shown only when a row is not in the functional currency. For a
 *  company that posts only in its own currency they would repeat the columns beside them. */
export function hasForeignLines(rows: LedgerAmountRow[]): boolean {
  return rows.some((r) => r.fx_rate !== undefined && r.fx_rate !== null && Number(r.fx_rate) !== 1);
}

export function ledgerTotals(rows: LedgerAmountRow[]) {
  let debit = 0;
  let credit = 0;
  let baseDebit = 0;
  let baseCredit = 0;
  for (const r of rows) {
    debit += Number(r.debit ?? 0);
    credit += Number(r.credit ?? 0);
    // A row without base amounts (older data) falls back to its transaction amount.
    baseDebit += Number(r.base_debit ?? r.debit ?? 0);
    baseCredit += Number(r.base_credit ?? r.credit ?? 0);
  }
  return { debit, credit, baseDebit, baseCredit };
}
