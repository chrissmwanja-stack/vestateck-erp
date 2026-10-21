import { describe, expect, it } from 'vitest';
import type { CommissionEntry, Policy } from './types';
import {
  buildCommissionStatement,
  canUnapproveClaim,
  claimRemainingToPay,
  isClaimApprovalBlockedFor,
  commissionSplit,
  daysBetween,
  formatMoney,
  friendlyError,
  isClaimOpen,
  isClaimTransitionAllowed,
  nextClaimStatuses,
  policyTermDays,
  renewalBucket,
  statementCurrencies,
  validateClaimMoneyInput,
  validatePolicyInput,
  validateStatementPeriod,
} from './logic';

// The claim map here must match ins_transition_claim() in
// supabase/migrations/20261010100000_insurance_brokerage_core.sql.
describe('claim lifecycle (mirrors ins_transition_claim)', () => {
  it('allows only the documented moves', () => {
    expect(isClaimTransitionAllowed('notified', 'assessing')).toBe(true);
    expect(isClaimTransitionAllowed('notified', 'repudiated')).toBe(true);
    expect(isClaimTransitionAllowed('assessing', 'approved')).toBe(true);
    expect(isClaimTransitionAllowed('approved', 'settled')).toBe(true);
    expect(isClaimTransitionAllowed('settled', 'closed')).toBe(true);
    expect(isClaimTransitionAllowed('repudiated', 'closed')).toBe(true);
  });

  it('refuses skips, reversals and moves out of closed', () => {
    expect(isClaimTransitionAllowed('notified', 'approved')).toBe(false);
    expect(isClaimTransitionAllowed('repudiated', 'approved')).toBe(false);
    expect(nextClaimStatuses('closed')).toEqual([]);
  });

  it('allows un-approval back to assessing, but only through the rule below', () => {
    expect(isClaimTransitionAllowed('approved', 'assessing')).toBe(true);
  });

  it('blocks the registrant from approving their own claim, and only them', () => {
    expect(isClaimApprovalBlockedFor({ created_by: 'u1' }, 'u1')).toBe(true);
    expect(isClaimApprovalBlockedFor({ created_by: 'u1' }, 'u2')).toBe(false);
    expect(isClaimApprovalBlockedFor({ created_by: 'u1' }, null)).toBe(false);
    expect(isClaimApprovalBlockedFor({ created_by: null }, 'u1')).toBe(false);
  });

  it('offers un-approval only to a manager, before recognition and before any payment', () => {
    const base = { status: 'approved' as const, recognised_at: null, paid_amount: 0 };
    expect(canUnapproveClaim(base, true)).toBe(true);
    expect(canUnapproveClaim(base, false)).toBe(false);
    expect(canUnapproveClaim({ ...base, recognised_at: '2026-10-17T10:00:00Z' }, true)).toBe(false);
    expect(canUnapproveClaim({ ...base, paid_amount: 100 }, true)).toBe(false);
    expect(canUnapproveClaim({ ...base, status: 'assessing' }, true)).toBe(false);
  });

  it('treats only notified, assessing and approved as open', () => {
    expect(isClaimOpen('notified')).toBe(true);
    expect(isClaimOpen('approved')).toBe(true);
    expect(isClaimOpen('settled')).toBe(false);
    expect(isClaimOpen('repudiated')).toBe(false);
    expect(isClaimOpen('closed')).toBe(false);
  });
});

describe('commission split (preview of ins_bind_policy)', () => {
  it('splits gross into commission and net to insurer', () => {
    expect(commissionSplit(1_200_000, 10)).toEqual({ commission: 120_000, net: 1_080_000 });
  });

  it('handles zero commission and rounds to 2dp without losing a cent', () => {
    expect(commissionSplit(500_000, 0)).toEqual({ commission: 0, net: 500_000 });
    const s = commissionSplit(1000.01, 12.5);
    expect(s.commission + s.net).toBeCloseTo(1000.01, 2);
    expect(Number.isInteger(Math.round(s.commission * 100))).toBe(true);
  });
});

