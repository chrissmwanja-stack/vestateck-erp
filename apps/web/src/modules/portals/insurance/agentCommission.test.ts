import { describe, expect, it } from 'vitest';
import { netOf, recentAccruals, summariseAccruals, type AgentAccrual } from './agentCommission';

const acc = (over: Partial<AgentAccrual>): AgentAccrual => ({
  id: 'a', policy_id: 'p', intermediary_id: 'i', basis: 'pct_of_broker_commission', gross_amount: 100,
  wht_amount: 0, net_amount: null, currency: 'UGX', status: 'accrued', eligible_on: null, paid_at: null,
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z', ...over,
});

describe('summariseAccruals', () => {
  it('groups by status and never mixes currencies', () => {
    const s = summariseAccruals([
      acc({ id: '1', gross_amount: 1000 }),
      acc({ id: '2', gross_amount: 500, status: 'eligible' }),
      acc({ id: '3', gross_amount: 200, currency: 'USD' }),
      acc({ id: '4', gross_amount: 300, status: 'paid' }),
    ]);
    expect(s.accrued).toEqual({ UGX: 1000, USD: 200 });
    expect(s.eligible).toEqual({ UGX: 500 });
    expect(s.paid).toEqual({ UGX: 300 });
  });

  it('ignores reversed accruals entirely', () => {
    const s = summariseAccruals([acc({ gross_amount: 900, wht_amount: 90, status: 'reversed' })]);
    expect(s).toEqual({ accrued: {}, eligible: {}, paid: {}, outstanding: {}, withholding: {} });
  });

  it('outstanding is net of withholding and excludes paid', () => {
    const s = summariseAccruals([
      acc({ id: '1', gross_amount: 1000, wht_amount: 100 }),
      acc({ id: '2', gross_amount: 500, wht_amount: 50, net_amount: 450, status: 'eligible' }),
      acc({ id: '3', gross_amount: 700, wht_amount: 70, status: 'paid' }),
    ]);
    expect(s.outstanding).toEqual({ UGX: 1350 });
    expect(s.withholding).toEqual({ UGX: 220 });
  });
});

describe('netOf', () => {
  it('prefers the stored net, else gross less withholding', () => {
    expect(netOf({ gross_amount: 100, wht_amount: 10, net_amount: 88 })).toBe(88);
    expect(netOf({ gross_amount: 100, wht_amount: 10, net_amount: null })).toBe(90);
  });
});

describe('recentAccruals', () => {
  it('returns the newest changes first, capped at the limit', () => {
    const list = [
      acc({ id: 'old', updated_at: '2026-01-01T00:00:00Z' }),
      acc({ id: 'new', updated_at: '2026-11-01T00:00:00Z' }),
      acc({ id: 'mid', updated_at: '2026-06-01T00:00:00Z' }),
    ];
    expect(recentAccruals(list, 2).map((a) => a.id)).toEqual(['new', 'mid']);
  });
});

import {
  basesForCategory, canApproveTerm, canEndTerm, termFigure, termPhase, validateTermInput, type TermFormInput,
} from './agentCommission';

const form = (over: Partial<TermFormInput>): TermFormInput => ({
  basis: 'pct_of_broker_commission', rate_pct: '30', fixed_amount: '', tier_from_amount: '', tier_to_amount: '',
  effective_from: '2026-11-01', effective_to: '', ...over,
});

describe('basesForCategory', () => {
  it('insurer-appointed agents can only be recorded as none; co-brokers get nothing', () => {
    expect(basesForCategory('insurer_appointed_agent')).toEqual(['none']);
    expect(basesForCategory('independent_broker')).toEqual([]);
    expect(basesForCategory('sub_agent')).toContain('flat_amount_per_policy');
    expect(basesForCategory('referral_partner')).not.toContain('none');
  });
});

