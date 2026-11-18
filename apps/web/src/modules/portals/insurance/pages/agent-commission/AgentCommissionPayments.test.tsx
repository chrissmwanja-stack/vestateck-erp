import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentCommissionPayments from './AgentCommissionPayments';

// The payments tab exists to make the second signature real. What is tested here:
// a prepared payment shows no Release, the preparer is told why they cannot
// approve it, an approver sees the frozen figures before approving, and a refusal
// from the server is shown without the raw error code.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
const mockGetUser = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...a: unknown[]) => mockFrom(...a),
    rpc: (...a: unknown[]) => mockRpc(...a),
    auth: { getUser: () => mockGetUser() },
  },
}));

const mockAccess = vi.fn();
vi.mock('../../access', () => ({ useInsuranceAccess: () => mockAccess() }));

const payment = (over: Record<string, unknown> = {}) => ({
  id: 'pay1', tenant_id: 't1', accrual_id: 'a1', bank_account_id: 'b1', currency: 'UGX',
  gross_amount: 300000, wht_amount: 30000, wht_rate_pct: 10, wht_is_final: true,
  wht_parameter_ref: 'param-1', net_amount: 270000, paid_on: '2026-11-15', note: null,
  status: 'prepared', prepared_by: 'u-maker', prepared_at: '2026-11-14T09:00:00Z',
  approved_by: null, approved_at: null, payment_journal_entry_id: null, ...over,
});

const accrual = (over: Record<string, unknown> = {}) => ({
  id: 'a1', policy_id: 'p1', intermediary_id: 'i1', basis: 'pct_of_broker_commission',
  rate_pct: 40, fixed_amount: null, commission_base: 750000, gross_amount: 300000,
  wht_amount: 0, net_amount: 300000, currency: 'UGX', status: 'eligible', eligible_on: '2026-11-01',
  paid_at: null, created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z',
  term_id: 't1', reversal_reason: null, journal_entry_id: 'j1', payment_journal_entry_id: null,
  wht_rate_pct: null, wht_is_final: null, wht_parameter_ref: null, ...over,
});

let data: Record<string, unknown[]>;
const builder = (out: unknown[]) => {
  const b: Record<string, unknown> = {};
  b.select = () => b; b.order = () => b; b.range = () => b; b.eq = () => b;
  b.then = (res: (v: unknown) => unknown) => Promise.resolve({ data: out, error: null }).then(res);
  return b;
};

const baseSeed = () => {
  data = {};
  data.ins_agent_commission_payments = [];
  data.ins_agent_commission_accruals = [accrual()];
  data.ins_intermediaries = [{ id: 'i1', name: 'Acme Agents' }];
  data.ins_policies = [{ id: 'p1', policy_no: 'POL-001' }];
  data.app_users = [
    { id: 'u-maker', name: 'Mary Maker', email: 'mary@example.com' },
    { id: 'u-checker', name: 'Charles Checker', email: 'charles@example.com' },
  ];
};

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockGetUser.mockReset();
  mockAccess.mockReset();
  baseSeed();
  mockFrom.mockImplementation((t: string) => builder(data[t] ?? []));
  mockRpc.mockResolvedValue({ id: 'b1', name: 'Stanbic Current', currency: 'UGX' });
  mockAccess.mockReturnValue({ loading: false, canManage: true });
  mockGetUser.mockResolvedValue({ data: { user: { id: 'u-checker' } } });
});

const renderTab = () => render(<AgentCommissionPayments />);

