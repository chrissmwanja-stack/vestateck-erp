import { isTransferable } from '../logic';
import type { CommissionEntry } from '../types';
import { describe, expect, it } from 'vitest';
import {
  cashActions,
  cashMaximum,
  parseCashContext,
  validateCashAmount,
  type CancellationCashContext,
  type CancellationCashRequest,
} from './cashWorkflow';
const row = {
  id: 'request',
  maker_id: 'maker',
  status: 'pending',
  kind: 'refund',
} as CancellationCashRequest;
describe('cancellation cash hints never grant authority', () => {
  it('keeps Insurance read-only even when its user also has Finance membership', () =>
    expect(
      cashActions({ actor_id: 'checker', can_finance: true }, row, 'view'),
    ).toEqual([]));
  it('keeps non-Finance users read-only inside the Finance route', () =>
    expect(
      cashActions({ actor_id: 'checker', can_finance: false }, row, 'finance'),
    ).toEqual([]));
  it('does not offer approval to the maker', () =>
    expect(
      cashActions({ actor_id: 'maker', can_finance: true }, row, 'finance'),
    ).toEqual(['cancel']));
  it('offers independent checker actions', () =>
    expect(
      cashActions({ actor_id: 'checker', can_finance: true }, row, 'finance'),
    ).toEqual(['approve', 'reject']));
  it.each(['voided', 'rejected', 'cancelled'] as const)(
    'does not reopen %s requests',
    (status) =>
      expect(
        cashActions(
          { actor_id: 'checker', can_finance: true },
          { ...row, status },
          'finance',
        ),
      ).toEqual([]),
  );
  it('only proposes a void, never performs one immediately', () =>
    expect(
      cashActions(
        { actor_id: 'maker', can_finance: true },
        { ...row, status: 'posted' },
        'finance',
      ),
    ).toEqual(['void']));
  it('does not propose duplicate pending voids', () =>
    expect(
      cashActions(
        { actor_id: 'maker', can_finance: true },
        { ...row, status: 'posted', void_requested: true },
        'finance',
      ),
    ).toEqual([]));
});
describe('exact money and server projections', () => {
  const context = {
    maximum_refund: '50.01',
    client_premium_outstanding: '900',
    insurers: [
      {
        adjustment_id: 'a',
        recovery_due: '450',
        maximum_remittance: '60',
        maximum_commission_return: '25',
        maximum_commission_withdrawal: '30',
      },
    ],
  } as CancellationCashContext;
  it.each([
    ['refund', '50.01'],
    ['premium_receipt', '900'],
    ['recovery', '450'],
    ['remittance', '60'],
    ['commission_return', '25'],
    ['commission_withdrawal', '30'],
  ] as const)('uses the server limit for %s', (kind, value) =>
    expect(cashMaximum(context, kind, 'a')).toBe(value),
  );
  it('does not silently select another insurer', () =>
    expect(cashMaximum(context, 'remittance', 'b')).toBe('0'));
  it('does not round above the allowed final cent', () =>
    expect(() => validateCashAmount('50.02', '50.01')).toThrow());
  it('preserves money above JavaScript safe integer precision', () =>
    expect(() =>
      validateCashAmount('9007199254740993.01', '9007199254740993.01'),
    ).not.toThrow());
  it.each(['0', '1.001', '-1', 'NaN', '1e3'])(
    'rejects invalid or non-exact amount %s',
    (value) => expect(() => validateCashAmount(value, '1000')).toThrow(),
  );
  it('fails closed on a wrong-policy context', () =>
    expect(() =>
      parseCashContext({ policy_id: 'other', available: false }, 'policy'),
    ).toThrow(/different policy/));
  it('does not turn missing RPC data into payment authority', () =>
    expect(() => parseCashContext([], 'policy')).toThrow());
  it('handles a policy without a posted cancellation', () =>
    expect(
      parseCashContext({ policy_id: 'policy', available: false }, 'policy'),
    ).toBeNull());
});

it('does not mix retained cancellation commission into the legacy one-step transfer batch', () => {
  const legacy = { status: 'earned', amount: 100 } as CommissionEntry;
  expect(isTransferable(legacy)).toBe(true);
  expect(isTransferable({ ...legacy, cancellation_id: 'case' })).toBe(false);
});
