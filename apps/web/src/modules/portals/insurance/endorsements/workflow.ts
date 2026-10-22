// The endorsement workflow's pure pieces and thin RPC wrappers. All the money
// math lives server-side (ins_preview_policy_endorsement); the UI only shapes
// inputs and presents the returned calculation.
import { rpc } from '../db';

export type EndorsementStatus = 'proposed' | 'prepared' | 'posting' | 'posted' | 'rejected' | 'withdrawn';

export interface EndorsementShareCalc {
  insurer_id: string;
  share_pct?: string;
  share_premium?: string;
  basis: 'agreed' | 'pro_rata';
  input: string;
  premium_delta: string;
  commission_delta: string;
  rate_pct: string;
  requires_review: boolean;
}

export interface EndorsementChange {
  field: string;
  before: unknown;
  after: unknown;
}

export interface EndorsementCalculation {
  policy_id: string;
  policy_no: string;
  currency: string;
  effective_date: string;
  inception_date: string;
  expiry_date: string;
  remaining_days: number;
  total_days: number;
  premium_delta: number;
  commission_delta: number;
  commission_rate_pct: number;
  premium_zero: boolean;
  requires_review?: boolean;
  shares: EndorsementShareCalc[];
  changes: EndorsementChange[];
  [key: string]: unknown;
}

export interface EndorsementRow {
  id: string;
  endorsement_no: string | null;
  status: EndorsementStatus;
  effective_date: string;
  reason: string;
  proposed_by: string;
  proposed_at: string;
  prepared_by: string | null;
  calculation: EndorsementCalculation | null;
  review_note: string | null;
  credit_note_ids: unknown;
}

export interface EndorsementTermsDraft {
  insurer_id: string;
  agreed_delta: string;
}

export type EndorsementChangesDraft = {
  sum_insured?: string;
  risk_description?: string;
  notes?: string;
};

export function buildTerms(drafts: EndorsementTermsDraft[]): { insurer_id: string; agreed_delta: string }[] {
  return drafts
    .filter((d) => d.agreed_delta.trim() !== '')
    .map((d) => ({ insurer_id: d.insurer_id, agreed_delta: d.agreed_delta.trim() }));
}

export function buildChanges(draft: EndorsementChangesDraft): Record<string, string | number> {
  const out: Record<string, string | number> = {};
  const sum = (draft.sum_insured ?? '').trim();
  if (sum !== '') {
    const n = Number(sum);
    if (!Number.isFinite(n) || n <= 0) throw new Error('Sum insured must be a positive number.');
    out.sum_insured = n;
  }
  const risk = (draft.risk_description ?? '').trim();
  if (risk !== '') out.risk_description = risk;
  const notes = (draft.notes ?? '').trim();
  if (notes !== '') out.notes = notes;
  return out;
}

export function statusTone(status: EndorsementStatus): 'success' | 'primary' | 'warning' | 'default' | 'error' {
  switch (status) {
    case 'posted':
      return 'success';
    case 'proposed':
    case 'prepared':
    case 'posting':
      return 'warning';
    case 'rejected':
      return 'error';
    default:
      return 'default';
  }
}

export function formatSigned(amount: number | null | undefined, currency: string): string {
  const n = amount ?? 0;
  const body = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Math.abs(n));
  return `${n < 0 ? '-' : ''}${currency} ${body}`;
}

export function isLive(status: EndorsementStatus): boolean {
  return status === 'proposed' || status === 'prepared' || status === 'posting';
}

export async function previewEndorsement(
  policyId: string,
  effectiveDate: string,
  terms: { insurer_id: string; agreed_delta: string }[],
  changes: Record<string, string | number>,
): Promise<EndorsementCalculation> {
  return rpc<EndorsementCalculation>('ins_preview_policy_endorsement', {
    p_policy_id: policyId,
    p_effective_date: effectiveDate,
    p_insurer_terms: terms,
    p_changes: changes,
  });
}

export async function proposeEndorsement(input: {
  policyId: string;
  effectiveDate: string;
  terms: { insurer_id: string; agreed_delta: string }[];
  changes: Record<string, string | number>;
  reason: string;
}): Promise<EndorsementRow> {
  return rpc<EndorsementRow>('ins_propose_policy_endorsement', {
    p_policy_id: input.policyId,
    p_effective_date: input.effectiveDate,
    p_insurer_terms: input.terms,
    p_changes: input.changes,
    p_reason: input.reason,
    p_request_key: crypto.randomUUID(),
  });
}

export async function withdrawEndorsement(id: string, reason: string): Promise<void> {
  await rpc('ins_withdraw_policy_endorsement', { p_endorsement_id: id, p_reason: reason });
}

export async function prepareEndorsement(id: string, clearingGlAccountId: string): Promise<EndorsementRow> {
  return rpc<EndorsementRow>('ins_prepare_policy_endorsement', {
    p_endorsement_id: id,
    p_clearing_gl_account_id: clearingGlAccountId,
  });
}

export async function decideEndorsement(
  id: string,
  decision: 'approve' | 'reject',
  reviewNote: string,
  acceptException = false,
): Promise<EndorsementRow> {
  return rpc<EndorsementRow>('ins_decide_policy_endorsement', {
    p_endorsement_id: id,
    p_decision: decision,
    p_review_note: reviewNote,
    p_accept_manual_exception: acceptException,
  });
}

export interface EndorsementPosition {
  policy_id: string;
  policy_no: string;
  currency: string;
  bound_gross_premium: number;
  bound_commission_amount: number;
  current_gross_premium: number;
  current_commission_amount: number;
  current_sum_insured: number | null;
  posted_endorsements: number;
  live_endorsements: unknown[];
  cancellation_in_flight: boolean;
}

export async function reviewPosition(policyId: string): Promise<EndorsementPosition> {
  return rpc<EndorsementPosition>('ins_endorsement_review_position', { p_policy_id: policyId });
}