describe('renewal pipeline buckets', () => {
  it('buckets by days to expiry', () => {
    expect(renewalBucket(-1)).toBe('overdue');
    expect(renewalBucket(0)).toBe('d0_30');
    expect(renewalBucket(30)).toBe('d0_30');
    expect(renewalBucket(31)).toBe('d31_60');
    expect(renewalBucket(90)).toBe('d61_90');
    expect(renewalBucket(120)).toBe('d91_120');
    expect(renewalBucket(121)).toBe('later');
  });
});

describe('dates', () => {
  it('counts whole days regardless of month and leap boundaries', () => {
    expect(daysBetween('2026-01-01', '2026-01-31')).toBe(30);
    expect(daysBetween('2028-02-28', '2028-03-01')).toBe(2); // leap year
    expect(daysBetween('2026-03-01', '2026-02-28')).toBe(-1);
  });

  it('measures a policy term in days', () => {
    expect(policyTermDays('2026-06-01', '2027-05-31')).toBe(364);
  });
});

describe('validatePolicyInput', () => {
  const ok = {
    clientId: 'c',
    insurerId: 'i',
    productLineId: 'p',
    inception: '2026-06-01',
    expiry: '2027-05-31',
    sumInsured: 1,
    grossPremium: 0,
    commissionRatePct: 10,
  };

  it('accepts a valid draft', () => {
    expect(validatePolicyInput(ok)).toEqual([]);
  });

  it('reports every problem, not just the first', () => {
    const errs = validatePolicyInput({ ...ok, clientId: '', expiry: '2026-06-01', commissionRatePct: 100 });
    expect(errs).toEqual(
      expect.arrayContaining(['Choose a client.', 'Expiry must be after inception.', 'Commission must be at least 0% and below 100%.']),
    );
  });
});

describe('formatting', () => {
  it('formats UGX with no decimals for whole amounts and dashes for missing values', () => {
    expect(formatMoney(1200000)).toMatch(/1,200,000/);
    expect(formatMoney(null)).toBe('-');
    expect(formatMoney(undefined)).toBe('-');
  });

  it('strips the server error code for display', () => {
    expect(friendlyError('INS_NOT_DRAFT: policy POL-2026-00001 is already active')).toBe(
      'policy POL-2026-00001 is already active',
    );
    expect(friendlyError('new row violates row-level security policy')).toBe('new row violates row-level security policy');
  });
});


// These mirror ins_record_claim_payment / ins_record_claim_receipt /
// ins_record_claim_payout in supabase/migrations/20261013090000_ins_claim_payments.sql.
describe('claim payment helpers', () => {
  const base = {
    amount: 100, max: 500, currency: 'UGX', date: '2026-10-13', todayIso: '2026-10-13',
    notifiedIso: '2026-10-01', reference: 'REF-1', bankId: 'bank-1',
  };

  it('works out what is still unpaid and never goes below zero', () => {
    expect(claimRemainingToPay(1000, 400)).toBe(600);
    expect(claimRemainingToPay(1000, 1000)).toBe(0);
    expect(claimRemainingToPay(null, 0)).toBe(0);
    expect(claimRemainingToPay(0.3, 0.1)).toBe(0.2);
  });

  it('accepts a valid insurer-direct payment without a bank account', () => {
    expect(validateClaimMoneyInput({ ...base, kind: 'direct', bankId: '' })).toEqual([]);
  });

  it('requires the insurer reference for a direct payment, because nothing else evidences it', () => {
    const errors = validateClaimMoneyInput({ ...base, kind: 'direct', reference: '  ' });
    expect(errors).toHaveLength(1);
    expect(errors[0]).toMatch(/reference/i);
  });

  it('requires a client-money bank account for a receipt and a payout, not a reference', () => {
    expect(validateClaimMoneyInput({ ...base, kind: 'receipt', bankId: '', reference: '' })).toHaveLength(1);
    expect(validateClaimMoneyInput({ ...base, kind: 'payout', bankId: '', reference: '' })).toHaveLength(1);
    expect(validateClaimMoneyInput({ ...base, kind: 'receipt', reference: '' })).toEqual([]);
    expect(validateClaimMoneyInput({ ...base, kind: 'payout', reference: '' })).toEqual([]);
  });

  it('rejects zero, negative and over-limit amounts, with a message per kind', () => {
    expect(validateClaimMoneyInput({ ...base, kind: 'direct', amount: 0 })[0]).toMatch(/above zero/i);
    expect(validateClaimMoneyInput({ ...base, kind: 'direct', amount: -5 })[0]).toMatch(/above zero/i);
    expect(validateClaimMoneyInput({ ...base, kind: 'direct', amount: 501 })[0]).toMatch(/still unpaid/i);
    expect(validateClaimMoneyInput({ ...base, kind: 'receipt', amount: 501 })[0]).toMatch(/insurer owes/i);
    expect(validateClaimMoneyInput({ ...base, kind: 'payout', amount: 501 })[0]).toMatch(/received from the insurer/i);
    expect(validateClaimMoneyInput({ ...base, kind: 'payout', amount: 500 })).toEqual([]);
  });

  it('rejects a future date and a date before the claim was notified', () => {
    expect(validateClaimMoneyInput({ ...base, kind: 'direct', date: '2026-10-14' })[0]).toMatch(/future/i);
    expect(validateClaimMoneyInput({ ...base, kind: 'direct', date: '2026-09-30' })[0]).toMatch(/before the claim was notified/i);
    expect(validateClaimMoneyInput({ ...base, kind: 'direct', date: '' })[0]).toMatch(/choose a date/i);
  });
});

