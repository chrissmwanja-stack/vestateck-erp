import { describe, expect, it } from 'vitest';
import {
  approveBlockedReason, assignmentCovers, assignmentState, canWithdrawDraft, formatParameterValue, isInForceToday, isUnverified,
  isValidReason, missingApprovedKeys, validateAssignment, validateDraft, validateEndDate,
  type ApprovalAssignment, type DraftInput, type ParamDefinition, type RegulatoryParameter,
} from './regulatory';

const def = (over: Partial<ParamDefinition>): ParamDefinition => ({
  key: 'remittance.deadline_working_days', category: 'remittance', description: 'd', value_type: 'days', class_scoped: false, ...over,
});
const draft = (over: Partial<DraftInput> = {}): DraftInput => ({
  key: 'remittance.deadline_working_days', appliesTo: '', value: '1', currency: '', from: '2026-10-17', to: '', source: 'UNVERIFIED: Insurance Act s.90', ...over,
});
const param = (over: Partial<RegulatoryParameter> = {}): RegulatoryParameter => ({
  id: 'p1', tenant_id: 't1', parameter_key: 'remittance.deadline_working_days', applies_to: null, value_num: 1, value_text: null, currency: null,
  effective_from: '2026-01-01', effective_to: null, source_ref: 's', status: 'approved', created_by: 'maker', created_at: '2026-01-01T00:00:00Z',
  approved_by: 'checker', approved_at: '2026-01-02T00:00:00Z', retired_reason: null, ...over,
});
const assign = (over: Partial<ApprovalAssignment> = {}): ApprovalAssignment => ({
  id: 'a1', user_id: 'checker', scope: 'category', scope_value: 'remittance', responsibility: 'IRA returns', effective_from: '2026-01-01',
  effective_to: null, assigned_by: 'admin', assigned_at: '2026-01-01T00:00:00Z', withdrawn_at: null, withdrawn_by: null, withdrawn_reason: null, ...over,
});

describe('validateDraft (mirrors regulatory_parameters_guard)', () => {
  it('accepts a whole number of days and sends no currency', () => {
    const r = validateDraft(def({}), draft());
    expect(r).toEqual({ ok: true, value: expect.objectContaining({ value_num: 1, value_text: null, currency: null, applies_to: null, effective_to: null }) });
  });
  it('refuses a fraction of a day or year, a negative value and a percentage above 100', () => {
    expect(validateDraft(def({}), draft({ value: '1.5' })).ok).toBe(false);
    expect(validateDraft(def({ value_type: 'years' }), draft({ value: '2.5' })).ok).toBe(false);
    expect(validateDraft(def({}), draft({ value: '-1' })).ok).toBe(false);
    const pct = validateDraft(def({ value_type: 'percent' }), draft({ value: '101' }));
    expect(pct.ok).toBe(false);
    expect(validateDraft(def({ value_type: 'percent' }), draft({ value: '18.5' })).ok).toBe(true);
  });
  it('needs a currency code for an amount, and only for an amount', () => {
    const amount = def({ key: 'stamp_duty.policy', value_type: 'amount', class_scoped: true });
    expect(validateDraft(amount, draft({ key: 'stamp_duty.policy', value: '35000' })).ok).toBe(false);
    const ok = validateDraft(amount, draft({ key: 'stamp_duty.policy', value: '35000', currency: 'ugx' }));
    expect(ok).toEqual({ ok: true, value: expect.objectContaining({ currency: 'UGX', value_num: 35000 }) });
  });
  it('allows a class only on rules that vary by class', () => {
    const r = validateDraft(def({}), draft({ appliesTo: 'motor' }));
    expect(r.ok).toBe(false);
    expect(validateDraft(def({ class_scoped: true }), draft({ appliesTo: ' motor ' }))).toEqual({
      ok: true, value: expect.objectContaining({ applies_to: 'motor' }),
    });
  });
  it('takes text only for a text rule', () => {
    const t = def({ value_type: 'text' });
    expect(validateDraft(t, draft({ value: '' })).ok).toBe(false);
    expect(validateDraft(t, draft({ value: 'abc' }))).toEqual({ ok: true, value: expect.objectContaining({ value_text: 'abc', value_num: null }) });
  });
  it('needs a start date, a later end date and a source', () => {
    expect(validateDraft(def({}), draft({ from: '' })).ok).toBe(false);
    expect(validateDraft(def({}), draft({ to: '2026-10-17' })).ok).toBe(false);
    expect(validateDraft(def({}), draft({ to: '2027-10-17' })).ok).toBe(true);
    const r = validateDraft(def({}), draft({ source: '  ' }));
    expect(r.ok).toBe(false);
  });
  it('asks which rule when none is chosen', () => {
    expect(validateDraft(undefined, draft())).toEqual({ ok: false, errors: { key: expect.any(String) } });
  });
});

describe('values and sources', () => {
  it('formats each type', () => {
    expect(formatParameterValue(param({ value_num: 1 }), 'days')).toBe('1 day');
    expect(formatParameterValue(param({ value_num: 5 }), 'days')).toBe('5 days');
    expect(formatParameterValue(param({ value_num: 10 }), 'years')).toBe('10 years');
    expect(formatParameterValue(param({ value_num: '18.5' }), 'percent')).toBe('18.5%');
    expect(formatParameterValue(param({ value_num: 35000, currency: 'UGX' }), 'amount')).toContain('35,000');
    expect(formatParameterValue(param({ value_num: null, value_text: 'abc' }), 'text')).toBe('abc');
  });
  it('spots an unverified source whatever the case', () => {
    expect(isUnverified('UNVERIFIED: draft')).toBe(true);
    expect(isUnverified('  unverified - waiting for adviser')).toBe(true);
    expect(isUnverified('Insurance Act 2017 s.90(3)')).toBe(false);
    expect(isUnverified('Not unverified later')).toBe(false);
  });
  it('wants a reason of five characters', () => {
    expect(isValidReason('oops')).toBe(false);
    expect(isValidReason(' wrong ')).toBe(true);
  });
});

