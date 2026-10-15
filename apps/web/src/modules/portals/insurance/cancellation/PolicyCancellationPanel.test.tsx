import {
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyCancellationPanel from './PolicyCancellationPanel';
import type {
  CancellationCase,
  CancellationContext,
  CancellationQuote,
} from './workflow';
const { rpc } = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('../db', () => ({
  rpc,
  errorText: (e: unknown) => (e instanceof Error ? e.message : String(e)),
}));
const quote: CancellationQuote = {
  stage: 'calculation_only',
  payment_authorized: false,
  invoice_credit: '500.00',
  receivable_credit: '0.00',
  client_refund_due: '500.00',
  requires_finance_exception: true,
  insurers: [
    {
      insurer_id: 'A',
      method: 'manual_review',
      contract_reference: 'Signed contract A',
      original_premium: '1000.00',
      retained_premium: '500.00',
      return_premium: '500.00',
      original_commission: '100.00',
      commission_clawback: '50.00',
      net_insurer_credit: '450.00',
      requires_finance_exception: true,
      pass_through_refund: '0.00',
      total_insurer_credit: '450.00',
    },
  ],
  charges: [],
};
const row = {
  id: 'case',
  status: 'prepared',
  proposed_by: 'manager',
  prepared_by: 'maker',
  calculation: quote,
  reason: 'Insurer agreed cancellation',
  effective_date: '2026-10-15',
  insurer_terms: [
    {
      insurer_id: 'A',
      terms: {
        method: 'manual_review',
        contract_reference: 'Signed contract A',
        manual_return_premium: '500',
      },
    },
  ],
  charge_refunds: [],
  credits: [],
  journals: [],
  insurer_adjustments: [],
} as unknown as CancellationCase;
let context: CancellationContext;
beforeEach(() => {
  rpc.mockReset();
  context = {
    policy_id: 'policy',
    policy_no: 'POL-1',
    policy_status: 'active',
    inception_date: '2026-01-01',
    expiry_date: '2026-12-31',
    actor_id: 'checker',
    can_finance: true,
    can_propose: true,
    has_claims: false,
    currency: 'UGX',
    offset: 0,
    has_more: false,
    insurers: [
      {
        insurer_id: 'A',
        insurer_name: 'Alpha',
        premium_amount: '1000',
        commission_amount: '100',
        commission_rate_pct: '10',
      },
    ],
    charges: [],
    cases: [row],
    clearing_accounts: [
      { id: 'clearing', account_code: '1199', name: 'Cancellation clearing' },
    ],
  } as CancellationContext;
  rpc.mockImplementation(async (name: string) =>
    name === 'ins_policy_cancellation_context'
      ? context
      : { id: 'case', status: 'posted' },
  );
});
describe('cancellation review screen', () => {
  it('shows contractual evidence and does not offer cash payment', async () => {
    render(<PolicyCancellationPanel policyId="policy" />);
    expect(await screen.findByText(/Signed contract A/)).toBeInTheDocument();
    expect(
      screen.getByText(/Client cash refund due: 500.00/),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole('button', { name: /pay refund/i }),
    ).not.toBeInTheDocument();
  });
  it('hides approval from the Finance maker', async () => {
    context = { ...context, actor_id: 'maker' };
    render(<PolicyCancellationPanel policyId="policy" />);
    expect(
      await screen.findByRole('button', {
        name: 'Refresh Finance preparation',
      }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole('button', { name: 'Review and approve cancellation' }),
    ).not.toBeInTheDocument();
  });
  it('keeps Insurance readers read-only', async () => {
    context = {
      ...context,
      actor_id: 'reader',
      can_propose: false,
      can_finance: false,
    };
    render(<PolicyCancellationPanel policyId="policy" />);
    await screen.findByText(/Signed contract A/);
    expect(
      screen.queryByRole('button', {
        name: /approve cancellation|Prepare for Finance|Propose cancellation/,
      }),
    ).not.toBeInTheDocument();
  });
  it('requires a review note and affirmative exception acceptance', async () => {
    render(<PolicyCancellationPanel policyId="policy" />);
    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Review and approve cancellation',
      }),
    );
    const dialog = screen.getByRole('dialog');
    const approve = within(dialog).getByRole('button', {
      name: 'Approve and post cancellation — no cash payment',
    });
    expect(approve).toBeDisabled();
    fireEvent.change(
      within(dialog).getByLabelText('Detailed review / decision note'),
      { target: { value: 'Verified insurer contractual evidence' } },
    );
    expect(approve).toBeDisabled();
    fireEvent.click(within(dialog).getByRole('checkbox'));
    expect(approve).toBeEnabled();
    fireEvent.click(approve);
    await waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('ins_decide_policy_cancellation', {
        p_cancellation_id: 'case',
        p_decision: 'approve',
        p_review_note: 'Verified insurer contractual evidence',
        p_accept_manual_exception: true,
      }),
    );
    expect(
      rpc.mock.calls.some(([name]) => String(name).includes('settlement')),
    ).toBe(false);
  });
  it('blocks proposals for a claim-bearing policy', async () => {
    context = { ...context, cases: [], has_claims: true };
    render(<PolicyCancellationPanel policyId="policy" />);
    expect(
      await screen.findByText(/This policy has an existing claim/),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole('button', { name: 'Propose cancellation' }),
    ).not.toBeInTheDocument();
  });
  it('keeps retryable checker inputs after a stale-review error', async () => {
    rpc.mockImplementation(async (name: string) => {
      if (name === 'ins_decide_policy_cancellation')
        throw new Error('INS_CANCELLATION_STALE: maker must refresh');
      return context;
    });
    render(<PolicyCancellationPanel policyId="policy" />);
    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Review and approve cancellation',
      }),
    );
    const dialog = screen.getByRole('dialog');
    fireEvent.change(
      within(dialog).getByLabelText('Detailed review / decision note'),
      { target: { value: 'Verified evidence for checker' } },
    );
    fireEvent.click(within(dialog).getByRole('checkbox'));
    fireEvent.click(
      within(dialog).getByRole('button', {
        name: 'Approve and post cancellation — no cash payment',
      }),
    );
    expect(
      await within(dialog).findByText(/INS_CANCELLATION_STALE/),
    ).toBeInTheDocument();
    expect(
      within(dialog).getByLabelText('Detailed review / decision note'),
    ).toHaveValue('Verified evidence for checker');
    expect(within(dialog).getByRole('checkbox')).toBeChecked();
  });
});

