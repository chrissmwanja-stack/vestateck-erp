import { describe, expect, it } from 'vitest';
import {
  approvalBlockedReason, canApprovePayment, canCancelPayment, canRejectPayment, canReleasePayment,
  isActionable, paymentQueueTotals, paymentSummary, sortPayments, type AgentPayment,
} from './agentCommission';

// The payment queue's rules, taken out of the component so they can be tested
// without a browser. The single most important one: nobody approves their own
// payment.

const payment = (over: Partial<AgentPayment> = {}): AgentPayment => ({
  id: 'pay1',
  tenant_id: 't1',
  accrual_id: 'a1',
  bank_account_id: 'b1',
  currency: 'UGX',
  gross_amount: 300000,
  wht_amount: 30000,
  wht_rate_pct: 10,
  wht_is_final: true,
  wht_parameter_ref: 'param-1',
  net_amount: 270000,
  paid_on: '2026-11-15',
  note: null,
  status: 'prepared',
  prepared_by: 'u-maker',
  prepared_at: '2026-11-14T09:00:00Z',
  approved_by: null,
  approved_at: null,
  payment_journal_entry_id: null,
  ...over,
});

const approved = (over: Partial<AgentPayment> = {}) =>
  payment({ status: 'approved', approved_by: 'u-checker', approved_at: '2026-11-14T11:00:00Z', ...over });

describe('the maker cannot be the checker', () => {
  it('hides approval from the person who prepared the payment', () => {
    const p = payment();
    expect(canApprovePayment(p, 'u-maker', true)).toBe(false);
    expect(canApprovePayment(p, 'u-checker', true)).toBe(true);
  });

  it('treats an unknown current user as not allowed rather than allowed', () => {
    // If the session has not resolved we do not know who is looking. Offering the
    // button would be a guess, and the guess is the one that self-approves.
    expect(canApprovePayment(payment(), null, true)).toBe(false);
  });

  it('requires the manager tier, not merely a logged-in user', () => {
    expect(canApprovePayment(payment(), 'u-checker', false)).toBe(false);
  });

  it('only approves a payment that is still waiting for approval', () => {
    expect(canApprovePayment(approved(), 'u-checker', true)).toBe(false);
    expect(canApprovePayment(payment({ status: 'paid' }), 'u-checker', true)).toBe(false);
    expect(canApprovePayment(payment({ status: 'rejected' }), 'u-checker', true)).toBe(false);
    expect(canApprovePayment(payment({ status: 'cancelled' }), 'u-checker', true)).toBe(false);
  });

  it('only releases what has been approved', () => {
    expect(canReleasePayment(payment(), true)).toBe(false);
    expect(canReleasePayment(approved(), true)).toBe(true);
    expect(canReleasePayment(approved(), false)).toBe(false);
    expect(canReleasePayment(approved({ status: 'paid' }), true)).toBe(false);
  });

  it('lets only the preparer withdraw their own proposal', () => {
    expect(canCancelPayment(payment(), 'u-maker', true)).toBe(true);
    expect(canCancelPayment(payment(), 'u-other', true)).toBe(false);
    expect(canCancelPayment(payment(), 'u-maker', false)).toBe(false);
    expect(canCancelPayment(approved(), 'u-maker', true)).toBe(false);
  });

  it('declines only what has not been decided yet', () => {
    expect(canRejectPayment(payment(), true)).toBe(true);
    expect(canRejectPayment(payment(), false)).toBe(false);
    // The server refuses to decline an authorised payment: once a second manager
    // has signed it off, the way to undo a release is to reverse the share, not to
    // rewrite the authorisation. Offering the button here would promise something
    // the database will not do.
    expect(canRejectPayment(approved(), true)).toBe(false);
    expect(canRejectPayment(payment({ status: 'paid' }), true)).toBe(false);
    expect(canRejectPayment(payment({ status: 'rejected' }), true)).toBe(false);
    expect(canRejectPayment(payment({ status: 'cancelled' }), true)).toBe(false);
  });
});

