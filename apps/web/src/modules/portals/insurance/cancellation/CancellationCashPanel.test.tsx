import {
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, expect, it, vi } from 'vitest';
import CancellationCashPanel from './CancellationCashPanel';
import type {
  CancellationCashContext,
  CancellationCashRequest,
} from './cashWorkflow';
const { rpc } = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('../db', () => ({
  rpc,
  errorText: (e: unknown) => (e instanceof Error ? e.message : String(e)),
}));
const pending = {
  id: 'request',
  kind: 'refund',
  status: 'pending',
  amount: '50.01',
  cash_date: '2026-10-15',
  reference: 'REFUND-VERIFIED',
  notes: 'Verified client beneficiary',
  maker_id: 'maker',
  checker_id: null,
  settlement_id: null,
  to_settlement_id: null,
  matched: false,
  destination_matched: false,
  journals: [],
} as unknown as CancellationCashRequest;
let context: CancellationCashContext;
const mount = (mode: 'finance' | 'view' = 'finance') =>
  render(
    <MemoryRouter>
      <CancellationCashPanel policyId="policy" mode={mode} />
    </MemoryRouter>,
  );
beforeEach(() => {
  rpc.mockReset();
  context = {
    policy_id: 'policy',
    available: true,
    cancellation_id: 'case',
    cancellation_no: 'CXL-1',
    currency: 'UGX',
    actor_id: 'checker',
    can_finance: true,
    selected_bank_id: null,
    proven_cash: '1000',
    bank_proven_cash: '1000',
    bank_book_cash: '1000',
    client_refund_outstanding: '50.01',
    client_premium_outstanding: '0',
    retained_fee_vat_reserve: '0',
    commission_reserve: '0',
    insurer_payable_reserve: '0',
    maximum_refund: '50.01',
    insurers: [],
    requests: [pending],
    banks: [
      {
        id: 'trust',
        name: 'Client trust',
        kind: 'client_money',
        currency: 'UGX',
      },
      {
        id: 'operating',
        name: 'Operating',
        kind: 'operating',
        currency: 'UGX',
      },
    ],
    offset: 0,
    has_more: false,
  };
  rpc.mockImplementation(
    async (name: string, args?: Record<string, unknown>) =>
      name === 'ins_cancellation_cash_context'
        ? { ...context, selected_bank_id: args?.p_bank_account_id ?? null }
        : { id: 'request' },
  );
});
it('keeps the Insurance view read-only even for a Finance member', async () => {
  mount('view');
  expect(
    await screen.findByText(/Verified client-money cash/),
  ).toBeInTheDocument();
  expect(
    screen.queryByRole('button', { name: 'Prepare cancellation cash' }),
  ).not.toBeInTheDocument();
  expect(
    screen.queryByRole('button', { name: 'approve' }),
  ).not.toBeInTheDocument();
});
it('hides checker approval from the maker', async () => {
  context.actor_id = 'maker';
  mount();
  expect(
    await screen.findByRole('button', { name: 'cancel' }),
  ).toBeInTheDocument();
  expect(
    screen.queryByRole('button', { name: 'approve' }),
  ).not.toBeInTheDocument();
});
it('requires a detailed independent review and calls only the cash decision RPC', async () => {
  mount();
  fireEvent.click(await screen.findByRole('button', { name: 'approve' }));
  const dialog = screen.getByRole('dialog');
  const approve = within(dialog).getByRole('button', {
    name: 'Approve and post cash / correction',
  });
  expect(approve).toBeDisabled();
  fireEvent.change(
    within(dialog).getByLabelText('Detailed cash review / correction reason'),
    {
      target: {
        value: 'Verified beneficiary, liability and actual bank funds',
      },
    },
  );
  fireEvent.click(approve);
  await waitFor(() =>
    expect(rpc).toHaveBeenCalledWith('ins_decide_cancellation_cash', {
      p_request_id: 'request',
      p_decision: 'approve',
      p_reason: 'Verified beneficiary, liability and actual bank funds',
    }),
  );
  expect(
    rpc.mock.calls.some(([name]) => name === 'ins_decide_policy_cancellation'),
  ).toBe(false);
});
it('keeps stale-funds errors visible and retains the checker review for a safe retry', async () => {
  rpc.mockImplementation(async (name: string) => {
    if (name === 'ins_decide_cancellation_cash')
      throw new Error('INS_CXL_CASH_FUNDS: bank cash changed');
    return context;
  });
  mount();
  fireEvent.click(await screen.findByRole('button', { name: 'approve' }));
  const dialog = screen.getByRole('dialog');
  fireEvent.change(
    within(dialog).getByLabelText('Detailed cash review / correction reason'),
    { target: { value: 'Checked the actual funding evidence' } },
  );
  fireEvent.click(
    within(dialog).getByRole('button', {
      name: 'Approve and post cash / correction',
    }),
  );
  expect(
    await within(dialog).findByText(/bank cash changed/),
  ).toBeInTheDocument();
  expect(
    within(dialog).getByLabelText('Detailed cash review / correction reason'),
  ).toHaveValue('Checked the actual funding evidence');
});
it('proposes a correction void instead of immediately reversing a posted payment', async () => {
  context.requests = [
    {
      ...pending,
      status: 'posted',
      settlement_id: 'settlement',
      settlement_no: 'STL-1',
    },
  ];
  mount();
  fireEvent.click(
    await screen.findByRole('button', { name: 'Request correction void' }),
  );
  const dialog = screen.getByRole('dialog');
  fireEvent.change(
    within(dialog).getByLabelText('Detailed cash review / correction reason'),
    { target: { value: 'Mistaken booking requires independent correction' } },
  );
  fireEvent.click(
    within(dialog).getByRole('button', { name: 'Submit void proposal only' }),
  );
  await waitFor(() =>
    expect(rpc).toHaveBeenCalledWith(
      'ins_submit_cancellation_cash_void',
      expect.objectContaining({
        p_request_id: 'request',
        p_reason: 'Mistaken booking requires independent correction',
        p_request_key: expect.any(String),
      }),
    ),
  );
  expect(rpc.mock.calls.some(([name]) => name === 'fin_void_settlement')).toBe(
    false,
  );
});
it('fails closed if the RPC shape is unavailable', async () => {
  rpc.mockResolvedValue([]);
  mount();
  expect(
    await screen.findByText(/Cancellation cash details are unavailable/),
  ).toBeInTheDocument();
  expect(
    screen.queryByRole('button', { name: 'Prepare cancellation cash' }),
  ).not.toBeInTheDocument();
});
it('retains the exact amount text and proposal UUID when the submit response is lost', async () => {
  context.requests = [];
  let submits = 0;
  rpc.mockImplementation(
    async (name: string, args?: Record<string, unknown>) => {
      if (name === 'ins_cancellation_cash_context')
        return {
          ...context,
          selected_bank_id: args?.p_bank_account_id ?? null,
        };
      if (name === 'ins_submit_cancellation_cash' && submits++ === 0)
        throw new Error('Lost cash proposal response');
      return { id: 'request' };
    },
  );
  mount();
  fireEvent.click(
    await screen.findByRole('button', { name: 'Prepare cancellation cash' }),
  );
  const dialog = screen.getByRole('dialog');
  fireEvent.mouseDown(within(dialog).getByLabelText('Source / receipt bank'));
  fireEvent.click(
    await screen.findByRole('option', { name: 'Client trust (UGX)' }),
  );
  await within(dialog).findByText(
    /Current server limit for this bank\/action: 50.01/,
  );
  fireEvent.change(within(dialog).getByLabelText('Exact cash amount'), {
    target: { value: '50.01' },
  });
  fireEvent.change(
    within(dialog).getByLabelText('Bank / beneficiary reference'),
    { target: { value: 'VERIFIED-CLIENT' } },
  );
  fireEvent.change(
    within(dialog).getByLabelText(
      'Verified purpose and beneficiary / insurer evidence',
    ),
    { target: { value: 'Verified beneficiary and contractual refund' } },
  );
  const submit = within(dialog).getByRole('button', {
    name: 'Submit cash proposal only',
  });
  await waitFor(() => expect(submit).toBeEnabled());
  fireEvent.click(submit);
  await within(dialog).findByText('Lost cash proposal response');
  fireEvent.click(submit);
  await waitFor(() =>
    expect(
      rpc.mock.calls.filter(
        ([name]) => name === 'ins_submit_cancellation_cash',
      ),
    ).toHaveLength(2),
  );
  const calls = rpc.mock.calls.filter(
    ([name]) => name === 'ins_submit_cancellation_cash',
  );
  expect(calls[0][1].p_request_key).toBe(calls[1][1].p_request_key);
  expect(calls[0][1].p_amount).toBe('50.01');
});