it('retains the proposal idempotency key after an uncertain response', async () => {
  context = { ...context, cases: [], has_live_case: false };
  let submitted = 0;
  rpc.mockImplementation(async (name: string) => {
    if (name === 'ins_policy_cancellation_context') return context;
    if (name === 'ins_preview_policy_cancellation')
      return {
        ...quote,
        invoice_credit: '0.00',
        receivable_credit: '0.00',
        client_refund_due: '0.00',
        requires_finance_exception: false,
        insurers: quote.insurers.map((r) => ({
          ...r,
          method: 'non_refundable',
          retained_premium: '1000.00',
          return_premium: '0.00',
          commission_clawback: '0.00',
          net_insurer_credit: '0.00',
          total_insurer_credit: '0.00',
          requires_finance_exception: false,
        })),
      };
    if (name === 'ins_submit_policy_cancellation' && submitted++ === 0)
      throw new Error('Lost response; safe retry needed');
    return { id: 'case' };
  });
  render(<PolicyCancellationPanel policyId="policy" />);
  fireEvent.click(
    await screen.findByRole('button', { name: 'Propose cancellation' }),
  );
  const dialog = screen.getByRole('dialog');
  fireEvent.change(within(dialog).getByLabelText('Cancellation reason'), {
    target: { value: 'Contractual cancellation requested' },
  });
  fireEvent.mouseDown(
    within(dialog).getByLabelText('Alpha cancellation method'),
  );
  fireEvent.click(
    await screen.findByRole('option', {
      name: 'Contractually non-refundable premium',
    }),
  );
  fireEvent.change(
    within(dialog).getByLabelText('Alpha contract / evidence reference'),
    { target: { value: 'Original contract clause A' } },
  );
  fireEvent.click(
    within(dialog).getByRole('button', { name: 'Calculate for review' }),
  );
  const submit = within(dialog).getByRole('button', {
    name: 'Submit proposal only',
  });
  await waitFor(() => expect(submit).toBeEnabled());
  fireEvent.click(submit);
  await within(dialog).findByText('Lost response; safe retry needed');
  fireEvent.click(submit);
  await waitFor(() =>
    expect(
      rpc.mock.calls.filter(
        ([name]) => name === 'ins_submit_policy_cancellation',
      ),
    ).toHaveLength(2),
  );
  const calls = rpc.mock.calls.filter(
    ([name]) => name === 'ins_submit_policy_cancellation',
  );
  expect(calls[0][1].p_request_key).toBe(calls[1][1].p_request_key);
  expect(calls[0][1]).not.toHaveProperty('p_calculation');
});

it('fails closed on an unavailable/mismatched RPC shape without crashing the surrounding page', async () => {
  rpc.mockResolvedValue([]);
  render(
    <>
      <div>Existing cash workflow</div>
      <PolicyCancellationPanel policyId="policy" />
    </>,
  );
  expect(
    await screen.findByText(
      /Cancellation details are unavailable or incomplete/,
    ),
  ).toBeInTheDocument();
  expect(screen.getByText('Existing cash workflow')).toBeInTheDocument();
  expect(
    screen.queryByRole('button', { name: 'Propose cancellation' }),
  ).not.toBeInTheDocument();
  expect(
    screen.queryByText('No cancellation proposals for this policy.'),
  ).not.toBeInTheDocument();
});
