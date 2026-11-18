import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentCommissionPage from './AgentCommissionPage';

// Overview reads the accrual subledger and shows per-currency totals; it never calls an RPC
// (no money is calculated in the browser). Payments is a real tab now; WHT Remittances is
// still a stage placeholder.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...a: unknown[]) => mockFrom(...a),
    rpc: vi.fn(),
    auth: {
      getUser: () => Promise.resolve({ data: { user: { id: 'u-1' } } }),
      getSession: () => Promise.resolve({ data: { session: null } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
    },
  },
}));

const accrual = (over: Record<string, unknown>) => ({
  id: 'a1', policy_id: 'p1', intermediary_id: 'i1', basis: 'pct_of_broker_commission', gross_amount: 100000,
  wht_amount: 0, net_amount: null, currency: 'UGX', status: 'accrued', eligible_on: null, paid_at: null,
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z', ...over,
});

const data: Record<string, unknown[]> = {};
const builder = (rowsOut: unknown[]) => {
  const b: Record<string, unknown> = {};
  b.select = () => b; b.order = () => b;
  b.then = (res: (v: unknown) => unknown) => Promise.resolve({ data: rowsOut, error: null }).then(res);
  return b;
};

beforeEach(() => {
  mockFrom.mockReset();
  mockFrom.mockImplementation((t: string) => builder(data[t] ?? []));
});

describe('AgentCommissionPage', () => {
  it('shows agent, policy and status in recent activity', async () => {
    data.ins_agent_commission_accruals = [accrual({ status: 'eligible' })];
    data.ins_intermediaries = [{ id: 'i1', name: 'Sample Agent' }];
    data.ins_policies = [{ id: 'p1', policy_no: 'POL-001' }];
    render(<AgentCommissionPage />);
    expect(await screen.findByText('Sample Agent')).toBeInTheDocument();
    expect(screen.getByText('POL-001')).toBeInTheDocument();
    expect(screen.getAllByText('Eligible for payment').length).toBeGreaterThan(0);
  });

  it('counts withholding as held, not as ever withheld', async () => {
    // Two paid shares with 30,000 withheld each. One return covering the first
    // has been PAID to URA, so only the second is still a liability of ours.
    data.ins_agent_commission_accruals = [
      accrual({ id: 'a1', policy_id: 'p1', status: 'paid', wht_amount: 30000, net_amount: 70000, gross_amount: 100000 }),
      accrual({ id: 'a2', policy_id: 'p2', status: 'paid', wht_amount: 30000, net_amount: 70000, gross_amount: 100000 }),
    ];
    data.ins_intermediaries = [{ id: 'i1', name: 'Sample Agent' }];
    data.ins_policies = [{ id: 'p1', policy_no: 'POL-001' }, { id: 'p2', policy_no: 'POL-002' }];
    data.ins_wht_remittance_lines = [{ accrual_id: 'a1', amount: 30000, remittance_id: 'r1' }];
    data.ins_wht_remittances = [{ id: 'r1', status: 'paid' }];
    render(<AgentCommissionPage />);

    expect(await screen.findByText('Withholding still held')).toBeInTheDocument();
    // 30,000, not the 60,000 ever withheld: the other half has gone to URA.
    expect(screen.getAllByText(/USh\s*30,000/).length).toBeGreaterThan(0);
    expect(screen.queryByText(/USh\s*60,000/)).toBeNull();
  });

  it('shows an empty state when nothing has accrued', async () => {
    data.ins_agent_commission_accruals = [];
    data.ins_intermediaries = [];
    data.ins_policies = [];
    render(<AgentCommissionPage />);
    expect(await screen.findByText('No agent commission has accrued yet.')).toBeInTheDocument();
  });

  it('the payments tab is wired to the payment queue, not a placeholder', async () => {
    data.ins_agent_commission_accruals = [];
    data.ins_agent_commission_payments = [];
    render(<AgentCommissionPage />);
    await waitFor(() => expect(screen.getByRole('tab', { name: 'Payments' })).toBeInTheDocument());
    await userEvent.click(screen.getByRole('tab', { name: 'Payments' }));

    expect(await screen.findByText('Waiting on somebody')).toBeInTheDocument();
    expect(screen.queryByText(/built in a later stage/i)).toBeNull();
  });

  it('the WHT tab is wired to the tax position, not a placeholder', async () => {
    data.ins_agent_commission_accruals = [];
    data.ins_wht_remittances = [];
    render(<AgentCommissionPage />);
    await waitFor(() => expect(screen.getByRole('tab', { name: 'WHT Remittances' })).toBeInTheDocument());
    await userEvent.click(screen.getByRole('tab', { name: 'WHT Remittances' }));

    expect(await screen.findByText('Returns still open')).toBeInTheDocument();
    expect(screen.queryByText(/built in a later stage/i)).toBeNull();
  });

  it('every tab now renders something real', async () => {
    // No stage placeholders remain on this page; if one comes back, this fails.
    data.ins_agent_commission_accruals = [];
    render(<AgentCommissionPage />);
    await waitFor(() => expect(screen.getByRole('tab', { name: 'Payments' })).toBeInTheDocument());
    for (const name of ['Payments', 'Statements', 'WHT Remittances', 'Accruals', 'Commission Terms']) {
      await userEvent.click(screen.getByRole('tab', { name }));
      expect(screen.queryByText(/built in a later stage/i)).toBeNull();
    }
  });
});
