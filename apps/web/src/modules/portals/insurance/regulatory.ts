import { formatMoney } from './logic';

// Rules for the regulatory-parameters screen. The server decides every one of these
// (regulatory_parameters_guard, reg_approve_parameter, reg_end_parameter,
// reg_retire_parameter, reg_assign_approver, reg_withdraw_approver). These helpers only
// mirror them so a person sees the problem before submitting, and so the screen shows
// each person only the buttons they can use. Approval follows an assignment, not a role.

export type ParamValueType = 'amount' | 'percent' | 'days' | 'years' | 'number' | 'text';
export type ParamStatus = 'draft' | 'approved' | 'retired';
export type AssignmentScope = 'key' | 'category';
export type AssignmentState = 'withdrawn' | 'scheduled' | 'in_force' | 'ended';

export interface ParamDefinition {
  key: string;
  category: string;
  description: string;
  value_type: ParamValueType;
  class_scoped: boolean;
}

export interface RegulatoryParameter {
  id: string;
  tenant_id: string;
  parameter_key: string;
  applies_to: string | null;
  value_num: number | string | null;
  value_text: string | null;
  currency: string | null;
  effective_from: string;
  effective_to: string | null;
  source_ref: string;
  status: ParamStatus;
  created_by: string | null;
  created_at: string;
  approved_by: string | null;
  approved_at: string | null;
  retired_reason: string | null;
}

export interface ApprovalAssignment {
  id: string;
  user_id: string;
  scope: AssignmentScope;
  scope_value: string;
  responsibility: string;
  effective_from: string;
  effective_to: string | null;
  assigned_by: string;
  assigned_at: string;
  withdrawn_at: string | null;
  withdrawn_by: string | null;
  withdrawn_reason: string | null;
}

export interface ParameterEvent {
  id: string;
  parameter_id: string;
  event: 'approved' | 'ended' | 'retired';
  actor: string | null;
  detail: string | null;
  created_at: string;
}

export const PARAM_STATUS_LABEL: Record<ParamStatus, string> = {
  draft: 'Draft, awaiting approval',
  approved: 'Approved',
  retired: 'Retired',
};

export const ASSIGNMENT_STATE_LABEL: Record<AssignmentState, string> = {
  in_force: 'In force',
  scheduled: 'Starts later',
  ended: 'Ended',
  withdrawn: 'Withdrawn',
};

export const MIN_REASON_LENGTH = 5;
export const isValidReason = (reason: string): boolean => reason.trim().length >= MIN_REASON_LENGTH;

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const CURRENCY = /^[A-Z]{3}$/;

/** A source marked UNVERIFIED has not been confirmed by the accountant or compliance adviser. */
export const isUnverified = (source: string): boolean => /^\s*unverified\b/i.test(source);

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

/** A value as people read it: 10%, 35,000 UGX, 5 days, a text. */
export function formatParameterValue(
  p: Pick<RegulatoryParameter, 'value_num' | 'value_text' | 'currency'>,
  type: ParamValueType | undefined,
): string {
  if (p.value_text !== null && p.value_text !== undefined && p.value_num == null) return p.value_text;
  if (p.value_num == null) return '-';
  const n = Number(p.value_num);
  switch (type) {
    case 'amount':
      return formatMoney(n, p.currency ?? undefined);
    case 'percent':
      return `${n}%`;
    case 'days':
      return `${n} ${plural(n, 'day', 'days')}`;
    case 'years':
      return `${n} ${plural(n, 'year', 'years')}`;
    default:
      return String(n);
  }
}

export interface DraftInput {
  key: string;
  appliesTo: string;
  value: string;
  currency: string;
  from: string;
  to: string;
  source: string;
}

export interface DraftValue {
  parameter_key: string;
  applies_to: string | null;
  value_num: number | null;
  value_text: string | null;
  currency: string | null;
  effective_from: string;
  effective_to: string | null;
  source_ref: string;
}

export type DraftResult =
  | { ok: true; value: DraftValue }
  | { ok: false; errors: Partial<Record<keyof DraftInput, string>> };

/** Checks a draft the way regulatory_parameters_guard does, plus the form's own format rules. */
export function validateDraft(def: ParamDefinition | undefined, input: DraftInput): DraftResult {
  const errors: Partial<Record<keyof DraftInput, string>> = {};
  if (!def) {
    return { ok: false, errors: { key: 'Choose which rule this value is for.' } };
  }

  const appliesTo = input.appliesTo.trim();
  if (appliesTo && !def.class_scoped) errors.appliesTo = 'This rule does not vary by class.';

  let valueNum: number | null = null;
  let valueText: string | null = null;
  let currency: string | null = null;
  const raw = input.value.trim();
  if (def.value_type === 'text') {
    if (!raw) errors.value = 'Enter the value.';
    else valueText = raw;
  } else {
    const n = Number(raw);
    if (raw === '' || !Number.isFinite(n)) errors.value = 'Enter a number.';
    else if (n < 0) errors.value = 'The value cannot be negative.';
    else if (def.value_type === 'percent' && n > 100) errors.value = 'A percentage cannot be more than 100.';
    else if ((def.value_type === 'days' || def.value_type === 'years') && !Number.isInteger(n)) {
      errors.value = `Use a whole number of ${def.value_type}.`;
    } else valueNum = n;
    if (def.value_type === 'amount') {
      const cur = input.currency.trim().toUpperCase();
      if (!CURRENCY.test(cur)) errors.currency = 'Use the three-letter currency code, for example UGX.';
      else currency = cur;
    }
  }

  if (!ISO_DATE.test(input.from)) errors.from = 'Enter the date this value starts.';
  if (input.to) {
    if (!ISO_DATE.test(input.to)) errors.to = 'Enter a valid end date, or leave it empty.';
    else if (ISO_DATE.test(input.from) && input.to <= input.from) errors.to = 'The end date must be after the start date.';
  }
  if (!input.source.trim()) {
    errors.source = 'Say where the value comes from. Start with UNVERIFIED if it is not yet confirmed.';
  }

  if (Object.keys(errors).length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      parameter_key: def.key,
      applies_to: appliesTo || null,
      value_num: valueNum,
      value_text: valueText,
      currency,
      effective_from: input.from,
      effective_to: input.to || null,
      source_ref: input.source.trim(),
    },
  };
}

