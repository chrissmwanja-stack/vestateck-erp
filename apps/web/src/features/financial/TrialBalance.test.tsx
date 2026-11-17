import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import TrialBalance from './TrialBalance';

// TrialBalance reads currency off the URL (?ccy=USD, defaulting to UGX) and an
// optional as-at date (?asOf=YYYY-MM-DD, defaulting to today), calls
// fin_trial_balance(p_as_of) filtered by that currency, and sums
// debit/credit/balance across the returned rows for a totals row. This pins
// down: the currency defaulting/switching, the as-at defaulting and override,
// the totals arithmetic, and that a query error degrades to the empty state
// rather than throwing.
//
// The reproducibility guarantee itself (same as-at date => same figures, with
// later postings and later voids ignored) is asserted in SQL, where it belongs:
// supabase/tests/test_fin_as_at_reporting.sql.

const ROW_UGX_1 = {
  account_id: 'a1',
  account_code: '1000',
  account_name: 'Cash',
  category_name: 'Assets',
  currency: 'UGX',
  total_debit: 500000,
  total_credit: 100000,
  balance: 400000,
};

const ROW_UGX_2 = {
  account_id: 'a2',
  account_code: '2000',
  account_name: 'Accounts Payable',
  category_name: 'Liabilities',
  currency: 'UGX',
  total_debit: 50000,
  total_credit: 450000,
  balance: -400000,
};

const ROW_USD_1 = {
  account_id: 'a3',
  account_code: '1010',
  account_name: 'USD Cash',
  category_name: 'Assets',
  currency: 'USD',
  total_debit: 1000,
  total_credit: 200,
  balance: 800,
};

function makeThenable(data: unknown, error: unknown = null) {
  const builder: any = {
    eq: (...args: unknown[]) => {
      calls.eq.push(args);
      return builder;
    },
    order: () => builder,
    then: (resolve: (v: { data: unknown; error: unknown }) => void) => resolve({ data, error }),
  };
  return builder;
}

let calls: { eq: unknown[][]; rpc: unknown[][] };
let mockRpcRef: ReturnType<typeof setup>['mockRpc'];

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: [string, Record<string, unknown>]) => mockRpcRef(...args),
  },
}));

function setup(opts: { rows?: unknown[]; error?: { message: string } | null } = {}) {
  const { rows = [ROW_UGX_1, ROW_UGX_2], error = null } = opts;
  calls = { eq: [], rpc: [] };

  const mockRpc = vi.fn((fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args]);
    if (fn === 'fin_trial_balance') {
      return makeThenable(rows, error);
    }
    throw new Error(`setup: no handler for rpc "${fn}"`);
  });

  return { mockRpc };
}

function activate(setupResult: ReturnType<typeof setup>) {
  mockRpcRef = setupResult.mockRpc;
}

function isoToday(): string {
  return new Date().toISOString().slice(0, 10);
}

function renderScreen(initialEntry = '/trial-balance') {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <TrialBalance />
    </MemoryRouter>
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('TrialBalance', () => {
  it('defaults to UGX, queries with that currency, and lists the returned accounts', async () => {
    const result = setup({ rows: [ROW_UGX_1, ROW_UGX_2] });
    activate(result);

    renderScreen();

    expect(await screen.findByText('Cash')).toBeInTheDocument();
    expect(screen.getByText('Accounts Payable')).toBeInTheDocument();
    expect(calls.eq).toContainEqual(['currency', 'UGX']);
    expect(calls.rpc[0][0]).toBe('fin_trial_balance');
    expect(calls.rpc[0][1]).toEqual({ p_as_of: isoToday() });
    expect(screen.getByText('Trial Balance')).toBeInTheDocument();
  });

  it('sums debit, credit, and balance across all rows into a totals row', async () => {
    const result = setup({ rows: [ROW_UGX_1, ROW_UGX_2] });
    activate(result);

    renderScreen();
    await waitFor(() => expect(screen.getByText('Cash')).toBeInTheDocument());

    // total_debit: 500000 + 50000 = 550000; total_credit: 100000 + 450000 =
    // 550000 too, so "550,000" legitimately appears twice in the totals row
    // alone (plus once more for row a2's credit cell).
    expect(screen.getAllByText('550,000').length).toBeGreaterThanOrEqual(2);
    // total balance: 400000 + (-400000) = 0
    expect(screen.getByText('0')).toBeInTheDocument();
  });

  it('switches to USD when ?ccy=USD is present, queries with USD, and labels the header', async () => {
    const result = setup({ rows: [ROW_USD_1] });
    activate(result);

    renderScreen('/trial-balance?ccy=USD');

    expect(await screen.findByText('USD Cash')).toBeInTheDocument();
    expect(calls.eq).toContainEqual(['currency', 'USD']);
    expect(screen.getByText(/Trial Balance \(USD\)/)).toBeInTheDocument();
  });

  it('shows the empty state, scoped to the active currency, when there are no rows', async () => {
    const result = setup({ rows: [] });
    activate(result);

    renderScreen();

    expect(await screen.findByText('No accounts with activity in UGX.')).toBeInTheDocument();
  });

  it('falls back to the empty state instead of throwing when the query errors', async () => {
    const result = setup({ rows: [{ bogus: true }], error: { message: 'permission denied' } });
    activate(result);

    renderScreen();

    expect(await screen.findByText('No accounts with activity in UGX.')).toBeInTheDocument();
  });
});
describe('TrialBalance as-at reporting', () => {
  it('asks for the trial balance as at the date in the URL', async () => {
    const result = setup();
    activate(result);

    renderScreen('/trial-balance?asOf=2027-12-31');

    await waitFor(() => expect(screen.getByText('Cash')).toBeInTheDocument());
    expect(calls.rpc[0][1]).toEqual({ p_as_of: '2027-12-31' });
  });

  it('re-queries when the as-at date is changed, so a past date can be reviewed', async () => {
    const result = setup();
    activate(result);

    renderScreen('/trial-balance?asOf=2027-12-31');
    await waitFor(() => expect(screen.getByText('Cash')).toBeInTheDocument());
    expect(calls.rpc).toHaveLength(1);

    const field = screen.getByLabelText('As at');
    await userEvent.clear(field);
    await userEvent.type(field, '2027-06-30');

    // A date input fires a change per keystroke, so assert on the settled
    // result rather than an exact call count.
    await waitFor(() =>
      expect(calls.rpc[calls.rpc.length - 1][1]).toEqual({ p_as_of: '2027-06-30' })
    );
    expect(calls.rpc.length).toBeGreaterThan(1);
  });

  it('shows the as-at date so a printed report cannot be mistaken for today', async () => {
    const result = setup();
    activate(result);

    renderScreen('/trial-balance?asOf=2027-12-31');
    await waitFor(() => expect(screen.getByText('Cash')).toBeInTheDocument());
    expect(screen.getByLabelText('As at')).toHaveValue('2027-12-31');
  });
});