describe('approved values in force', () => {
  const today = '2026-10-17';
  it('uses an exclusive end date', () => {
    expect(isInForceToday(param({ effective_to: '2026-10-18' }), today)).toBe(true);
    expect(isInForceToday(param({ effective_to: '2026-10-17' }), today)).toBe(false);
  });
  it('ignores drafts, retired values and values that start later', () => {
    expect(isInForceToday(param({ status: 'draft' }), today)).toBe(false);
    expect(isInForceToday(param({ status: 'retired' }), today)).toBe(false);
    expect(isInForceToday(param({ effective_from: '2026-10-18' }), today)).toBe(false);
  });
  it('lists rules with no approved value in force, by category then key', () => {
    const defs = [def({ key: 'tax.vat_standard_percent', category: 'tax' }), def({}), def({ key: 'fx.rate_max_age_days', category: 'fx' })];
    const missing = missingApprovedKeys(defs, [param()], today).map((d) => d.key);
    expect(missing).toEqual(['fx.rate_max_age_days', 'tax.vat_standard_percent']);
  });
});

describe('approval by assignment', () => {
  const today = '2026-10-17';
  const p = param({ status: 'draft', created_by: 'maker', approved_by: null, approved_at: null });
  it('lets an assigned approver approve someone else\'s draft', () => {
    expect(approveBlockedReason(p, 'remittance', 'checker', [assign()], today)).toBeNull();
    expect(approveBlockedReason(p, 'remittance', 'checker', [assign({ scope: 'key', scope_value: 'remittance.deadline_working_days' })], today)).toBeNull();
  });
  it('never lets the proposer approve, even if assigned', () => {
    expect(approveBlockedReason(p, 'remittance', 'maker', [assign({ user_id: 'maker' })], today)).toMatch(/proposed/);
  });
  it('refuses someone with no assignment, a withdrawn or ended one, one for another scope, or one that starts later', () => {
    expect(approveBlockedReason(p, 'remittance', 'checker', [], today)).toMatch(/assigned approver/);
    expect(approveBlockedReason(p, 'remittance', 'checker', [assign({ withdrawn_at: '2026-02-01T00:00:00Z' })], today)).not.toBeNull();
    expect(approveBlockedReason(p, 'remittance', 'checker', [assign({ effective_to: '2026-10-16' })], today)).not.toBeNull();
    expect(approveBlockedReason(p, 'remittance', 'checker', [assign({ scope_value: 'levy' })], today)).not.toBeNull();
    expect(approveBlockedReason(p, 'remittance', 'checker', [assign({ effective_from: '2026-10-18' })], today)).not.toBeNull();
    expect(approveBlockedReason(p, 'remittance', 'checker', [assign({ user_id: 'someone-else' })], today)).not.toBeNull();
  });
  it('treats both ends of an assignment as inclusive', () => {
    expect(assignmentState(assign({ effective_from: today, effective_to: today }), today)).toBe('in_force');
    expect(assignmentState(assign({ effective_to: '2026-10-16' }), today)).toBe('ended');
    expect(assignmentState(assign({ effective_from: '2026-10-18' }), today)).toBe('scheduled');
    expect(assignmentState(assign({ withdrawn_at: 'x' }), today)).toBe('withdrawn');
  });
  it('covers by key or by category', () => {
    expect(assignmentCovers(assign({ scope: 'key', scope_value: 'a.b' }), 'a.b', 'x')).toBe(true);
    expect(assignmentCovers(assign({ scope: 'key', scope_value: 'a.b' }), 'a.c', 'x')).toBe(false);
    expect(assignmentCovers(assign({ scope: 'category', scope_value: 'x' }), 'a.c', 'x')).toBe(true);
    expect(assignmentCovers(assign({ scope: 'category', scope_value: 'x' }), 'a.c', undefined)).toBe(false);
  });
  it('lets a draft be withdrawn by its proposer or a company admin only', () => {
    expect(canWithdrawDraft(p, 'maker', false)).toBe(true);
    expect(canWithdrawDraft(p, 'other', false)).toBe(false);
    expect(canWithdrawDraft(p, 'other', true)).toBe(true);
    expect(canWithdrawDraft(param(), 'maker', true)).toBe(false);
  });
});

describe('end dates and assignments', () => {
  it('only shortens an approved value', () => {
    const p = param({ effective_from: '2026-01-01', effective_to: '2027-01-01' });
    expect(validateEndDate(p, '2026-06-30')).toBeNull();
    expect(validateEndDate(p, '2026-01-01')).not.toBeNull();
    expect(validateEndDate(p, '2027-01-01')).not.toBeNull();
    expect(validateEndDate(param({ effective_to: null }), '2030-01-01')).toBeNull();
    expect(validateEndDate(p, '')).not.toBeNull();
  });
  it('checks an approver assignment', () => {
    const ok = { userId: 'u', scope: 'key' as const, scopeValue: 'a.b', responsibility: 'IRA returns', from: '2026-10-17', to: '' };
    expect(validateAssignment(ok)).toEqual({});
    expect(Object.keys(validateAssignment({ ...ok, userId: '', scopeValue: '', responsibility: ' ' }))).toEqual(['userId', 'scopeValue', 'responsibility']);
    expect(validateAssignment({ ...ok, to: '2026-10-16' }).to).toBeDefined();
    expect(validateAssignment({ ...ok, to: '2026-10-17' })).toEqual({});
  });
});