/** True while an approved value applies on `today`. The end date is exclusive, as on the server. */
export function isInForceToday(p: Pick<RegulatoryParameter, 'status' | 'effective_from' | 'effective_to'>, today: string): boolean {
  return p.status === 'approved' && p.effective_from <= today && (p.effective_to === null || today < p.effective_to);
}

/** Rules that have no approved value in force today, in category then key order. */
export function missingApprovedKeys(defs: ParamDefinition[], params: RegulatoryParameter[], today: string): ParamDefinition[] {
  const covered = new Set(params.filter((p) => isInForceToday(p, today)).map((p) => p.parameter_key));
  return defs
    .filter((d) => !covered.has(d.key))
    .sort((a, b) => a.category.localeCompare(b.category) || a.key.localeCompare(b.key));
}

/** Where an approver assignment stands on `today`. Both ends are inclusive, as on the server. */
export function assignmentState(
  a: Pick<ApprovalAssignment, 'withdrawn_at' | 'effective_from' | 'effective_to'>,
  today: string,
): AssignmentState {
  if (a.withdrawn_at) return 'withdrawn';
  if (today < a.effective_from) return 'scheduled';
  if (a.effective_to && today > a.effective_to) return 'ended';
  return 'in_force';
}

export function assignmentCovers(a: Pick<ApprovalAssignment, 'scope' | 'scope_value'>, key: string, category: string | undefined): boolean {
  return (a.scope === 'key' && a.scope_value === key) || (a.scope === 'category' && category !== undefined && a.scope_value === category);
}

/** Why this person cannot approve a draft, or null if they can. The server still decides. */
export function approveBlockedReason(
  p: Pick<RegulatoryParameter, 'status' | 'parameter_key' | 'created_by'>,
  category: string | undefined,
  userId: string | null,
  assignments: ApprovalAssignment[],
  today: string,
): string | null {
  if (p.status !== 'draft') return 'Only a draft can be approved.';
  if (!userId) return 'Sign in to approve.';
  if (p.created_by === userId) return 'You proposed this value, so someone else has to approve it.';
  const assigned = assignments.some(
    (a) => a.user_id === userId && assignmentState(a, today) === 'in_force' && assignmentCovers(a, p.parameter_key, category),
  );
  return assigned ? null : 'Only an assigned approver can approve this. A company admin assigns approvers.';
}

export const canWithdrawDraft = (p: Pick<RegulatoryParameter, 'status' | 'created_by'>, userId: string | null, isCompanyAdmin: boolean): boolean =>
  p.status === 'draft' && (isCompanyAdmin || (userId !== null && p.created_by === userId));

/** An approved value can only be shortened: the new end is after its start and before its current end. */
export function validateEndDate(p: Pick<RegulatoryParameter, 'effective_from' | 'effective_to'>, end: string): string | null {
  if (!ISO_DATE.test(end)) return 'Enter the end date.';
  if (end <= p.effective_from) return `The end date must be after the start date (${p.effective_from}).`;
  if (p.effective_to !== null && end >= p.effective_to) return `The end date must be earlier than the current end date (${p.effective_to}).`;
  return null;
}

export interface AssignmentInput {
  userId: string;
  scope: AssignmentScope;
  scopeValue: string;
  responsibility: string;
  from: string;
  to: string;
}

export function validateAssignment(input: AssignmentInput): Partial<Record<keyof AssignmentInput, string>> {
  const errors: Partial<Record<keyof AssignmentInput, string>> = {};
  if (!input.userId) errors.userId = 'Choose who will approve.';
  if (!input.scopeValue) errors.scopeValue = input.scope === 'key' ? 'Choose the rule.' : 'Choose the category.';
  if (!input.responsibility.trim()) errors.responsibility = 'State the responsibility this approval covers, for example the submission it supports.';
  if (!ISO_DATE.test(input.from)) errors.from = 'Enter the date the assignment starts.';
  if (input.to) {
    if (!ISO_DATE.test(input.to)) errors.to = 'Enter a valid end date, or leave it empty.';
    else if (ISO_DATE.test(input.from) && input.to < input.from) errors.to = 'The end date cannot be before the start date.';
  }
  return errors;
}
