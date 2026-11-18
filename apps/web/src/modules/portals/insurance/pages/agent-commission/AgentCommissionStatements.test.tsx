import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentCommissionStatements from './AgentCommissionStatements';

// The statement tab is read-only reporting on top of the statement RPC. What is
// tested: every figure comes from the server, currencies are never summed, the
// period runs on the payment date, the tax character is spelled out in words, and
// the PDF is produced from what is on screen rather than recalculated.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

const mockAccess = vi.fn();
vi.mock('../../access', () => ({ useInsuranceAccess: () => mockAccess() }));

const mockDownload = vi.fn();
vi.mock('./download', () => ({ downloadTextFile: (...a: unknown[]) => mockDownload(...a) }));

const line = (over: Record<string, unknown> = {}) => ({
  accrual_id: 'a1', policy_no: 'POL-001', currency: 'UGX',
  accrued_on: '2026-11-01', paid_on: '2026-11-18', statement_date: '2026-11-18',
  basis: 'pct_of_broker_commission', gross_amount: 300000, wht_rate_pct: 10,
  wht_amount: 30000, wht_is_final: true, net_amount: 270000, status: 'paid', ...over,
});

const statement = (over: Record<string, unknown> = {}) => ({
  intermediary_id: 'i1', name: 'Acme Agents', category: 'sub_agent',
  from: '2026-11-01', to: '2026-11-30',
  gross_commission: 300000, wht_withheld: 30000, net_commission: 270000, paid: 270000, outstanding: 0,
  by_currency: [{
    currency: 'UGX', gross_commission: 300000, wht_withheld: 30000,
    net_commission: 270000, paid: 270000, outstanding: 0, lines: 1,
  }],
  lines: [line()],
  ...over,
});

const ok = (data: unknown) => Promise.resolve({ data, error: null });

let intermediaries: unknown[];

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockDownload.mockReset();
  mockAccess.mockReset();
  intermediaries = [{ id: 'i1', name: 'Acme Agents', category: 'sub_agent' }];
  const b = (out: unknown[]) => {
    const x: Record<string, unknown> = {};
    x.select = () => x; x.order = () => x; x.range = () => x; x.eq = () => x;
    x.then = (res: (v: unknown) => unknown) => Promise.resolve({ data: out, error: null }).then(res);
    return x;
  };
  mockFrom.mockImplementation((t: string) => b(t === 'ins_intermediaries' ? intermediaries : []));
  mockRpc.mockImplementation(() => ok(statement()));
  mockAccess.mockReturnValue({ loading: false, canManage: true });
});

const renderTab = () => render(<AgentCommissionStatements />);

describe('every figure comes from the statement RPC', () => {
  it('asks the server for the chosen agent and period', async () => {
    renderTab();
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_agent_commission_statement', expect.objectContaining({
      p_intermediary_id: 'i1',
    })));
  });

  it('shows the five figures the agent cares about', async () => {
    renderTab();
    expect(await screen.findByText('Gross commission')).toBeTruthy();
    expect(screen.getByText('Tax withheld')).toBeTruthy();
    expect(screen.getByText('Net commission')).toBeTruthy();
    expect(screen.getByText('Paid to agent')).toBeTruthy();
    expect(screen.getByText('Outstanding')).toBeTruthy();
    expect(screen.getAllByText(/USh\s*270,000/).length).toBeGreaterThan(0);
  });

  it('never adds two currencies together', async () => {
    mockRpc.mockImplementation(() => ok(statement({
      gross_commission: 900500,
      by_currency: [
        { currency: 'UGX', gross_commission: 900000, wht_withheld: 0, net_commission: 900000, paid: 0, outstanding: 900000, lines: 1 },
        { currency: 'USD', gross_commission: 500, wht_withheld: 0, net_commission: 500, paid: 0, outstanding: 500, lines: 1 },
      ],
    })));
    renderTab();

    expect(await screen.findByText('UGX')).toBeTruthy();
    expect(screen.getByText('USD')).toBeTruthy();
    expect(screen.queryByText(/900,500/)).toBeNull();
  });

  it('says so when the period is empty', async () => {
    mockRpc.mockImplementation(() => ok(statement({
      lines: [], by_currency: [],
      gross_commission: 0, wht_withheld: 0, net_commission: 0, paid: 0, outstanding: 0,
    })));
    renderTab();
    expect(await screen.findByText(/Nothing has been earned by this intermediary/i)).toBeTruthy();
  });
});

