import type { ReportExportColumn } from '../../../lib/reportExport';
import { daysBetween } from './logic';

// The unremitted-premium report (ins_unremitted_premium_report). The deadline comes from
// the approved rule remittance.deadline_working_days. With no approved rule there is no
// deadline and the status is deadline_not_set: no default is ever assumed.

export type RemittanceStatus = 'overdue' | 'due_today' | 'within_deadline' | 'deadline_not_set' | 'receipt_date_missing';

export interface RemittanceRow {
  policy_id: string;
  policy_no: string;
  insurer_id: string;
  unremitted_amount: number | string;
  receipt_date: string | null;
  deadline_date: string | null;
  status: RemittanceStatus;
}

export const REMITTANCE_STATUS_LABEL: Record<RemittanceStatus, string> = {
  overdue: 'Overdue',
  due_today: 'Due today',
  within_deadline: 'Within deadline',
  deadline_not_set: 'No deadline set',
  receipt_date_missing: 'Receipt date missing',
};

/** Most urgent first. */
export const REMITTANCE_STATUS_ORDER: RemittanceStatus[] = ['overdue', 'due_today', 'receipt_date_missing', 'deadline_not_set', 'within_deadline'];

export interface RemittanceFacts {
  overdue: number;
  dueToday: number;
  deadlineNotSet: number;
  receiptMissing: number;
}

export function remittanceFacts(rows: Pick<RemittanceRow, 'status'>[]): RemittanceFacts {
  const count = (s: RemittanceStatus) => rows.filter((r) => r.status === s).length;
  return { overdue: count('overdue'), dueToday: count('due_today'), deadlineNotSet: count('deadline_not_set'), receiptMissing: count('receipt_date_missing') };
}

/** Whole days past the deadline as of the report date, or 0 when it is not late. */
export function daysPastDeadline(deadline: string | null, asOf: string): number {
  if (!deadline) return 0;
  return Math.max(0, daysBetween(deadline, asOf));
}

export function sortRemittanceRows<T extends Pick<RemittanceRow, 'status' | 'deadline_date' | 'policy_no'>>(rows: T[]): T[] {
  return [...rows].sort(
    (a, b) =>
      REMITTANCE_STATUS_ORDER.indexOf(a.status) - REMITTANCE_STATUS_ORDER.indexOf(b.status) ||
      (a.deadline_date ?? '9999-12-31').localeCompare(b.deadline_date ?? '9999-12-31') ||
      a.policy_no.localeCompare(b.policy_no),
  );
}

/** Splits a list into groups of at most `size`, so a lookup by id stays within the request length limit. */
export function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

/** One line of the exported report: the same facts the screen shows, with the amount as a plain number. */
export interface RemittanceExportRow {
  policy_no: string;
  client: string;
  insurer: string;
  currency: string;
  amount: number;
  receipt_date: string;
  deadline_date: string;
  status: string;
  days_late: number;
}

export const REMITTANCE_EXPORT_COLUMNS: ReportExportColumn<RemittanceExportRow>[] = [
  { header: 'Policy', accessor: (r) => r.policy_no },
  { header: 'Client', accessor: (r) => r.client },
  { header: 'Insurer', accessor: (r) => r.insurer },
  { header: 'Currency', accessor: (r) => r.currency },
  // Formatted with grouping so the PDF is readable; the Excel export turns it back into a number.
  { header: 'Held, not remitted', align: 'right', accessor: (r) => r.amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) },
  { header: 'Received', accessor: (r) => r.receipt_date },
  { header: 'Deadline', accessor: (r) => r.deadline_date },
  { header: 'Status', accessor: (r) => r.status },
  { header: 'Days late', align: 'right', accessor: (r) => r.days_late },
];

/** The rows to export, in the order and with the filters the screen shows. Money is never mixed across currencies. */
export function remittanceExportRows(
  rows: RemittanceRow[],
  asOf: string,
  lookup: { client: (r: RemittanceRow) => string; insurer: (r: RemittanceRow) => string; currency: (r: RemittanceRow) => string },
): RemittanceExportRow[] {
  return rows.map((r) => ({
    policy_no: r.policy_no,
    client: lookup.client(r),
    insurer: lookup.insurer(r),
    currency: lookup.currency(r),
    amount: Number(r.unremitted_amount),
    receipt_date: r.receipt_date ?? '',
    deadline_date: r.deadline_date ?? '',
    status: REMITTANCE_STATUS_LABEL[r.status],
    days_late: r.status === 'overdue' ? daysPastDeadline(r.deadline_date, asOf) : 0,
  }));
}
