import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentCommissionPage from './AgentCommissionPage';

// Overview reads the accrual subledger and shows per-currency totals; it never calls an RPC
// (no money is calculated in the browser). The other tabs are stage placeholders.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: vi.fn() },
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

  it('shows an empty state when nothing has accrued', async () => {
    data.ins_agent_commission_accruals = [];
    data.ins_intermediaries = [];
    data.ins_policies = [];
    render(<AgentCommissionPage />);
    expect(await screen.findByText('No agent commission has accrued yet.')).toBeInTheDocument();
  });

  it('other tabs are placeholders until their stage is built', async () => {
    data.ins_agent_commission_accruals = [];
    render(<AgentCommissionPage />);
    await waitFor(() => expect(screen.getByRole('tab', { name: 'Payments' })).toBeInTheDocument());
    await userEvent.click(screen.getByRole('tab', { name: 'Payments' }));
    expect(screen.getByText(/built in a later stage/i)).toBeInTheDocument();
  });
});