describe('a disabled button says why', () => {
  it('names the reason rather than leaving the user to guess', () => {
    expect(approvalBlockedReason(payment(), 'u-maker', true)).toMatch(/you prepared/i);
  });

  it('says nothing when there is nothing blocking', () => {
    expect(approvalBlockedReason(payment(), 'u-checker', true)).toBeNull();
  });

  it('explains a permission problem as a permission problem', () => {
    expect(approvalBlockedReason(payment(), 'u-checker', false)).toMatch(/manager/i);
  });

  it('explains a state problem as a state problem', () => {
    expect(approvalBlockedReason(approved(), 'u-checker', true)).toMatch(/already/i);
  });
});

describe('the queue totals keep currencies apart', () => {
  it('buckets net cash by status and never adds shillings to dollars', () => {
    const totals = paymentQueueTotals([
      payment(),
      payment({ id: 'pay2', net_amount: 100, currency: 'USD', gross_amount: 110, wht_amount: 10 }),
      approved(),
      payment({ id: 'pay3', status: 'paid', net_amount: 50000 }),
      payment({ id: 'pay4', status: 'rejected', net_amount: 999999 }),
      payment({ id: 'pay5', status: 'cancelled', net_amount: 888888 }),
    ]);
    // Net, not gross: this tile answers "how much cash is going out", and the
    // withheld tax is never cash that leaves the bank account.
    expect(totals.prepared.UGX).toBe(270000);
    expect(totals.prepared.USD).toBe(100);
    expect(totals.approved.UGX).toBe(270000);
    expect(totals.paid.UGX).toBe(50000);
    // Declined and withdrawn proposals are not money that is going anywhere, so
    // there is no bucket for them at all -- not a bucket holding zero.
    expect(Object.keys(totals).sort()).toEqual(['approved', 'paid', 'prepared']);
  });

  it('reports nothing for an empty queue', () => {
    expect(paymentQueueTotals([])).toEqual({ prepared: {}, approved: {}, paid: {} });
  });
});

describe('ordering and actionability', () => {
  it('puts what needs action first, longest-waiting at the top', () => {
    const sorted = sortPayments([
      // The oldest row in the list is settled, so a plain date sort would put it
      // at the top and bury the work underneath it.
      payment({ id: 'paid', status: 'paid', prepared_at: '2026-11-01T09:00:00Z' }),
      payment({ id: 'new', prepared_at: '2026-11-15T09:00:00Z' }),
      approved({ id: 'appr', prepared_at: '2026-11-12T09:00:00Z' }),
      payment({ id: 'old', prepared_at: '2026-11-10T09:00:00Z' }),
    ]);
    expect(sorted.map((p) => p.id)).toEqual(['old', 'appr', 'new', 'paid']);
  });

  it('counts prepared and approved as still needing somebody', () => {
    expect(isActionable(payment())).toBe(true);
    expect(isActionable(approved())).toBe(true);
    expect(isActionable(payment({ status: 'paid' }))).toBe(false);
    expect(isActionable(payment({ status: 'rejected' }))).toBe(false);
    expect(isActionable(payment({ status: 'cancelled' }))).toBe(false);
  });
});

describe('the one-line summary carries the tax character', () => {
  it('shows gross, withholding at its rate, and net', () => {
    const line = paymentSummary(payment());
    expect(line).toContain('300,000');
    expect(line).toContain('30,000');
    expect(line).toContain('270,000');
    expect(line).toMatch(/10%/);
    expect(line).toMatch(/final/i);
  });

  it('distinguishes on-account withholding from final tax', () => {
    expect(paymentSummary(payment({ wht_is_final: false }))).toMatch(/on account/i);
  });

  it('says plainly when no tax was withheld, instead of printing a zero rate', () => {
    const line = paymentSummary(payment({ wht_amount: 0, net_amount: 300000, wht_rate_pct: null, wht_is_final: null }));
    expect(line).toMatch(/nothing withheld/i);
    expect(line).toContain('300,000');
  });
});