describe('the queue is honest about who may press what', () => {
  it('offers Release only once a payment has been approved', async () => {
    data.ins_agent_commission_payments = [payment()];
    renderTab();

    expect(await screen.findByRole('button', { name: 'Approve' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Release' })).toBeNull();
  });

  it('replaces Approve with Release after approval', async () => {
    data.ins_agent_commission_payments = [
      payment({ status: 'approved', approved_by: 'u-checker', approved_at: '2026-11-14T11:00:00Z' }),
    ];
    renderTab();

    expect(await screen.findByRole('button', { name: 'Release' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Approve' })).toBeNull();
  });

  it('does not offer the preparer a way to approve their own work', async () => {
    mockGetUser.mockResolvedValue({ data: { user: { id: 'u-maker' } } });
    data.ins_agent_commission_payments = [payment()];
    renderTab();

    // The proposer may withdraw, not approve.
    expect(await screen.findByRole('button', { name: 'Withdraw' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Approve' })).toBeNull();
    expect(screen.getByText(/you prepared this payment/i)).toBeTruthy();
  });

  it('hides every decision from a member who cannot manage', async () => {
    mockAccess.mockReturnValue({ loading: false, canManage: false });
    data.ins_agent_commission_payments = [payment()];
    renderTab();

    await screen.findByText('Acme Agents');
    for (const name of ['Approve', 'Release', 'Withdraw', 'Decline', 'Propose a payment']) {
      expect(screen.queryByRole('button', { name })).toBeNull();
    }
  });

  it('shows the tax character next to the net the approver is accepting', async () => {
    data.ins_agent_commission_payments = [payment()];
    renderTab();

    const table = (await screen.findByText('Acme Agents')).closest('table') as HTMLElement;
    const body = within(table);
    // The approver is agreeing to a gross, a withholding and a net -- all three,
    // because approving a net without seeing the tax is approving a surprise.
    for (const amount of ['300,000', '30,000', '270,000']) {
      expect(body.getAllByText(new RegExp(`USh\\s*${amount}`)).length).toBeGreaterThan(0);
    }
    expect(body.getByText('Awaiting a second approver')).toBeTruthy();
    // The proposer is named on the row, and the approval column is still empty --
    // that empty cell is what the queue is chasing.
    expect(body.getByText('Mary Maker')).toBeTruthy();
  });
});

describe('writes go through the RPCs and refusals are readable', () => {
  it('approves through the RPC, not a table update', async () => {
    data.ins_agent_commission_payments = [payment()];
    mockRpc.mockImplementation((fn: string) => Promise.resolve(fn === 'ins_commission_bank_accounts'
      ? [{ id: 'b1', name: 'Stanbic Current', currency: 'UGX' }]
      : { approved: true }));
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith(
      'ins_agent_commission_approve_payment', { p_payment_id: 'pay1' },
    ));
    expect(await screen.findByText(/now ready to release/i)).toBeTruthy();
  });

  it('releases through the RPC with the payment id', async () => {
    data.ins_agent_commission_payments = [
      payment({ status: 'approved', approved_by: 'u-checker', approved_at: '2026-11-14T11:00:00Z' }),
    ];
    mockRpc.mockImplementation((fn: string) => Promise.resolve(fn === 'ins_commission_bank_accounts'
      ? [{ id: 'b1', name: 'Stanbic Current', currency: 'UGX' }]
      : { released: true }));
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Release' }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith(
      'ins_agent_commission_release_payment', { p_payment_id: 'pay1', p_note: null },
    ));
    expect(await screen.findByText(/payment released and posted/i)).toBeTruthy();
  });

  it('shows a server refusal in words, without the error code', async () => {
    data.ins_agent_commission_payments = [payment()];
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_commission_bank_accounts') return Promise.resolve([{ id: 'b1', name: 'Stanbic', currency: 'UGX' }]);
      return Promise.reject(new Error('INS_AGENT_PAYMENT_STALE: the share changed after this payment was prepared'));
    });
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));

    const alert = await screen.findByText(/the share changed after this payment was prepared/i);
    expect(alert.textContent).not.toContain('INS_AGENT_PAYMENT_STALE');
  });
});

describe('declining demands a reason', () => {
  it('refuses a short reason before calling the server', async () => {
    data.ins_agent_commission_payments = [payment()];
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Decline' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.type(within(dialog).getByLabelText(/reason/i), 'no');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Decline' }));

    // Both the helper text under the field and the banner above it say this.
    expect((await screen.findAllByText(/at least 10 characters/i)).length).toBeGreaterThan(0);
    expect(mockRpc).not.toHaveBeenCalledWith('ins_agent_commission_reject_payment', expect.anything());
  });

  it('sends the reason once it is long enough', async () => {
    data.ins_agent_commission_payments = [payment()];
    mockRpc.mockImplementation((fn: string) => Promise.resolve(fn === 'ins_commission_bank_accounts'
      ? [{ id: 'b1', name: 'Stanbic', currency: 'UGX' }]
      : { rejected: true }));
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Decline' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.type(within(dialog).getByLabelText(/reason/i), 'the bank details are wrong on this share');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Decline' }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_agent_commission_reject_payment', {
      p_payment_id: 'pay1', p_reason: 'the bank details are wrong on this share',
    }));
  });
});

describe('proposing a payment', () => {
  it('offers only eligible shares that are not already being paid', async () => {
    data.ins_agent_commission_accruals = [
      accrual({ id: 'a1' }),
      accrual({ id: 'a2', status: 'accrued' }),
      accrual({ id: 'a3', policy_id: 'p2' }),
    ];
    data.ins_policies = [{ id: 'p1', policy_no: 'POL-001' }, { id: 'p2', policy_no: 'POL-002' }];
    data.ins_agent_commission_payments = [payment({ accrual_id: 'a3', status: 'approved', approved_by: 'u', approved_at: '2026-11-14T11:00:00Z' })];
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Propose a payment' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByLabelText(/agent share/i));

    expect(await screen.findByRole('option', { name: /POL-001/ })).toBeTruthy();
    // a2 is not eligible yet, a3 already has a live payment.
    expect(screen.queryByRole('option', { name: /POL-002/ })).toBeNull();
  });

  it('says why nothing can be proposed when nothing is eligible', async () => {
    data.ins_agent_commission_accruals = [accrual({ status: 'accrued' })];
    renderTab();

    expect(await screen.findByText(/no agent share is eligible and unpaid/i)).toBeTruthy();
  });
});
