import { describe, expect, it } from 'vitest';
import { kycTargets } from './clientKyc';

describe('kycTargets', () => {
  it('offers every other status, verification first', () => {
    expect(kycTargets('pending')).toEqual(['verified', 'expired']);
    expect(kycTargets('verified')).toEqual(['expired', 'pending']);
    expect(kycTargets('expired')).toEqual(['verified', 'pending']);
  });
});
