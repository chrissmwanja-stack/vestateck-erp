import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentCommissionAccruals from './AgentCommissionAccruals';

// The accrual register reads rows and never calculates money in the browser.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: vi.fn() },
}));

const accrual = (over: Record<string, unknown>) => ({
  id: 'a1', policy_id: 'p1', intermediary_id: 'i1', basis: 'pct_of_broker_commission',
  rate_pct: 40, fixed_amount: null, commission_base: 750000,
  gross_amount: 300000, wht_amount: 0, net_amount: 300000, currency: 'UGX',
  status: 'accrued', eligible_on: null, paid_at: null,
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z',
  term_id: 't1', reversal_reason: null, journal_entry_id: 'j1', payment_journal_entry_id: null,
  wht_rate_pct: null, wht_is_final: null, wht_parameter_ref: null, ...over,
});

const data: Record<string, unknown[]> = {};

/** The list load uses allRows (range-paged); the event load uses rows (awaited directly). */
const listBuilder = (rowsOut: unknown[]) => {
  const b: Record<string, unknown> = {};
  b.select = () => b;
  b.order = () => b;
  b.range = () => b;
  b.eq = () => b;
  b.then = (res: (v: unknown) => unknown) => Promise.resolve({ data: rowsOut, error: null }).then(res);
  return b;
};

const event = (over: Record<string, unknown>) => ({
  id: 'e1', accrual_id: 'a1', event: 'accrued', amount: 300000, journal_entry_id: 'j1',
  note: 'share of the brokerage commission', actor_id: null, created_at: '2026-11-01T00:00:00Z', ...over,
});

beforeEach(() => {
  mockFrom.mockReset();
  for (const k of Object.keys(data)) delete data[k];
  mockFrom.mockImplementation((t: string) => listBuilder(data[t] ?? []));
});

const seed = () => {
  data.ins_agent_commission_accruals = [
    accrual(),
    accrual({
      id: 'a2', policy_id: 'p2', intermediary_id: 'i2', status: 'paid',
      wht_amount: 30000, net_amount: 270000, wht_rate_pct: 10, wht_is_final: true,
      paid_at: '2026-11-15T10:00:00Z', payment_journal_entry_id: 'j2',
    }),
  ];
  data.ins_intermediaries = [{ id: 'i1', name: 'Acme Agents' }, { id: 'i2', name: 'Zeta Partners' }];
  data.ins_policies = [
    { id: 'p1', policy_no: 'POL-001', ins_clients: { bd_clients: { name: 'Jubilee Foods' } } },
    { id: 'p2', policy_no: 'POL-002', ins_clients: { bd_clients: { name: 'Muller Logistics' } } },
  ];
  data.app_users = [];
};

describe('AgentCommissionAccruals', () => {
  it('lists an accrual with agent, policy, client and basis', async () => {
    seed();
    render(<AgentCommissionAccruals />);
    expect(await screen.findByText('Acme Agents')).toBeInTheDocument();
    expect(screen.getByText('POL-001')).toBeInTheDocument();
    expect(screen.getByText('Jubilee Foods')).toBeInTheDocument();
  });

  it('shows an empty state before anything has accrued', async () => {
    data.ins_agent_commission_accruals = [];
    render(<AgentCommissionAccruals />);
    expect(await screen.findByText(/No agent commission has accrued yet/)).toBeInTheDocument();
  });

  it('totals the rows shown, per currency, leaving reversed out', async () => {
    seed();
    render(<AgentCommissionAccruals />);
    await screen.findByText('Acme Agents');
    const totals = screen.getByRole('region', { name: /Totals of the accruals shown/i });
    // 300,000 accrued (nothing withheld yet) + 270,000 net of the paid one.
    expect(within(totals).getByText(/Net payable to agents/).textContent).toContain('570,000');
    expect(within(totals).getByText(/Withholding/).textContent).toContain('30,000');
  });

  it('filters by agent', async () => {
    seed();
    render(<AgentCommissionAccruals />);
    await screen.findByText('Acme Agents');
    await userEvent.click(screen.getByLabelText('Agent'));
    await userEvent.click(await screen.findByRole('option', { name: 'Zeta Partners' }));
    await waitFor(() => expect(screen.queryByText('POL-001')).not.toBeInTheDocument());
    expect(screen.getByText('POL-002')).toBeInTheDocument();
  });

  it('finds a policy by its number in the search box', async () => {
    seed();
    render(<AgentCommissionAccruals />);
    await screen.findByText('Acme Agents');
    await userEvent.type(screen.getByLabelText('Search'), 'POL-002');
    await waitFor(() => expect(screen.queryByText('POL-001')).not.toBeInTheDocument());
    expect(screen.getByText('POL-002')).toBeInTheDocument();
  });

  it('opens the detail with withholding explained for a paid share', async () => {
    seed();
    render(<AgentCommissionAccruals />);
    await userEvent.click(await screen.findByText('Zeta Partners'));
    const dialog = await screen.findByRole('dialog');
    // A paid, final withholding must say so in words, not just show 30,000.
    expect(within(dialog).getByText(/final tax at 10%/)).toBeInTheDocument();
  });

  it('says an unpaid share has no withholding YET rather than none at all', async () => {
    seed();
    render(<AgentCommissionAccruals />);
    await userEvent.click(await screen.findByText('Acme Agents'));
    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/determined when the agent is paid/)).toBeInTheDocument();
  });

  it('loads the event history for the accrual that was opened', async () => {
    seed();
    data.ins_agent_commission_events = [event({})];
    render(<AgentCommissionAccruals />);
    await userEvent.click(await screen.findByText('Acme Agents'));
    const dialog = await screen.findByRole('dialog');
    // The event's own note, not the word "Accrued", which is also the status value.
    expect(await within(dialog).findByText(/share of the brokerage commission/)).toBeInTheDocument();
    // The amount is labelled by what it is, because a paid event is the net and a
    // reversal is the gross; two bare numbers would read as a discrepancy.
    expect(within(dialog).getByText('gross share')).toBeInTheDocument();
  });

  it('reports a failure to load instead of showing an empty register as if it were true', async () => {
    mockFrom.mockImplementation(() => {
      const b: Record<string, unknown> = {};
      b.select = () => b; b.order = () => b; b.range = () => b;
      b.then = (res: (v: unknown) => unknown) =>
        Promise.resolve({ data: null, error: { message: 'permission denied' } }).then(res);
      return b;
    });
    render(<AgentCommissionAccruals />);
    expect(await screen.findByText(/permission denied/i)).toBeInTheDocument();
  });
});
