import type { ReportExportColumn } from '../../../lib/reportExport';

// Types, labels and export columns for the server-side management reports
// (ins_report_production, ins_report_premium_collected, ins_report_outstanding_premium).
// The figures come from the ledger; nothing here adds a total that the server did not return.

export type ReportGroupBy = 'month' | 'client' | 'product_line' | 'branch' | 'agent';

export const REPORT_GROUPS: { value: ReportGroupBy; label: string }[] = [
  { value: 'month', label: 'Month' },
  { value: 'client', label: 'Client' },
  { value: 'product_line', label: 'Product line' },
  { value: 'branch', label: 'Branch' },
  { value: 'agent', label: 'Agent' },
];

export const groupLabel = (g: ReportGroupBy): string => REPORT_GROUPS.find((x) => x.value === g)?.label ?? g;

export function monthStartIso(now: Date = new Date()): string {
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-01`;
}

export interface ProductionLine {
  group_key: string;
  group_label: string;
  currency: string;
  new_business: number;
  endorsements: number;
  cancellations: number;
  reversals: number;
  net_written: number;
  policy_count: number;
}

export interface CollectedLine {
  group_key: string;
  group_label: string;
  currency: string;
  collected: number;
  receipt_count: number;
}

export const AGE_BUCKETS = ['current', '1-30', '31-60', '61-90', '90+'] as const;
export type AgeBucket = (typeof AGE_BUCKETS)[number];

export const AGE_BUCKET_LABEL: Record<AgeBucket, string> = {
  current: 'Not yet due',
  '1-30': '1-30 days',
  '31-60': '31-60 days',
  '61-90': '61-90 days',
  '90+': 'Over 90 days',
};

export interface OutstandingLine {
  open_item_id: string;
  policy_id: string;
  policy_no: string;
  client_id: string;
  client_name: string | null;
  currency: string;
  document_no: string;
  document_date: string;
  due_date: string | null;
  billed: number;
  received: number;
  credited: number;
  outstanding: number;
  days_overdue: number;
  age_bucket: AgeBucket;
}

export const productionColumns = (groupHeader: string): ReportExportColumn<ProductionLine>[] => [
  { header: groupHeader, accessor: (r) => r.group_label },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'New business', accessor: (r) => Number(r.new_business), align: 'right' },
  { header: 'Endorsements', accessor: (r) => Number(r.endorsements), align: 'right' },
  { header: 'Cancellations', accessor: (r) => Number(r.cancellations), align: 'right' },
  { header: 'Reversals', accessor: (r) => Number(r.reversals), align: 'right' },
  { header: 'Net written', accessor: (r) => Number(r.net_written), align: 'right' },
  { header: 'Policies', accessor: (r) => Number(r.policy_count), align: 'right' },
];

export const collectedColumns = (groupHeader: string): ReportExportColumn<CollectedLine>[] => [
  { header: groupHeader, accessor: (r) => r.group_label },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Collected', accessor: (r) => Number(r.collected), align: 'right' },
  { header: 'Receipts', accessor: (r) => Number(r.receipt_count), align: 'right' },
];

export const OUTSTANDING_COLUMNS: ReportExportColumn<OutstandingLine>[] = [
  { header: 'Policy', accessor: (r) => r.policy_no },
  { header: 'Client', accessor: (r) => r.client_name ?? '-' },
  { header: 'Document', accessor: (r) => r.document_no },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Billed', accessor: (r) => Number(r.billed), align: 'right' },
  { header: 'Received', accessor: (r) => Number(r.received), align: 'right' },
  { header: 'Credited', accessor: (r) => Number(r.credited), align: 'right' },
  { header: 'Outstanding', accessor: (r) => Number(r.outstanding), align: 'right' },
  { header: 'Due', accessor: (r) => r.due_date ?? r.document_date },
  { header: 'Days overdue', accessor: (r) => Number(r.days_overdue), align: 'right' },
  { header: 'Age', accessor: (r) => AGE_BUCKET_LABEL[r.age_bucket] ?? r.age_bucket },
];
