import { describe, expect, it } from 'vitest';
import {
  cancellationCaseActions,
  cancellationPayload,
  newTermsDraft,
  parseShortPeriodBands,
  type CancellationCase,
  type CancellationContext,
} from './workflow';
const row = {
  status: 'prepared',
  proposed_by: 'manager',
  prepared_by: 'maker',
} as CancellationCase;
describe('cancellation authorization hints', () => {
  it('never lets the Finance maker approve their own preparation', () =>
    expect(
      cancellationCaseActions({ actor_id: 'maker', can_finance: true }, row),
    ).toEqual(['prepare']));
  it('never lets the proposer approve their own proposal', () =>
    expect(
      cancellationCaseActions({ actor_id: 'manager', can_finance: true }, row),
    ).toEqual(['withdraw']));
  it('offers approval only to an independent Finance checker', () =>
    expect(
      cancellationCaseActions({ actor_id: 'checker', can_finance: true }, row),
    ).toEqual(['reject', 'approve']));
  it('keeps Insurance cash/Finance review read-only', () =>
    expect(
      cancellationCaseActions({ actor_id: 'reader', can_finance: false }, row),
    ).toEqual([]));
  it.each(['posted', 'rejected', 'withdrawn'] as const)(
    'does not offer mutable actions on %s evidence',
    (status) =>
      expect(
        cancellationCaseActions(
          { actor_id: 'checker', can_finance: true },
          { ...row, status },
        ),
      ).toEqual([]),
  );
});
describe('contract input construction', () => {
  const context = {
    policy_id: 'policy',
    insurers: [
      {
        insurer_id: 'A',
        insurer_name: 'Alpha',
        premium_amount: '600',
        commission_rate_pct: '10',
      },
    ],
    charges: [],
  } as unknown as CancellationContext;
  const terms = {
    A: {
      ...newTermsDraft(),
      method: 'pro_rata' as const,
      reference: 'Contract clause permits pro-rata',
      prorataPermitted: true,
    },
  };
  it('does not send caller-supplied original premium or commission rates', () => {
    const payload = cancellationPayload(
      context,
      '2026-10-15',
      'Agreed cancellation',
      terms,
      {},
    );
    expect(payload.p_insurer_terms).toEqual([
      {
        insurer_id: 'A',
        terms: {
          method: 'pro_rata',
          contract_reference: 'Contract clause permits pro-rata',
          minimum_retained_premium: '0',
          pro_rata_permitted: true,
        },
      },
    ]);
    expect(JSON.stringify(payload)).not.toContain('commission_rate_pct');
  });
  it('requires affirmative permission for pro-rata', () =>
    expect(() =>
      cancellationPayload(
        context,
        '2026-10-15',
        'Agreed cancellation',
        { A: { ...terms.A, prorataPermitted: false } },
        {},
      ),
    ).toThrow(/permission/));
  it('requires one insurer-specific contract reference', () =>
    expect(() =>
      cancellationPayload(context, '2026-10-15', 'Agreed cancellation', {}, {}),
    ).toThrow(/Alpha/));
  it('does not set an exception-approved flag in a manual proposal', () => {
    const p = cancellationPayload(
      context,
      '2026-10-15',
      'Agreed cancellation',
      { A: { ...terms.A, method: 'manual_review', manualReturn: '300' } },
      {},
    );
    expect(p.p_insurer_terms[0].terms).not.toHaveProperty(
      'finance_exception_approved',
    );
  });
  it('keeps explicit zero charge decisions instead of dropping them', () => {
    const c = {
      ...context,
      charges: [
        {
          id: 'fee',
          kind: 'broker_fee',
          description: 'Service fee',
          amount: '50',
          vat_amount: '0',
          original_allocations: [],
        },
      ],
    } as CancellationContext;
    expect(
      cancellationPayload(c, '2026-10-15', 'Agreed cancellation', terms, {
        fee: {
          refund: '0',
          basis: 'Fee contractually retained',
          confirmed: true,
          recipients: {},
        },
      }).p_charge_refunds,
    ).toHaveLength(1);
  });
  it('requires a separate decision for every pass-through recipient', () => {
    const c = {
      ...context,
      charges: [
        {
          id: 'pass',
          kind: 'insurer_pass_through',
          description: 'Shared charge',
          amount: '100',
          vat_amount: '0',
          original_allocations: [
            { insurer_id: 'A', insurer_name: 'Alpha', amount: '60' },
            { insurer_id: 'B', insurer_name: 'Beta', amount: '40' },
          ],
        },
      ],
    } as CancellationContext;
    expect(() =>
      cancellationPayload(c, '2026-10-15', 'Agreed cancellation', terms, {
        pass: {
          refund: '0',
          basis: 'Contractual basis recorded',
          confirmed: true,
          recipients: { A: { refund: '0', basis: 'Alpha retains charge' } },
        },
      }),
    ).toThrow(/recipient/);
  });
  it('parses supplied short-period schedules without inventing bands', () =>
    expect(parseShortPeriodBands('30:20\n90 : 50\n366:100')).toEqual([
      { through_day: 30, retained_pct: '20' },
      { through_day: 90, retained_pct: '50' },
      { through_day: 366, retained_pct: '100' },
    ]));
  it.each(['', 'one month:10', '-1:20', '30:12.34567'])(
    'rejects malformed schedule %s',
    (value) => expect(() => parseShortPeriodBands(value)).toThrow(),
  );
});
