import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ProductionBook from './ProductionBook';

// The production book screen: reads the ins_production_book view, groups by the
// chosen dimension, totals per currency, and offers Excel/PDF export.

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

let book: {
  policy_id: string; policy_no: string; client_name: string; insurer_name: string;
  branch_name: string | null; agent_name: string | null; product_line_name: string;
  transaction_type: string; status: string; bound_date: string; currency: string;
  gross_premium: number; commission_amount: number; net_premium_to_insurer: number;
}[] = [];

function builder(result: () => { data: unknown; error: { message: string } | null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'gte', 'lte', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

beforeEach(() => {
  book = [];
  mockFrom.mockReset();
  mockFrom.mockImplementation((name: string) => {
    if (name === 'tenant_ledger_settings') return builder(() => ({ data: [{ functional_currency: 'UGX' }], error: null }));
    return builder(() => ({ data: book, error: null }));
  });
});

describe('ProductionBook', () => {
  it('groups written business by client with per-currency totals and a grand total', async () => {
    book = [
      { policy_id: 'p1', policy_no: 'POL-1', client_name: 'Acme', insurer_name: 'Jubilee', branch_name: 'Kampala', agent_name: null, product_line_name: 'Motor', transaction_type: 'new_business', status: 'active', bound_date: '2026-10-01', currency: 'UGX', gross_premium: 1000, commission_amount: 100, net_premium_to_insurer: 900 },
      { policy_id: 'p2', policy_no: 'POL-2', client_name: 'Acme', insurer_name: 'Jubilee', branch_name: 'Kampala', agent_name: null, product_line_name: 'Motor', transaction_type: 'renewal', status: 'active', bound_date: '2026-10-05', currency: 'UGX', gross_premium: 500, commission_amount: 50, net_premium_to_insurer: 450 },
      { policy_id: 'p3', policy_no: 'POL-3', client_name: 'Beta', insurer_name: 'Jubilee', branch_name: null, agent_name: 'Jane', product_line_name: 'Fire', transaction_type: 'new_business', status: 'active', bound_date: '2026-10-07', currency: 'USD', gross_premium: 200, commission_amount: 20, net_premium_to_insurer: 180 },
    ];
    render(<ProductionBook />);
    await screen.findByText('Acme');
    expect(screen.getByText('Beta')).toBeInTheDocument();
    // Default grouping is by client: two groups + the total row.
    expect(screen.getByText('Total (3 policies)')).toBeInTheDocument();
    // Acme row: 2 policies, 1500 gross.
    const acmeRow = screen.getByText('Acme').closest('tr');
    expect(acmeRow).toHaveTextContent('2');
    expect(acmeRow).toHaveTextContent('UGX 1,500.00');
  });

  it('regroups by another dimension and shows unassigned values as their own group', async () => {
    book = [
      { policy_id: 'p1', policy_no: 'POL-1', client_name: 'Acme', insurer_name: 'Jubilee', branch_name: null, agent_name: null, product_line_name: 'Motor', transaction_type: 'new_business', status: 'active', bound_date: '2026-10-01', currency: 'UGX', gross_premium: 1000, commission_amount: 100, net_premium_to_insurer: 900 },
      { policy_id: 'p2', policy_no: 'POL-2', client_name: 'Beta', insurer_name: 'Jubilee', branch_name: 'Kampala', agent_name: 'Jane', product_line_name: 'Fire', transaction_type: 'new_business', status: 'active', bound_date: '2026-10-05', currency: 'UGX', gross_premium: 500, commission_amount: 50, net_premium_to_insurer: 450 },
    ];
    render(<ProductionBook />);
    await screen.findByText('Acme');
    await userEvent.click(screen.getByLabelText('Group by'));
    await userEvent.click(await screen.findByRole('option', { name: 'Agent' }));
    expect(await screen.findByText('Jane')).toBeInTheDocument();
    expect(screen.getByText('No agent')).toBeInTheDocument();
  });

  it('says when nothing was written in the period', async () => {
    render(<ProductionBook />);
    expect(await screen.findByText(/no business was written in this period/i)).toBeInTheDocument();
    expect(screen.getByText(/a policy appears here once it is bound/i)).toBeInTheDocument();
  });

  it('surfaces read errors from the view', async () => {
    mockFrom.mockImplementation((name: string) => {
      if (name === 'tenant_ledger_settings') return builder(() => ({ data: [], error: null }));
      return builder(() => ({ data: null, error: { message: 'INS_FORBIDDEN: no' } }));
    });
    render(<ProductionBook />);
    expect(await screen.findByText(/no$/)).toBeInTheDocument();
  });

  it('offers the exports', async () => {
    render(<ProductionBook />);
    await screen.findByText(/no business was written/i);
    expect(screen.getByRole('button', { name: 'Excel' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'PDF' })).toBeInTheDocument();
  });

  it('queries the ins_production_book view once per load', async () => {
    render(<ProductionBook />);
    await screen.findByText(/no business was written/i);
    expect(mockFrom.mock.calls.filter(([t]) => t === 'ins_production_book')).toHaveLength(1);
  });
});