describe('validateTermInput', () => {
  it('accepts a plain percentage of brokerage commission', () => {
    expect(validateTermInput(form({}))).toBeNull();
  });
  it('requires a basis and a start date', () => {
    expect(validateTermInput(form({ basis: '' }))).toMatch(/how this intermediary is paid/i);
    expect(validateTermInput(form({ effective_from: '' }))).toMatch(/starts/i);
  });
  it('rejects an end date before the start date', () => {
    expect(validateTermInput(form({ effective_to: '2026-10-01' }))).toMatch(/end date/i);
  });
  it('percentages must be between 0 and 100', () => {
    expect(validateTermInput(form({ rate_pct: '' }))).toMatch(/percentage/i);
    expect(validateTermInput(form({ rate_pct: '101' }))).toMatch(/percentage/i);
    expect(validateTermInput(form({ rate_pct: '-1' }))).toMatch(/percentage/i);
    expect(validateTermInput(form({ rate_pct: '0' }))).toBeNull();
  });
  it('a fixed amount must be greater than zero and needs no percentage', () => {
    expect(validateTermInput(form({ basis: 'flat_amount_per_policy', rate_pct: '', fixed_amount: '0' }))).toMatch(/fixed amount/i);
    expect(validateTermInput(form({ basis: 'flat_amount_per_policy', rate_pct: '', fixed_amount: '50000' }))).toBeNull();
  });
  it('a tier needs both bounds with to above from', () => {
    expect(validateTermInput(form({ basis: 'tiered_pct_of_broker_commission', tier_from_amount: '100' }))).toMatch(/both/i);
    expect(validateTermInput(form({ basis: 'tiered_pct_of_broker_commission', tier_from_amount: '500', tier_to_amount: '500' }))).toMatch(/greater/i);
    expect(validateTermInput(form({ basis: 'tiered_pct_of_broker_commission', tier_from_amount: '0', tier_to_amount: '500' }))).toBeNull();
  });
  it('none needs no figure', () => {
    expect(validateTermInput(form({ basis: 'none', rate_pct: '' }))).toBeNull();
  });
});

describe('termFigure', () => {
  it('describes each basis', () => {
    const base = { rate_pct: null, fixed_amount: null, tier_from_amount: null, tier_to_amount: null, currency: 'UGX' };
    expect(termFigure({ ...base, basis: 'none' })).toBe('No commission');
    expect(termFigure({ ...base, basis: 'pct_of_broker_commission', rate_pct: 30 })).toBe('30% of brokerage commission');
    expect(termFigure({ ...base, basis: 'pct_of_gross_premium', rate_pct: 5 })).toBe('5% of gross premium');
    expect(termFigure({ ...base, basis: 'flat_amount_per_policy', fixed_amount: 50000 })).toMatch(/50,000.*per policy/);
  });
});

describe('termPhase', () => {
  const t = (status: 'draft' | 'approved' | 'withdrawn' | 'expired', from: string, to: string | null) => ({ status, effective_from: from, effective_to: to });
  it('derives the phase of an approved term from its dates', () => {
    expect(termPhase(t('approved', '2026-12-01', null), '2026-11-18')).toBe('scheduled');
    expect(termPhase(t('approved', '2026-01-01', null), '2026-11-18')).toBe('in_force');
    expect(termPhase(t('approved', '2026-01-01', '2026-06-30'), '2026-11-18')).toBe('ended');
    expect(termPhase(t('draft', '2026-01-01', null), '2026-11-18')).toBe('draft');
    expect(termPhase(t('withdrawn', '2026-01-01', null), '2026-11-18')).toBe('withdrawn');
  });
});

describe('canApproveTerm / canEndTerm', () => {
  it('the person who entered a term cannot approve it', () => {
    expect(canApproveTerm({ status: 'draft', entered_by: 'u1' }, 'u1', true)).toBe(false);
    expect(canApproveTerm({ status: 'draft', entered_by: 'u1' }, 'u2', true)).toBe(true);
  });
  it('needs a manager, a draft, and a known user', () => {
    expect(canApproveTerm({ status: 'draft', entered_by: 'u1' }, 'u2', false)).toBe(false);
    expect(canApproveTerm({ status: 'approved', entered_by: 'u1' }, 'u2', true)).toBe(false);
    expect(canApproveTerm({ status: 'draft', entered_by: 'u1' }, null, true)).toBe(false);
  });
  it('only an approved term with no passed end date can be ended', () => {
    expect(canEndTerm({ status: 'approved', effective_to: null }, '2026-11-18', true)).toBe(true);
    expect(canEndTerm({ status: 'approved', effective_to: '2026-06-30' }, '2026-11-18', true)).toBe(false);
    expect(canEndTerm({ status: 'draft', effective_to: null }, '2026-11-18', true)).toBe(false);
    expect(canEndTerm({ status: 'approved', effective_to: null }, '2026-11-18', false)).toBe(false);
  });
});
