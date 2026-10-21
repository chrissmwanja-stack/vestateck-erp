import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClientStatements from './ClientStatements';

// Statements of account and aged balances: 'All clients' shows the aged
// subsidiary balances (outstanding premium per client and bucket); picking a
// client shows their statement (billed, received, balance per policy).

const mockFrom = vi.fn();


// Deterministic money strings: en-UG ICU renders UGX as "USh 1,500" (and can
// vary by ICU build), so pin the formatter to "<CODE> <amount>" for tests.
class FixedNumberFormat {
  constructor(_locale: string | undefined, opts?: { currency?: string; maximumFractionDigits?: number }) {
    const digits = opts?.maximumFractionDigits ?? 2;
    const code = opts?.currency ?? 'UGX';
    this.format = (n: number) => `${code} ${n.toLocaleString('en', { minimumFractionDigits: digits, maximumFractionDigits: digits })}`;
  }
  format!: (n: number) => string;
}
vi.stubGlobal('Intl', { ...globalThis.Intl, NumberFormat: FixedNumberFormat as unknown as typeof Intl.NumberFormat });

vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (name: string) => mockFrom(name), rpc: vi.fn() },
}));

let stmt: {
  policy_id: string; policy_no: string; client_id: string; client_name: string; currency: string;
  billed_amount: number; received_amount: number; balance_amount: number;
  bound_date: string; expiry_date: string; status: string;
}[] = [];

function builder(result: () => { data: unknown; error: { message: string } | null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'gte', 'lte', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

beforeEach(() => {
  stmt = [];
  mockFrom.mockReset();
  mockFrom.mockImplementation((name: string) => {
    if (name === 'tenant_ledger_settings') return builder(() => ({ data: [{ functional_currency: 'UGX' }], error: null }));
    return builder(() => ({ data: stmt, error: null }));
  });
});

const row = (over: Partial<typeof stmt[number]>) => ({
  policy_id: 'p1', policy_no: 'POL-1', client_id: 'c1', client_name: 'Acme', currency: 'UGX',
  billed_amount: 1000, received_amount: 400, balance_amount: 600,
  bound_date: '2026-10-01', expiry_date: '2027-09-30', status: 'active', ...over,
});

describe('ClientStatements', () => {
  it('shows aged balances across clients when no client is picked', async () => {
    stmt = [
      row({}),
      row({ policy_id: 'p2', policy_no: 'POL-2', bound_date: '2026-06-01', balance_amount: 0, received_amount: 1000 }), // settled
      row({ policy_id: 'p3', policy_no: 'POL-3', client_name: 'Beta', client_id: 'c2', bound_date: '2026-06-01', billed_amount: 800, received_amount: 300, balance_amount: 500 }),
    ];
    render(<ClientStatements />);
    await screen.findByText('Acme');
    // Acme 600 in the not-yet-due bucket, Beta 500 over 90 days.
    expect(screen.getByText('Beta')).toBeInTheDocument();
    // 600 shows up in Acme's not-yet-due bucket and their row total.
    expect(screen.getAllByText('UGX 600.00').length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('UGX 500.00').length).toBeGreaterThanOrEqual(1);
    expect(screen.queryByText(/nothing outstanding/i)).not.toBeInTheDocument();
  });

  it('shows a client statement with billed, received and balance, and the age strip', async () => {
    stmt = [
      row({}),
      row({ policy_id: 'p2', policy_no: 'POL-2', bound_date: '2026-06-01', billed_amount: 800, received_amount: 300, balance_amount: 500 }),
    ];
    render(<ClientStatements />);
    await screen.findByText('Acme');
    await userEvent.click(screen.getByLabelText('Client'));
    await userEvent.click(await screen.findByRole('option', { name: 'Acme' }));

    expect(await screen.findByText('POL-1')).toBeInTheDocument();
    expect(screen.getByText('POL-2')).toBeInTheDocument();
    expect(screen.getByText('UGX 1,800.00')).toBeInTheDocument(); // billed total
    expect(screen.getByText('UGX 1,100.00')).toBeInTheDocument(); // balance total
    expect(screen.getByText(/age of the outstanding balance/i)).toBeInTheDocument();
  });

  it('says when everything is paid', async () => {
    stmt = [row({ balance_amount: 0, received_amount: 1000 })];
    render(<ClientStatements />);
    expect(await screen.findByText(/every policy is fully paid/i)).toBeInTheDocument();
  });
});