describe('the tax character is spelled out', () => {
  it('says a final tax will not be declared again', async () => {
    renderTab();
    expect(await screen.findByText(/final tax/i)).toBeTruthy();
  });

  it('says an on-account withholding still has to be declared', async () => {
    mockRpc.mockImplementation(() => ok(statement({
      lines: [line({ wht_is_final: false })],
    })));
    renderTab();
    expect(await screen.findByText(/payment on account/i)).toBeTruthy();
  });

  it('distinguishes "none withheld" from "not yet determined"', async () => {
    mockRpc.mockImplementation(() => ok(statement({
      lines: [
        line({ accrual_id: 'a1', status: 'paid', wht_amount: 0, net_amount: 300000, wht_rate_pct: null, wht_is_final: null }),
        line({ accrual_id: 'a2', policy_no: 'POL-002', status: 'eligible', paid_on: null, statement_date: '2026-11-05', wht_amount: 0, net_amount: 300000, wht_rate_pct: null, wht_is_final: null }),
      ],
    })));
    renderTab();
    expect(await screen.findByText('none withheld')).toBeTruthy();
    expect(screen.getByText('determined when paid')).toBeTruthy();
  });
});

describe('the period runs on the payment date', () => {
  it('sends explicit dates for a preset rather than a month name', async () => {
    renderTab();
    await waitFor(() => expect(mockRpc).toHaveBeenCalled());
    const args = mockRpc.mock.calls[0][1] as { p_from: string; p_to: string };
    // A month preset must resolve to first and last day of that month.
    expect(args.p_from).toMatch(/^\d{4}-\d{2}-01$/);
    expect(args.p_to).toMatch(/^\d{4}-\d{2}-(28|29|30|31)$/);
  });

  it('asks for all time with no bounds at all', async () => {
    renderTab();
    await screen.findByText('Acme Agents');
    await userEvent.click(screen.getByRole('button', { name: 'All time' }));
    await waitFor(() => {
      const last = mockRpc.mock.calls[mockRpc.mock.calls.length - 1]?.[1] as { p_from: string | null; p_to: string | null };
      expect(last.p_from).toBeNull();
      expect(last.p_to).toBeNull();
    });
  });
});

describe('the PDF is produced from what is on screen', () => {
  it('downloads a statement named after the agent and its period', async () => {
    renderTab();
    await screen.findByText('Acme Agents');
    await userEvent.click(screen.getByRole('button', { name: 'Download PDF' }));

    expect(mockDownload).toHaveBeenCalledTimes(1);
    const [filename, body] = mockDownload.mock.calls[0] as [string, string];
    expect(filename).toBe('Acme-Agents-statement-2026-11-01-2026-11-30.pdf');
    expect(body.startsWith('%PDF-1.4')).toBe(true);
    expect(body).toContain('Acme Agents');
    expect(body.trimEnd().endsWith('%%EOF')).toBe(true);
  });

  it('will not download an empty statement', async () => {
    mockRpc.mockImplementation(() => ok(statement({
      lines: [], by_currency: [],
      gross_commission: 0, wht_withheld: 0, net_commission: 0, paid: 0, outstanding: 0,
    })));
    renderTab();
    await screen.findByText(/Nothing has been earned/i);
    expect((screen.getByRole('button', { name: 'Download PDF' }) as HTMLButtonElement).disabled).toBe(true);
  });
});

describe('errors lose their codes', () => {
  it('shows a refusal in words', async () => {
    mockRpc.mockImplementation(() => Promise.reject(new Error('the intermediary is not in this company')));
    renderTab();
    expect(await screen.findByText(/not in this company/i)).toBeTruthy();
  });
});

describe('a member can read but is told what they cannot do', () => {
  it('says paying is a manager action', async () => {
    mockAccess.mockReturnValue({ loading: false, canManage: false });
    renderTab();
    expect(await screen.findByText(/paying an agent is a manager action/i)).toBeTruthy();
    // Reading and downloading are still available.
    const button = screen.getByRole('button', { name: 'Download PDF' }) as HTMLButtonElement;
    expect(button.disabled).toBe(false);
  });
});
