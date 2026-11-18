import { describe, expect, it } from 'vitest';
import {
  canApproveRemittance, canPayRemittance, canVoidRemittance, isOpenRemittance, monthBounds, prepareWarning,
  previousMonth, remittanceBlockedReason, sortRemittances, whtCurrencyLines, whtPositionView, whtStillHeld,
  type AgentAccrual, type WhtPosition, type WhtRemittance,
} from './agentCommission';

// The tax position and the return workflow, taken out of the component. The rules
// here are the ones the server enforces; these tests pin the words and the
// ordering the screen uses to explain them.

const remittance = (over: Partial<WhtRemittance> = {}): WhtRemittance => ({
  id: 'r1',
  remittance_no: 'WHT-2026-0001',
  period_start: '2026-10-01',
  period_end: '2026-10-31',
  currency: 'UGX',
  amount: 60000,
  status: 'prepared',
  paid_on: null,
  payment_reference: null,
  prepared_by: 'u-maker',
  approved_by: null,
  approved_at: null,
  ...over,
});

const position = (over: Partial<WhtPosition> = {}): WhtPosition => ({
  withheld_total: 90000,
  reported_total: 60000,
  paid_total: 0,
  unreported: 30000,
  awaiting_payment: 60000,
  remittances: [],
  ...over,
});

describe('the position never shows a negative backlog', () => {
  it('floors an over-reported period at zero and names the excess', () => {
    // A return was filed, then a share behind it was reversed. The filed figure is
    // a fact; the tax it claimed is no longer withheld. The arithmetic gives a
    // negative "unreported", and printing minus thirty thousand would read as
    // negative work to do.
    const v = whtPositionView(position({ withheld_total: 60000, reported_total: 90000, unreported: -30000 }));
    expect(v.unreported_clear).toBe(0);
    expect(v.over_reported).toBe(30000);
  });

  it('reports no excess when the figures agree', () => {
    const v = whtPositionView(position());
    expect(v.over_reported).toBe(0);
    expect(v.unreported_clear).toBe(30000);
  });

  it('leaves everything else alone', () => {
    const v = whtPositionView(position());
    expect(v.withheld_total).toBe(90000);
    expect(v.awaiting_payment).toBe(60000);
    expect(v.paid_total).toBe(0);
  });
});

describe('who may move a return along', () => {
  it('keeps the preparer out of the approval', () => {
    expect(canApproveRemittance(remittance(), 'u-maker', true)).toBe(false);
    expect(canApproveRemittance(remittance(), 'u-checker', true)).toBe(true);
    expect(canApproveRemittance(remittance(), null, true)).toBe(false);
    expect(canApproveRemittance(remittance(), 'u-checker', false)).toBe(false);
  });

  it('approves only what is still waiting for approval', () => {
    expect(canApproveRemittance(remittance({ status: 'approved' }), 'u-checker', true)).toBe(false);
    expect(canApproveRemittance(remittance({ status: 'paid' }), 'u-checker', true)).toBe(false);
  });

  it('pays only what has been approved', () => {
    expect(canPayRemittance(remittance(), true)).toBe(false);
    expect(canPayRemittance(remittance({ status: 'approved' }), true)).toBe(true);
    expect(canPayRemittance(remittance({ status: 'approved' }), false)).toBe(false);
    expect(canPayRemittance(remittance({ status: 'paid' }), true)).toBe(false);
  });

  it('voids an open return but never a paid one', () => {
    expect(canVoidRemittance(remittance(), true)).toBe(true);
    expect(canVoidRemittance(remittance({ status: 'approved' }), true)).toBe(true);
    expect(canVoidRemittance(remittance({ status: 'paid' }), true)).toBe(false);
    expect(canVoidRemittance(remittance({ status: 'void' }), true)).toBe(false);
  });

  it('says why a return cannot be approved', () => {
    expect(remittanceBlockedReason(remittance(), 'u-maker', true)).toMatch(/you prepared/i);
    expect(remittanceBlockedReason(remittance(), 'u-checker', false)).toMatch(/manager/i);
    expect(remittanceBlockedReason(remittance({ status: 'paid' }), 'u-checker', true)).toMatch(/already been paid/i);
    expect(remittanceBlockedReason(remittance(), 'u-checker', true)).toBeNull();
  });

  it('treats prepared and approved as open, and nothing else', () => {
    expect(isOpenRemittance(remittance())).toBe(true);
    expect(isOpenRemittance(remittance({ status: 'approved' }))).toBe(true);
    expect(isOpenRemittance(remittance({ status: 'paid' }))).toBe(false);
    expect(isOpenRemittance(remittance({ status: 'void' }))).toBe(false);
  });
});

describe('a tax ledger is read forwards', () => {
  it('puts open returns above settled ones, then oldest period first', () => {
    const sorted = sortRemittances([
      remittance({ id: 'new-paid', remittance_no: 'WHT-2026-0004', status: 'paid', period_start: '2026-01-01' }),
      remittance({ id: 'sep', remittance_no: 'WHT-2026-0003', period_start: '2026-09-01' }),
      remittance({ id: 'jul', remittance_no: 'WHT-2026-0001', period_start: '2026-07-01' }),
      remittance({ id: 'aug', remittance_no: 'WHT-2026-0002', status: 'approved', period_start: '2026-08-01' }),
    ]);
    expect(sorted.map((r) => r.id)).toEqual(['jul', 'aug', 'sep', 'new-paid']);
  });
});

