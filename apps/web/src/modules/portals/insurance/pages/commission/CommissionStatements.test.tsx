import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CommissionStatements from './CommissionStatements';

// Statement screen: reads the insurer's bound policies and commission ledger, shows each policy with its commission status, labels pre-deferral policies
// as legacy, totals by status, and refuses an inverted period before querying.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockExcel = vi.fn();
const mockPdf = vi.fn();
vi.mock('../../../../../lib/reportExport', () => ({
  exportReportToExcel: (...args: unknown[]) => mockExcel(...args),
  exportReportToPdf: (...args: unknown[]) => mockPdf(...args),
}));

const today = new Date().toISOString().slice(0, 10);
const boundAt = `${today}T08:00:00Z`;

const policy = (over: Record<string, unknown>) => ({
  id: 'p', policy_no: 'POL-1', status: 'active', client_id: 'c1', insurer_id: 'i1', product_line_id: 'pl',
  inception_date: today, expiry_date: '2099-01-01', sum_insured: 0, currency: 'UGX', gross_premium: 1000,
  commission_rate_pct: 10, commission_amount: 100, net_premium_to_insurer: 900, bound_at: boundAt,
  journal_entry_id: null, renewal_of_id: null, risk_description: null, notes: null,
  ins_clients: { bd_clients: { name: 'Acme Ltd' } }, ...over,
});
const POLICIES = [
  policy({ id: 'pa', policy_no: 'POL-A' }),
  policy({ id: 'pb', policy_no: 'POL-B', ins_clients: { bd_clients: { name: 'Beta Ltd' } } }),
  policy({ id: 'pl', policy_no: 'POL-OLD' }),
];
const LEDGER = [
  { id: 'ea', policy_id: 'pa', policy_no: 'POL-A', insurer_id: 'i1', client_id: 'c1', amount: 100, status: 'earned', earned_on: today, transfer_id: null, transfer_no: null, transfer_date: null, created_at: '', updated_at: '' },
  { id: 'eb', policy_id: 'pb', policy_no: 'POL-B', insurer_id: 'i1', client_id: 'c1', amount: 100, status: 'deferred', earned_on: null, transfer_id: null, transfer_no: null, transfer_date: null, created_at: '', updated_at: '' },
];

function selectChain(data: unknown[]) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'neq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data, error: null });
  return chain;
}

beforeEach(() => {
  vi.clearAllMocks();
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_insurers') return selectChain([{ id: 'i1', name: 'Alpha Assurance' }]);
    if (name === 'ins_policies') return selectChain(POLICIES);
    if (name === 'ins_commission_ledger') return selectChain(LEDGER);
    throw new Error(`unexpected table ${name}`);
  });
});

async function generate(user: ReturnType<typeof userEvent.setup>) {
  render(<CommissionStatements />);
  await user.click(await screen.findByLabelText('Insurer'));
  await user.click(await screen.findByRole('option', { name: 'Alpha Assurance' }));
  await user.click(screen.getByRole('button', { name: 'Generate' }));
}

describe('CommissionStatements', () => {
  it('needs an insurer before it can generate', async () => {
    render(<CommissionStatements />);
    expect(await screen.findByRole('button', { name: 'Generate' })).toBeDisabled();
  });

  it('lists each policy with its commission status and marks pre-deferral policies as legacy', async () => {
    const user = userEvent.setup();
    await generate(user);
    const rowA = (await screen.findByText('POL-A')).closest('tr') as HTMLElement;
    expect(within(rowA).getByText('Earned')).toBeTruthy();
    const rowB = screen.getByText('POL-B').closest('tr') as HTMLElement;
    expect(within(rowB).getByText('Deferred')).toBeTruthy();
    expect(within(rowB).getByText('Beta Ltd')).toBeTruthy();
    const rowOld = screen.getByText('POL-OLD').closest('tr') as HTMLElement;
    expect(within(rowOld).getByText('Legacy (income at bind)')).toBeTruthy();
    expect(screen.getByText('3 policies')).toBeTruthy();
  });

  it('exports the statement with a total row', async () => {
    const user = userEvent.setup();
    await generate(user);
    await screen.findByText('POL-A');
    await user.click(screen.getByRole('button', { name: 'Export Excel' }));
    expect(mockExcel).toHaveBeenCalledTimes(1);
    const exportedRows = mockExcel.mock.calls[0][3] as { policy_no: string; commission: number }[];
    expect(exportedRows[exportedRows.length - 1]).toMatchObject({ policy_no: 'TOTAL', commission: 300 });
    await user.click(screen.getByRole('button', { name: 'Export PDF' }));
    expect(mockPdf).toHaveBeenCalledTimes(1);
  });

  it('refuses a period whose start is after its end, without querying policies', async () => {
    const user = userEvent.setup();
    render(<CommissionStatements />);
    await user.click(await screen.findByLabelText('Insurer'));
    await user.click(await screen.findByRole('option', { name: 'Alpha Assurance' }));
    const from = screen.getByLabelText('Bound from');
    await user.clear(from);
    await user.type(from, '2099-12-31');
    expect(await screen.findByText('The start date is after the end date.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Generate' })).toBeDisabled();
    expect(mockFrom).not.toHaveBeenCalledWith('ins_policies');
  });
  it('lets a mixed-currency period be viewed one currency at a time, without adding currencies together', async () => {
    const mixed = [
      policy({ id: 'pa', policy_no: 'POL-A', commission_amount: 100 }),
      policy({ id: 'pu', policy_no: 'POL-USD', currency: 'USD', commission_amount: 7 }),
      policy({ id: 'pv', policy_no: 'POL-USD2', currency: 'USD', commission_amount: 3 }),
    ];
    mockFrom.mockImplementation((name: string) => {
      if (name === 'ins_insurers') return selectChain([{ id: 'i1', name: 'Alpha Assurance' }]);
      if (name === 'ins_policies') return selectChain(mixed);
      if (name === 'ins_commission_ledger') return selectChain([]);
      throw new Error(`unexpected table ${name}`);
    });
    const user = userEvent.setup();
    await generate(user);
    // USD has two policies, so it is shown first.
    await screen.findByText('POL-USD');
    expect(screen.queryByText('POL-A')).toBeNull();
    expect(screen.getByText(/USD and UGX/)).toBeTruthy();
    await user.click(screen.getByLabelText('Currency'));
    await user.click(await screen.findByRole('option', { name: 'UGX' }));
    await screen.findByText('POL-A');
    expect(screen.queryByText('POL-USD')).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Export Excel' }));
    expect(mockExcel.mock.calls[0][0]).toMatch(/-UGX$/);
  });
});
