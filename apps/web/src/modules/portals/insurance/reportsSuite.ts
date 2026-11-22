import { businessMonthStart } from '../../../lib/businessDate';
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

export const monthStartIso = (now: Date = new Date()): string => businessMonthStart(now);

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

// ---- Batch 2: commission earned (period) and commission receivable (as at) ----

export interface CommissionEarnedLine {
  group_key: string;
  group_label: string;
  currency: string;
  placement: number;
  recognised: number;
  reversed: number;
  cancellations: number;
  endorsements: number;
  other: number;
  net_earned: number;
  policy_count: number;
}

export interface CommissionReceivableLine {
  open_item_id: string;
  policy_id: string;
  policy_no: string;
  insurer_id: string | null;
  insurer_name: string | null;
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

export const commissionEarnedColumns = (groupHeader: string): ReportExportColumn<CommissionEarnedLine>[] => [
  { header: groupHeader, accessor: (r) => r.group_label },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'At placement', accessor: (r) => Number(r.placement), align: 'right' },
  { header: 'On settlement or collection', accessor: (r) => Number(r.recognised), align: 'right' },
  { header: 'Reversed', accessor: (r) => Number(r.reversed), align: 'right' },
  { header: 'Cancellations', accessor: (r) => Number(r.cancellations), align: 'right' },
  { header: 'Endorsements', accessor: (r) => Number(r.endorsements), align: 'right' },
  { header: 'Other', accessor: (r) => Number(r.other), align: 'right' },
  { header: 'Net earned', accessor: (r) => Number(r.net_earned), align: 'right' },
  { header: 'Policies', accessor: (r) => Number(r.policy_count), align: 'right' },
];

