import { describe, expect, it } from 'vitest';
import { policyCashActions, validatePolicyCashInput, type PolicyCashPosition, type PolicyCashRequest } from './policyCash';

describe('policy cash UI controls (server remains authoritative)', () => {
  const pos = { can_prepare: true, actor_id: 'maker' } as PolicyCashPosition;
  const pending = { maker_id: 'maker', status: 'pending' } as PolicyCashRequest;
  it('only offers cancellation to the maker', () => {
    expect(policyCashActions(pos, pending)).toEqual(['cancel']);
  });
  it('offers approval and rejection to a different Finance checker', () => {
    expect(policyCashActions({ ...pos, actor_id: 'checker' }, pending)).toEqual(['approve', 'reject']);
  });
  it('offers no money actions to Insurance-only users', () => {
    expect(policyCashActions({ ...pos, can_prepare: false }, pending)).toEqual([]);
  });
  it.each(['posted', 'void', 'rejected', 'cancelled'] as const)('never re-decides a %s request', (status) => {
    expect(policyCashActions(pos, { ...pending, status })).toEqual([]);
  });
  it('accepts a partial payment up to the full server cap, without a pro-rata reserve', () => {
    expect(validatePolicyCashInput('400', '2026-10-15', 'bank', 400, '2026-10-15')).toBeNull();
    expect(validatePolicyCashInput('100.25', '2026-10-14', 'bank', 400, '2026-10-15')).toBeNull();
  });
  it.each(['0', '-1', '1.001', 'NaN', 'Infinity', '', '1e3'])('rejects invalid amount %s', (amount) => {
    expect(validatePolicyCashInput(amount, '2026-10-15', 'bank', 1000, '2026-10-15')).not.toBeNull();
  });
  it('rejects cap overflow, missing bank and future date', () => {
    expect(validatePolicyCashInput('400.01', '2026-10-15', 'bank', 400, '2026-10-15')).toMatch(/limit/);
    expect(validatePolicyCashInput('1', '2026-10-15', '', 400, '2026-10-15')).toMatch(/bank/);
    expect(validatePolicyCashInput('1', '2026-10-16', 'bank', 400, '2026-10-15')).toMatch(/today/);
  });
});