describe('the default period is a month that has closed', () => {
  it('defaults to the month before the current one', () => {
    const last = previousMonth(new Date(2026, 10, 16)); // 16 Nov 2026
    const b = monthBounds(last);
    expect(b.start).toBe('2026-10-01');
    expect(b.end).toBe('2026-10-31');
    expect(b.label).toBe('October 2026');
  });

  it('gets month ends right in February without arithmetic on days', () => {
    expect(monthBounds(new Date(2026, 1, 10)).end).toBe('2026-02-28');
    expect(monthBounds(new Date(2028, 1, 10)).end).toBe('2028-02-29');
  });

  it('crosses the year boundary correctly', () => {
    const b = monthBounds(previousMonth(new Date(2026, 0, 15))); // Jan 2026 -> Dec 2025
    expect(b.start).toBe('2025-12-01');
    expect(b.end).toBe('2025-12-31');
  });

  it('warns before preparing the month we are still in', () => {
    expect(prepareWarning('2026-10-31', new Date(2026, 10, 16))).toBeNull();
    expect(prepareWarning('2026-11-30', new Date(2026, 10, 16))).toMatch(/has not finished/i);
    // The last day of the month is still the current month until it ends.
    expect(prepareWarning('2026-11-16', new Date(2026, 10, 16))).toMatch(/has not finished/i);
    expect(prepareWarning('2026-11-15', new Date(2026, 10, 16))).toBeNull();
  });
});

describe('the position is per currency', () => {
  it('uses the server split when there is one', () => {
    const lines = whtCurrencyLines(position({
      by_currency: [
        { currency: 'UGX', withheld_total: 90000, reported_total: 60000, paid_total: 0, unreported: 30000, unreported_open: 30000, over_reported: 0, awaiting_payment: 60000 },
        { currency: 'USD', withheld_total: 500, reported_total: 500, paid_total: 500, unreported: 0, unreported_open: 0, over_reported: 0, awaiting_payment: 0 },
      ],
    }));
    expect(lines.map((l) => l.currency)).toEqual(['UGX', 'USD']);
    expect(lines[1].paid_total).toBe(500);
  });

  it('falls back to one line from the flat figures for an older server', () => {
    const lines = whtCurrencyLines(position({ unreported: -30000, withheld_total: 60000, reported_total: 90000 }));
    expect(lines).toHaveLength(1);
    expect(lines[0].unreported_open).toBe(0);
    expect(lines[0].over_reported).toBe(30000);
  });

  it('never adds one currency to another', () => {
    // 500 USD and 900,000 UGX are two answers. A single total here would be a
    // number that means nothing, so the split is the only shape offered.
    const lines = whtCurrencyLines(position({
      by_currency: [
        { currency: 'UGX', withheld_total: 900000, reported_total: 0, paid_total: 0, unreported: 900000, unreported_open: 900000, over_reported: 0, awaiting_payment: 0 },
        { currency: 'USD', withheld_total: 500, reported_total: 0, paid_total: 0, unreported: 500, unreported_open: 500, over_reported: 0, awaiting_payment: 0 },
      ],
    }));
    expect(lines).toHaveLength(2);
    expect(lines.map((l) => l.withheld_total)).toEqual([900000, 500]);
  });
});

describe('the Overview counts held tax, not tax ever withheld', () => {
  const accrual = (over: Partial<AgentAccrual> = {}): AgentAccrual => ({
    id: 'a1', policy_id: 'p1', intermediary_id: 'i1', basis: 'pct_of_broker_commission',
    gross_amount: 300000, wht_amount: 30000, net_amount: 270000, currency: 'UGX', status: 'paid',
    eligible_on: null, paid_at: null, created_at: '2026-11-01T00:00:00Z',
    updated_at: '2026-11-01T00:00:00Z', ...over,
  });

  it('stops counting tax whose return has been paid', () => {
    const held = whtStillHeld(
      [accrual({ id: 'a1' }), accrual({ id: 'a2' })],
      [{ accrual_id: 'a1', amount: 30000, remittance_id: 'r1' }],
      [{ id: 'r1', status: 'paid' }],
    );
    // a1's tax has gone to URA; a2's has not been reported at all.
    expect(held.UGX).toBe(30000);
  });

  it('keeps counting tax on a return that is only prepared or approved', () => {
    for (const status of ['prepared', 'approved'] as const) {
      const held = whtStillHeld(
        [accrual({ id: 'a1' }), accrual({ id: 'a2' })],
        [{ accrual_id: 'a1', amount: 30000, remittance_id: 'r1' }],
        [{ id: 'r1', status }],
      );
      // The money has not moved, and a return waiting for a signature is exactly
      // the thing that gets forgotten.
      expect(held.UGX).toBe(60000);
    }
  });

  it('ignores reversed shares and shares with no tax', () => {
    const held = whtStillHeld(
      [accrual({ id: 'a1', status: 'reversed' }), accrual({ id: 'a2', wht_amount: 0 }), accrual({ id: 'a3' })],
      [],
      [],
    );
    expect(held.UGX).toBe(30000);
  });

  it('keeps currencies apart', () => {
    const held = whtStillHeld(
      [accrual({ id: 'a1' }), accrual({ id: 'a2', currency: 'USD', wht_amount: 50, gross_amount: 500, net_amount: 450 })],
      [],
      [],
    );
    expect(held).toEqual({ UGX: 30000, USD: 50 });
  });
});