export const COMMISSION_RECEIVABLE_COLUMNS: ReportExportColumn<CommissionReceivableLine>[] = [
  { header: 'Insurer', accessor: (r) => r.insurer_name ?? '-' },
  { header: 'Policy', accessor: (r) => r.policy_no },
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

// ---- Batch 3: claims register and claims ageing (as at a date) ----

export const CLAIM_AGE_BUCKETS = ['0-30', '31-60', '61-90', '91-180', '180+'] as const;
export type ClaimAgeBucket = (typeof CLAIM_AGE_BUCKETS)[number];
export type ClaimBucket = ClaimAgeBucket | 'closed';

export const CLAIM_AGE_BUCKET_LABEL: Record<ClaimBucket, string> = {
  '0-30': '0-30 days',
  '31-60': '31-60 days',
  '61-90': '61-90 days',
  '91-180': '91-180 days',
  '180+': 'Over 180 days',
  closed: 'Closed',
};

export const CLAIM_STATUS_LABEL: Record<string, string> = {
  notified: 'Notified',
  assessing: 'Assessing',
  approved: 'Approved',
  settled: 'Settled',
  repudiated: 'Repudiated',
  closed: 'Closed',
};

export type ClaimsScope = 'open' | 'all';
export type ClaimsGroupBy = 'none' | 'insurer' | 'product_line';

export const CLAIMS_GROUPS: { value: ClaimsGroupBy; label: string }[] = [
  { value: 'none', label: 'None' },
  { value: 'insurer', label: 'Insurer' },
  { value: 'product_line', label: 'Product line' },
];

export interface ClaimRegisterLine {
  claim_id: string;
  claim_no: string;
  insurer_claim_ref: string | null;
  policy_id: string;
  policy_no: string;
  client_id: string | null;
  client_name: string | null;
  insurer_id: string | null;
  insurer_name: string | null;
  product_line_id: string | null;
  product_line_name: string | null;
  currency: string;
  loss_date: string;
  notified_date: string;
  status_as_at: string;
  is_open: boolean;
  reserve_as_at: number;
  approved_amount: number | null;
  paid_as_at: number;
  outstanding_amount: number;
  age_days: number;
  days_since_activity: number;
  age_bucket: ClaimBucket;
}

export interface ClaimAgeingLine {
  group_key: string;
  group_label: string;
  currency: string;
  age_bucket: ClaimAgeBucket;
  claim_count: number;
  reserve_total: number;
  outstanding_total: number;
  oldest_age_days: number;
}

export const CLAIMS_REGISTER_COLUMNS: ReportExportColumn<ClaimRegisterLine>[] = [
  { header: 'Claim', accessor: (r) => r.claim_no },
  { header: 'Insurer ref', accessor: (r) => r.insurer_claim_ref ?? '' },
  { header: 'Policy', accessor: (r) => r.policy_no },
  { header: 'Client', accessor: (r) => r.client_name ?? '-' },
  { header: 'Insurer', accessor: (r) => r.insurer_name ?? '-' },
  { header: 'Product line', accessor: (r) => r.product_line_name ?? '-' },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Loss date', accessor: (r) => r.loss_date },
  { header: 'Notified', accessor: (r) => r.notified_date },
  { header: 'Status', accessor: (r) => CLAIM_STATUS_LABEL[r.status_as_at] ?? r.status_as_at },
  { header: 'Reserve', accessor: (r) => Number(r.reserve_as_at), align: 'right' },
  { header: 'Approved', accessor: (r) => (r.approved_amount == null ? '' : Number(r.approved_amount)), align: 'right' },
  { header: 'Paid', accessor: (r) => Number(r.paid_as_at), align: 'right' },
  { header: 'Outstanding', accessor: (r) => Number(r.outstanding_amount), align: 'right' },
  { header: 'Age (days)', accessor: (r) => Number(r.age_days), align: 'right' },
  { header: 'Days since activity', accessor: (r) => Number(r.days_since_activity), align: 'right' },
];

export const claimsAgeingColumns = (groupHeader: string): ReportExportColumn<ClaimAgeingLine>[] => [
  { header: groupHeader, accessor: (r) => r.group_label },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Age', accessor: (r) => CLAIM_AGE_BUCKET_LABEL[r.age_bucket] ?? r.age_bucket },
  { header: 'Claims', accessor: (r) => Number(r.claim_count), align: 'right' },
  { header: 'Reserve', accessor: (r) => Number(r.reserve_total), align: 'right' },
  { header: 'Outstanding', accessor: (r) => Number(r.outstanding_total), align: 'right' },
  { header: 'Oldest (days)', accessor: (r) => Number(r.oldest_age_days), align: 'right' },
];

// ---- Batch 4: cancellations (period) ----

export type CancellationGroupBy = ReportGroupBy | 'insurer';

export const CANCELLATION_GROUPS: { value: CancellationGroupBy; label: string }[] = [
  ...REPORT_GROUPS,
  { value: 'insurer', label: 'Insurer' },
];

export const cancellationGroupLabel = (g: CancellationGroupBy): string =>
  CANCELLATION_GROUPS.find((x) => x.value === g)?.label ?? g;

export interface CancellationLine {
  group_key: string;
  group_label: string;
  currency: string;
  cancellation_count: number;
  return_premium: number;
  commission_clawback: number;
  retained_commission: number;
  total_insurer_credit: number;
}

export const cancellationColumns = (groupHeader: string): ReportExportColumn<CancellationLine>[] => [
  { header: groupHeader, accessor: (r) => r.group_label },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Cancellations', accessor: (r) => Number(r.cancellation_count), align: 'right' },
  { header: 'Return premium', accessor: (r) => Number(r.return_premium), align: 'right' },
  { header: 'Commission clawed back', accessor: (r) => Number(r.commission_clawback), align: 'right' },
  { header: 'Commission retained', accessor: (r) => Number(r.retained_commission), align: 'right' },
  { header: 'Insurer credit', accessor: (r) => Number(r.total_insurer_credit), align: 'right' },
];

// ---- Batch 4: cancellation register, renewals and renewal retention ----

export interface CancellationRegisterLine {
  cancellation_id: string;
  cancellation_no: string;
  policy_id: string;
  policy_no: string;
  client_name: string | null;
  insurer_name: string | null;
  product_line_name: string | null;
  currency: string;
  reason: string | null;
  effective_date: string;
  posting_date: string;
  return_premium: number;
  commission_clawback: number;
  retained_commission: number;
  total_insurer_credit: number;
}

export const CANCELLATION_REGISTER_COLUMNS: ReportExportColumn<CancellationRegisterLine>[] = [
  { header: 'Cancellation', accessor: (r) => r.cancellation_no },
  { header: 'Policy', accessor: (r) => r.policy_no },
  { header: 'Client', accessor: (r) => r.client_name ?? '-' },
  { header: 'Insurer', accessor: (r) => r.insurer_name ?? '-' },
  { header: 'Product line', accessor: (r) => r.product_line_name ?? '-' },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Reason', accessor: (r) => r.reason ?? '' },
  { header: 'Effective', accessor: (r) => r.effective_date },
  { header: 'Posted', accessor: (r) => r.posting_date },
  { header: 'Return premium', accessor: (r) => Number(r.return_premium), align: 'right' },
  { header: 'Commission clawed back', accessor: (r) => Number(r.commission_clawback), align: 'right' },
  { header: 'Commission retained', accessor: (r) => Number(r.retained_commission), align: 'right' },
  { header: 'Insurer credit', accessor: (r) => Number(r.total_insurer_credit), align: 'right' },
];

export type RenewalOutcome = 'renewed' | 'lost' | 'declined' | 'lapsed' | 'upcoming' | 'unresolved';

export const RENEWAL_OUTCOMES: RenewalOutcome[] = ['renewed', 'upcoming', 'unresolved', 'lost', 'declined', 'lapsed'];

export const RENEWAL_OUTCOME_LABEL: Record<RenewalOutcome, string> = {
  renewed: 'Renewed',
  upcoming: 'Upcoming',
  unresolved: 'Not resolved',
  lost: 'Lost',
  declined: 'Declined',
  lapsed: 'Lapsed',
};

export interface RenewalLine {
  policy_id: string;
  policy_no: string;
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
  currency: string;
  expiry_date: string;
  days_to_expiry: number;
  expiring_premium: number;
  outcome: RenewalOutcome;
  outcome_reason: string | null;
  renewal_policy_id: string | null;
  renewal_policy_no: string | null;
  renewal_premium: number | null;
}

export const RENEWALS_COLUMNS: ReportExportColumn<RenewalLine>[] = [
  { header: 'Policy', accessor: (r) => r.policy_no },
  { header: 'Client', accessor: (r) => r.client_name ?? '-' },
  { header: 'Insurer', accessor: (r) => r.insurer_name ?? '-' },
  { header: 'Product line', accessor: (r) => r.product_line_name ?? '-' },
  { header: 'Branch', accessor: (r) => r.branch_name ?? '-' },
  { header: 'Agent', accessor: (r) => r.agent_name ?? '-' },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Expiry', accessor: (r) => r.expiry_date },
  { header: 'Days to expiry', accessor: (r) => Number(r.days_to_expiry), align: 'right' },
  { header: 'Expiring premium', accessor: (r) => Number(r.expiring_premium), align: 'right' },
  { header: 'Outcome', accessor: (r) => RENEWAL_OUTCOME_LABEL[r.outcome] ?? r.outcome },
  { header: 'Reason', accessor: (r) => r.outcome_reason ?? '' },
  { header: 'Renewal policy', accessor: (r) => r.renewal_policy_no ?? '' },
  { header: 'Renewal premium', accessor: (r) => (r.renewal_premium == null ? '' : Number(r.renewal_premium)), align: 'right' },
];

export interface RenewalRetentionLine {
  group_key: string;
  group_label: string;
  currency: string;
  due_count: number;
  renewed_count: number;
  lost_count: number;
  unresolved_count: number;
  upcoming_count: number;
  expiring_premium: number;
  renewed_premium: number;
  retention_count_pct: number | null;
  retention_premium_pct: number | null;
}

export const formatPct = (v: number | null | undefined): string => (v == null ? '-' : `${Number(v).toFixed(1)}%`);

export const renewalRetentionColumns = (groupHeader: string): ReportExportColumn<RenewalRetentionLine>[] => [
  { header: groupHeader, accessor: (r) => r.group_label },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Due', accessor: (r) => Number(r.due_count), align: 'right' },
  { header: 'Renewed', accessor: (r) => Number(r.renewed_count), align: 'right' },
  { header: 'Lost', accessor: (r) => Number(r.lost_count), align: 'right' },
  { header: 'Not resolved', accessor: (r) => Number(r.unresolved_count), align: 'right' },
  { header: 'Upcoming', accessor: (r) => Number(r.upcoming_count), align: 'right' },
  { header: 'Expiring premium', accessor: (r) => Number(r.expiring_premium), align: 'right' },
  { header: 'Renewed premium', accessor: (r) => Number(r.renewed_premium), align: 'right' },
  { header: 'Retention (count)', accessor: (r) => formatPct(r.retention_count_pct), align: 'right' },
  { header: 'Retention (premium)', accessor: (r) => formatPct(r.retention_premium_pct), align: 'right' },
];

// ---- Statutory charges: summary, trace and reconciliation exceptions ----

export type StatutoryGroupBy = 'charge' | 'insurer' | 'month' | 'client';

export const STATUTORY_GROUPS: { value: StatutoryGroupBy; label: string }[] = [
  { value: 'charge', label: 'Charge' },
  { value: 'insurer', label: 'Insurer' },
  { value: 'month', label: 'Month bound' },
  { value: 'client', label: 'Client' },
];

export const statutoryGroupLabel = (g: StatutoryGroupBy): string => STATUTORY_GROUPS.find((x) => x.value === g)?.label ?? g;

export interface StatutoryChargeLine {
  group_key: string;
  group_label: string;
  currency: string;
  policy_count: number;
  assessed: number;
  collected: number;
  uncollected: number;
  remitted: number;
  held_unremitted: number;
  remitter: 'insurer' | 'brokerage' | 'mixed';
}

export const REMITTER_LABEL: Record<StatutoryChargeLine['remitter'], string> = {
  insurer: 'Insurer remits',
  brokerage: 'Brokerage remits',
  mixed: 'Mixed',
};

export const statutoryChargeColumns = (groupHeader: string): ReportExportColumn<StatutoryChargeLine>[] => [
  { header: groupHeader, accessor: (r) => r.group_label },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Policies', accessor: (r) => Number(r.policy_count), align: 'right' },
  { header: 'Assessed', accessor: (r) => Number(r.assessed), align: 'right' },
  { header: 'Collected (pro rata)', accessor: (r) => Number(r.collected), align: 'right' },
  { header: 'Not yet collected', accessor: (r) => Number(r.uncollected), align: 'right' },
  { header: 'Remitted to insurer (pro rata)', accessor: (r) => Number(r.remitted), align: 'right' },
  { header: 'Collected, not yet remitted', accessor: (r) => Number(r.held_unremitted), align: 'right' },
  { header: 'Remitted to authority by', accessor: (r) => REMITTER_LABEL[r.remitter] ?? r.remitter },
];

export type StatutoryStage = 'assessed' | 'collected' | 'remitted';

export const STATUTORY_STAGE_LABEL: Record<StatutoryStage, string> = {
  assessed: 'Assessed',
  collected: 'Collected',
  remitted: 'Remitted to insurer',
};

export interface StatutoryTraceLine {
  stage: StatutoryStage;
  cohort_month: string;
  policy_id: string;
  policy_no: string;
  client_name: string | null;
  policy_status: string;
  insurer_id: string;
  insurer_name: string | null;
  charge_id: string;
  charge_code: string;
  charge_name: string | null;
  charge_class: string | null;
  collector: string | null;
  recipient_name: string | null;
  payable_role: string | null;
  currency: string;
  event_date: string;
  settlement_id: string | null;
  settlement_no: string | null;
  amount: number;
  basis: string;
}

export const STATUTORY_TRACE_COLUMNS: ReportExportColumn<StatutoryTraceLine>[] = [
  { header: 'Stage', accessor: (r) => STATUTORY_STAGE_LABEL[r.stage] ?? r.stage },
  { header: 'Policy', accessor: (r) => r.policy_no },
  { header: 'Policy status', accessor: (r) => r.policy_status },
  { header: 'Client', accessor: (r) => r.client_name ?? '-' },
  { header: 'Insurer', accessor: (r) => r.insurer_name ?? '-' },
  { header: 'Charge', accessor: (r) => r.charge_code },
  { header: 'Recipient', accessor: (r) => r.recipient_name ?? '-' },
  { header: 'Collector', accessor: (r) => r.collector ?? '-' },
  { header: 'Currency', accessor: (r) => r.currency },
  { header: 'Date', accessor: (r) => r.event_date },
  { header: 'Settlement', accessor: (r) => r.settlement_no ?? '' },
  { header: 'Amount', accessor: (r) => Number(r.amount), align: 'right' },
  { header: 'Basis', accessor: (r) => r.basis },
];

export interface StatutoryExceptionLine {
  check_name: 'allocation' | 'ledger';
  policy_id: string;
  policy_no: string;
  insurer_name: string | null;
  recorded_amount: number;
  booked_amount: number;
  difference: number;
}

export const STATUTORY_EXCEPTION_LABEL: Record<StatutoryExceptionLine['check_name'], string> = {
  allocation: 'Charge allocations differ from the booked pass-through',
  ledger: 'Bind journal differs from the insurer payable amounts',
};
