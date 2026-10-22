import { describe, expect, it } from 'vitest';
import { canStartRenewal, isRenewalOpen, summariseBulkRenewal, validateRenewalOutcome } from './logic';

describe('renewal state', () => {
  it('is open until an outcome is recorded', () => {
    expect(isRenewalOpen({ renewal_outcome: null })).toBe(true);
    expect(isRenewalOpen({ renewal_outcome: 'lost' })).toBe(false);
  });

  it('can start only when open and without a draft', () => {
    expect(canStartRenewal({ renewal_outcome: null, renewal_draft_id: null })).toBe(true);
    expect(canStartRenewal({ renewal_outcome: null, renewal_draft_id: 'd1' })).toBe(false);
    expect(canStartRenewal({ renewal_outcome: 'declined', renewal_draft_id: null })).toBe(false);
  });
});

describe('validateRenewalOutcome', () => {
  it('needs an outcome and a reason of at least 5 characters', () => {
    expect(validateRenewalOutcome('', 'Moved to another broker')).toHaveLength(1);
    expect(validateRenewalOutcome('lost', 'no')).toHaveLength(1);
    expect(validateRenewalOutcome('', '')).toHaveLength(2);
    expect(validateRenewalOutcome('lost', 'Moved to another broker')).toEqual([]);
  });

  it('ignores surrounding spaces when counting the reason', () => {
    expect(validateRenewalOutcome('lapsed', '  abc  ')).toHaveLength(1);
  });
});

describe('summariseBulkRenewal', () => {
  it('counts the drafts opened and lists each refusal without the server code', () => {
    const out = summariseBulkRenewal([
      { policy_id: 'a', policy_no: 'POL-1', ok: true, draft_id: 'd1' },
      { policy_id: 'b', policy_no: 'POL-2', ok: false, error: 'INS_RENEWAL_EXISTS: a renewal draft already exists for POL-2' },
      { policy_id: 'c', policy_no: null, ok: false },
    ]);
    expect(out.created).toBe(1);
    expect(out.failed).toEqual([
      { policy_no: 'POL-2', message: 'a renewal draft already exists for POL-2' },
      { policy_no: 'Unknown policy', message: 'Could not start the renewal.' },
    ]);
  });

  it('handles an empty result', () => {
    expect(summariseBulkRenewal([])).toEqual({ created: 0, failed: [] });
  });
});