describe('commission statement per insurer', () => {
  const policy = (over: Partial<Policy>): Policy => ({
    id: 'p1', policy_no: 'POL-1', status: 'active', client_id: 'c1', insurer_id: 'i1', product_line_id: 'pl1',
    branch_id: null, agent_id: null, transaction_type: 'new_business',
    inception_date: '2026-10-01', expiry_date: '2027-10-01', sum_insured: 0, currency: 'UGX',
    gross_premium: 1000, commission_rate_pct: 10, commission_amount: 100, net_premium_to_insurer: 900,
    bound_at: '2026-10-05T08:00:00Z', journal_entry_id: null, renewal_of_id: null, risk_description: null, notes: null,
    ins_clients: { bd_clients: { name: 'Acme' } },
    ...over,
  });
  const entry = (over: Partial<CommissionEntry>): CommissionEntry => ({
    id: 'e1', tenant_id: 't', policy_id: 'p1', policy_no: 'POL-1', insurer_id: 'i1', client_id: 'c1', amount: 100,
    status: 'deferred', earned_on: null, transfer_id: null, transfer_no: null, transfer_date: null,
    created_at: '', updated_at: '', ...over,
  });
  const period = { from: '2026-10-01', to: '2026-10-31' };

  it('includes only bound policies inside the period, inclusive of both end dates', () => {
    const policies = [
      policy({ id: 'a', policy_no: 'A', bound_at: '2026-10-01T00:00:00Z' }),
      policy({ id: 'b', policy_no: 'B', bound_at: '2026-10-31T23:59:00Z' }),
      policy({ id: 'c', policy_no: 'C', bound_at: '2026-09-30T23:59:00Z' }),
      policy({ id: 'd', policy_no: 'D', bound_at: '2026-11-01T00:00:00Z' }),
      policy({ id: 'e', policy_no: 'E', status: 'draft', bound_at: null }),
    ];
    expect(buildCommissionStatement(policies, [], period).rows.map((r) => r.policy_no)).toEqual(['A', 'B']);
  });

  it('takes status and transfer details from the ledger and totals each status separately', () => {
    const policies = [
      policy({ id: 'a', policy_no: 'A', commission_amount: 100 }),
      policy({ id: 'b', policy_no: 'B', commission_amount: 50, gross_premium: 500, net_premium_to_insurer: 450 }),
      policy({ id: 'c', policy_no: 'C', commission_amount: 20, gross_premium: 200, net_premium_to_insurer: 180 }),
    ];
    const ledger = [
      entry({ id: 'ea', policy_id: 'a', amount: 100, status: 'deferred' }),
      entry({ id: 'eb', policy_id: 'b', amount: 50, status: 'earned', earned_on: '2026-10-10' }),
      entry({ id: 'ec', policy_id: 'c', amount: 20, status: 'transferred', earned_on: '2026-10-10', transfer_id: 't1', transfer_no: 'CT-1', transfer_date: '2026-10-12' }),
    ];
    const { rows, totals } = buildCommissionStatement(policies, ledger, period);
    expect(rows.map((r) => r.status)).toEqual(['deferred', 'earned', 'transferred']);
    expect(rows[2]).toMatchObject({ transfer_no: 'CT-1', transfer_date: '2026-10-12', earned_on: '2026-10-10' });
    expect(totals).toMatchObject({
      policies: 3, gross_premium: 1700, net_premium: 1530, commission: 170,
      deferred: 100, earned: 50, transferred: 20, legacy: 0,
    });
  });

  it('shows policies bound before commission deferral as legacy, so every bound policy is accounted for', () => {
    const { rows, totals } = buildCommissionStatement([policy({ commission_amount: 100 })], [], period);
    expect(rows[0].status).toBe('legacy');
    expect(rows[0].commission).toBe(100);
    expect(totals.legacy).toBe(100);
    expect(totals.deferred + totals.earned + totals.transferred + totals.legacy).toBe(totals.commission);
  });

  it('refuses to total more than one currency', () => {
    const policies = [policy({ id: 'a' }), policy({ id: 'b', policy_no: 'B', currency: 'USD' })];
    expect(() => buildCommissionStatement(policies, [], period)).toThrow(/more than one currency/);
  });

  it('builds a statement for one chosen currency, leaving the others out of the totals', () => {
    const policies = [
      policy({ id: 'a', commission_amount: 100 }),
      policy({ id: 'b', policy_no: 'B', currency: 'USD', commission_amount: 7 }),
      policy({ id: 'c', policy_no: 'C', currency: 'USD', commission_amount: 3 }),
    ];
    const usd = buildCommissionStatement(policies, [], period, 'USD');
    expect(usd.rows.map((r) => r.policy_no)).toEqual(['B', 'C']);
    expect(usd.totals.commission).toBe(10);
    expect(buildCommissionStatement(policies, [], period, 'UGX').totals.commission).toBe(100);
  });

  it('lists the currencies in a period, most used first, ignoring drafts and policies outside it', () => {
    const policies = [
      policy({ id: 'a' }),
      policy({ id: 'b', currency: 'USD' }),
      policy({ id: 'c', currency: 'USD' }),
      policy({ id: 'd', currency: 'EUR', status: 'draft' }),
      policy({ id: 'e', currency: 'KES', bound_at: '1999-01-01T00:00:00Z' }),
    ];
    expect(statementCurrencies(policies, period)).toEqual(['USD', 'UGX']);
  });

  it('keeps totals free of floating point drift', () => {
    const policies = [0.1, 0.2].map((c, i) => policy({ id: `p${i}`, policy_no: `P${i}`, commission_amount: c }));
    expect(buildCommissionStatement(policies, [], period).totals.commission).toBe(0.3);
  });

  it('returns an empty statement when nothing was bound in the period', () => {
    const { rows, totals } = buildCommissionStatement([], [], period);
    expect(rows).toEqual([]);
    expect(totals.commission).toBe(0);
  });

  it('validates the period', () => {
    expect(validateStatementPeriod('', '2026-10-31')).toMatch(/both/);
    expect(validateStatementPeriod('2026-11-01', '2026-10-31')).toMatch(/after/);
    expect(validateStatementPeriod('2026-10-01', '2026-10-31')).toBeNull();
  });
});


describe('reversed policy statement history', () => {
  it('labels reversed policies and excludes their original amounts from active totals', () => {
    const p = { id: 'reversed', policy_no: 'OLD-1', status: 'reversed', bound_at: '2026-10-10T08:00:00Z',
      currency: 'UGX', gross_premium: 1000, net_premium_to_insurer: 900, commission_amount: 100 } as Policy;
    const statement = buildCommissionStatement([p], [], { from: '2026-10-01', to: '2026-10-31' });
    expect(statement.rows[0].status).toBe('reversed');
    expect(statement.totals.gross_premium).toBe(0);
    expect(statement.totals.commission).toBe(0);
    expect(statement.totals.reversed).toBe(100);
  });
});
