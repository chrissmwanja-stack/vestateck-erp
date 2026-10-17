import { describe, expect, it } from 'vitest';
import {
  allowedStatusMoves,
  canVerify,
  changeNeedsReverification,
  parentChoices,
  parentWouldLoop,
  saveProblems,
  statusNeedsNote,
  type Intermediary,
  type IntermediaryForm,
} from './intermediaries';

const TODAY = '2026-10-17';

const base = (over: Partial<Intermediary> = {}): Intermediary => ({
  id: 'x', code: 'X', kind: 'business', name: 'X', category: 'independent_broker',
  contact_email: null, contact_phone: null, parent_id: null,
  licence_ref: 'LIC', licence_authority: 'IRA', licence_valid_from: null, licence_valid_to: '2027-10-17',
  appointment_ref: null, authorisation_basis: null, authorisation_reference: null,
  status: 'active', last_changed_by: 'maker', verified_by: 'checker', verified_at: '2026-10-01',
  ...over,
});

const form = (over: Partial<IntermediaryForm> = {}): IntermediaryForm => ({
  code: 'IB-1', name: 'Alpha', kind: 'business', category: 'independent_broker', parent_id: null,
  licence_ref: 'LIC-1', licence_authority: 'IRA', licence_valid_from: '', licence_valid_to: '2027-10-17',
  appointment_ref: '', authorisation_basis: '', authorisation_reference: '', ...over,
});

describe('licence and appointment rules', () => {
  it('requires a licence for every category except a referral partner', () => {
    expect(saveProblems(form({ licence_ref: '' }), [], null, TODAY)).toContain(
      'A licence needs its reference, issuing authority and expiry date.');
    expect(saveProblems(form({ category: 'referral_partner', licence_ref: '', licence_authority: '', licence_valid_to: '' }), [], null, TODAY))
      .toEqual([]);
  });

  it('refuses an expired licence and an expiry before its start', () => {
    expect(saveProblems(form({ licence_valid_to: '2026-01-01' }), [], null, TODAY)).toContain('The licence has already expired.');
    expect(saveProblems(form({ licence_valid_from: '2027-01-01', licence_valid_to: '2026-12-01' }), [], null, TODAY))
      .toContain('The licence expiry is before its start date.');
  });

  it('needs an appointment reference for an insurer-appointed agent, separate from the licence', () => {
    const agent = form({ category: 'insurer_appointed_agent', appointment_ref: '' });
    expect(saveProblems(agent, [], null, TODAY).join(' ')).toMatch(/appointment reference/);
    expect(saveProblems({ ...agent, appointment_ref: 'APPT-9' }, [], null, TODAY)).toEqual([]);
  });

  it('a broker needs no appointment reference', () => {
    expect(saveProblems(form({ appointment_ref: '' }), [], null, TODAY)).toEqual([]);
  });
});

describe('sub-agent parent rules', () => {
  const broker = base({ id: 'B', status: 'active' });
  const sub = form({
    category: 'sub_agent', parent_id: 'B', authorisation_basis: 'Written appointment', authorisation_reference: 'AUTH-1',
  });

  it('needs a parent, and the authorisation evidence', () => {
    expect(saveProblems({ ...sub, parent_id: null }, [broker], null, TODAY)).toContain(
      'A sub-agent must be placed under a parent intermediary.');
    expect(saveProblems({ ...sub, authorisation_reference: '' }, [broker], null, TODAY).join(' ')).toMatch(/Record the basis/);
  });

  it('accepts an active, non-referral parent with the evidence', () => {
    expect(saveProblems(sub, [broker], null, TODAY)).toEqual([]);
  });

  it('refuses a parent that is not active, and a referral partner', () => {
    const pending = base({ id: 'P', status: 'pending_verification' });
    expect(saveProblems({ ...sub, parent_id: 'P' }, [pending], null, TODAY).join(' ')).toMatch(/verified and active/);
    const ref = base({ id: 'R', category: 'referral_partner', licence_ref: null, licence_authority: null, licence_valid_to: null });
    expect(saveProblems({ ...sub, parent_id: 'R' }, [ref], null, TODAY).join(' ')).toMatch(/referral partner cannot/);
  });

  it('places no limit on depth, but refuses a loop', () => {
    // A -> B -> C (C is a sub-agent under B, B under A). Making C the parent of A is a loop.
    const a = base({ id: 'A' });
    const b = base({ id: 'B', category: 'sub_agent', parent_id: 'A' });
    const c = base({ id: 'C', category: 'sub_agent', parent_id: 'B' });
    expect(parentWouldLoop('C', 'A', [a, b, c])).toBe(true);
    expect(parentWouldLoop('A', 'C', [a, b, c])).toBe(false);
    expect(saveProblems({ ...form({ category: 'independent_broker' }), parent_id: 'C' }, [a, b, c], 'A', TODAY))
      .toContain('That parent sits below this intermediary in the chain.');
  });

  it('a deep chain with no loop is allowed', () => {
    const chain = Array.from({ length: 12 }, (_, i) =>
      base({ id: `n${i}`, category: 'sub_agent', parent_id: i === 0 ? null : `n${i - 1}` }));
    expect(parentWouldLoop('n11', 'fresh', chain)).toBe(false);
  });

  it('offers only active, non-referral, non-looping parents', () => {
    const a = base({ id: 'A' });
    const b = base({ id: 'B', category: 'sub_agent', parent_id: 'A' });
    const pendingBroker = base({ id: 'P', status: 'pending_verification' });
    const ref = base({ id: 'R', category: 'referral_partner' });
    // Editing A: B is A's own child, so it would loop. Only A itself is excluded for a new record.
    expect(parentChoices([a, b, pendingBroker, ref], 'A').map((p) => p.id)).toEqual([]);
    expect(parentChoices([a, b, pendingBroker, ref], 'NEW').map((p) => p.id)).toEqual(['A', 'B']);
  });
});

describe('re-verification after a change', () => {
  const before = base({ parent_id: null, licence_valid_from: null });

  it('a credential, category or parent change sends the record back', () => {
    expect(changeNeedsReverification(before, { ...before, licence_ref: 'NEW' })).toBe(true);
    expect(changeNeedsReverification(before, { ...before, category: 'sub_agent' })).toBe(true);
    expect(changeNeedsReverification(before, { ...before, parent_id: 'P' })).toBe(true);
  });

  it('a name or contact change does not', () => {
    expect(changeNeedsReverification(before, { ...before })).toBe(false);
  });
});

describe('verification segregation', () => {
  it('the person who last changed a record cannot verify it', () => {
    const pending = base({ status: 'pending_verification', last_changed_by: 'maker' });
    expect(canVerify(pending, 'maker').ok).toBe(false);
    expect(canVerify(pending, 'checker')).toEqual({ ok: true });
  });

  it('only a pending record can be verified', () => {
    expect(canVerify(base({ status: 'active' }), 'checker').ok).toBe(false);
  });
});

describe('status moves', () => {
  it('lists the moves the server allows', () => {
    expect(allowedStatusMoves('active')).toEqual(['suspended', 'expired', 'terminated']);
    expect(allowedStatusMoves('suspended')).toEqual(['active', 'terminated']);
    expect(allowedStatusMoves('pending_verification')).toEqual(['terminated']);
    expect(allowedStatusMoves('terminated')).toEqual([]);
  });

  it('suspending and terminating need a reason', () => {
    expect(statusNeedsNote('suspended')).toBe(true);
    expect(statusNeedsNote('terminated')).toBe(true);
    expect(statusNeedsNote('active')).toBe(false);
  });
});
