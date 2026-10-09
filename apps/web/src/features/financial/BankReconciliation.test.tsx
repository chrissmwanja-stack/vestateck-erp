import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import BankReconciliation from './BankReconciliation';
import { mockSupabaseRpc } from '../../test/rpcHarness';

// D4d-2: the screen now matches statement lines against posted
// settlements as well as legacy cash/bank transactions. This pins down the
// parts with real client-side branching: which RPC a match goes to, that
// already-reconciled settlements are hidden, that the registry gate keeps
// settlement/position queries off unregistered bank names, and that the
// double-entry and unexplained-difference warnings appear.

const BANK_ID = 'bank-1';
const LINE = {
  id: 'line-1',
  statement_date: '2026-10-02',
  description: 'CLIENT DEPOSIT',
  reference: 'REF1',
  amount: 500000,
  currency: 'UGX',
};
const SETTLEMENT_OPEN = {
  id: 'set-open',
  settlement_no: 'STL-0001',
  direction: 'in',
  amount: 500000,
  currency: 'UGX',
  settlement_date: '2026-10-01',
  reference: null,
  notes: null,
};
const SETTLEMENT_RECONCILED = { ...SETTLEMENT_OPEN, id: 'set-done', settlement_no: 'STL-0002' };
const CASH_TXN = {
  id: 'cash-1',
  transaction_date: '2026-10-02',
  transaction_type: 'receipt',
  amount: 500000,
  currency: 'UGX',
  description: 'Legacy receipt',
  reference_type: 'receivable_invoice',
};

type TableData = Record<string, unknown[]>;
let tableData: TableData;
let fromCalls: string[];
const mockRpc = vi.fn();
const mockFrom = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: [string]) => mockFrom(...args),
    rpc: (...args: [string, unknown?]) => mockRpc(...args),
  },
}));

function builderFor(table: string) {
  const builder: any = {};
  for (const m of ['select', 'eq', 'gte', 'lte', 'in', 'order']) builder[m] = () => builder;
  builder.then = (resolve: (v: { data: unknown; error: unknown }) => void) =>
    resolve({ data: tableData[table] ?? [], error: null });
  return builder;
}

function setup(opts: {
  registry?: unknown[];
  position?: unknown[];
  positionError?: { message: string } | null;
  extraHandlers?: Record<string, (args: unknown) => { data?: unknown; error?: unknown }>;
} = {}) {
  tableData = {
    fin_bank_accounts: opts.registry ?? [{ id: BANK_ID, name: 'Stanbic-001', currency: 'UGX' }],
    v_bank_statement_unmatched: [LINE],
    v_cash_bank_unmatched: [CASH_TXN],
    v_bank_reconciliation_variance: [],
    v_bank_possible_double_entries: [],
    fin_settlements: [SETTLEMENT_OPEN, SETTLEMENT_RECONCILED],
    bank_reconciliations: [{ settlement_id: SETTLEMENT_RECONCILED.id }],
  };
  fromCalls = [];
  mockFrom.mockImplementation((table: string) => {
    fromCalls.push(table);
    return builderFor(table);
  });
  return mockSupabaseRpc(mockRpc, {
    is_finance_team_member: () => ({ data: true }),
    fin_bank_reconciliation_position: () =>
      opts.positionError
        ? { data: null, error: opts.positionError }
        : {
            data: opts.position ?? [
              { line_order: 5, component: 'unexplained_difference', label: 'Unexplained', amount: 0 },
              { line_order: 1, component: 'gl_balance', label: 'GL balance', amount: 1000000 },
              { line_order: 4, component: 'expected_statement_balance', label: 'Expected statement closing balance', amount: 1250000 },
            ],
            error: null,
          },
    match_bank_statement_line_to_settlement: () => ({ data: { variance: 0 }, error: null }),
    match_bank_statement_line: () => ({ data: { variance: 0 }, error: null }),
    auto_match_bank_statement: () => ({ data: 2, error: null }),
    ...opts.extraHandlers,
  });
}

async function openAccount(name: string) {
  const input = screen.getByLabelText('Bank Account');
  fireEvent.change(input, { target: { value: name } });
}

describe('BankReconciliation', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    mockFrom.mockReset();
  });

  it('matches a statement line to a settlement through the settlement RPC, not the legacy one', async () => {
    const { callsTo } = setup();
    const user = userEvent.setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('STL-0001');
    await user.click(screen.getByText('CLIENT DEPOSIT'));
    await user.click(screen.getByText('STL-0001'));
    await user.click(screen.getByRole('button', { name: 'Match Selected Pair' }));

    await waitFor(() => expect(callsTo('match_bank_statement_line_to_settlement')).toHaveLength(1));
    expect(callsTo('match_bank_statement_line_to_settlement')[0].args).toEqual({
      p_statement_line_id: 'line-1',
      p_settlement_id: 'set-open',
    });
    expect(callsTo('match_bank_statement_line')).toHaveLength(0);
  });

  it('still matches against a legacy cash/bank transaction through the original RPC', async () => {
    const { callsTo } = setup();
    const user = userEvent.setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('Legacy receipt');
    await user.click(screen.getByText('CLIENT DEPOSIT'));
    await user.click(screen.getByText('Legacy receipt'));
    await user.click(screen.getByRole('button', { name: 'Match Selected Pair' }));

    await waitFor(() => expect(callsTo('match_bank_statement_line')).toHaveLength(1));
    expect(callsTo('match_bank_statement_line')[0].args).toEqual({
      p_statement_line_id: 'line-1',
      p_cash_bank_transaction_id: 'cash-1',
    });
    expect(callsTo('match_bank_statement_line_to_settlement')).toHaveLength(0);
  });

  it('hides settlements that already have a reconciliation row', async () => {
    setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('STL-0001');
    expect(screen.queryByText('STL-0002')).toBeNull();
    expect(screen.getByText(/Open Settlements \(1\)/)).toBeTruthy();
  });

  it('does not query settlements or the position for a bank name missing from the registry', async () => {
    const { callsTo } = setup({ registry: [] });
    render(<BankReconciliation />);
    await openAccount('Some Other Bank');

    await screen.findByText(/not in the bank account registry/);
    expect(fromCalls).not.toContain('fin_settlements');
    expect(callsTo('fin_bank_reconciliation_position')).toHaveLength(0);
    // Statement lines and legacy transactions still load.
    expect(screen.getByText('CLIENT DEPOSIT')).toBeTruthy();
  });

  it('shows the position with the unexplained difference called out separately', async () => {
    setup({
      position: [
        { line_order: 1, component: 'gl_balance', label: 'GL balance', amount: 1000000 },
        { line_order: 4, component: 'expected_statement_balance', label: 'Expected statement closing balance', amount: 1250000 },
        { line_order: 5, component: 'unexplained_difference', label: 'Unexplained', amount: 75000 },
      ],
    });
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    const panel = await screen.findByTestId('position-panel');
    expect(within(panel).getByText('Expected statement closing balance')).toBeTruthy();
    // The unexplained line is an alert, not a row in the balance table.
    expect(within(panel).queryByText('Unexplained')).toBeNull();
    expect(within(panel).getByText(/Unexplained difference/)).toBeTruthy();
    expect(within(panel).getByText('75,000')).toBeTruthy();
  });

  it('keeps the lines usable when the position call fails', async () => {
    setup({ positionError: { message: 'permission denied' } });
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('permission denied');
    expect(screen.getByText('CLIENT DEPOSIT')).toBeTruthy();
    expect(screen.getByText('STL-0001')).toBeTruthy();
  });

  it('warns about possible double entries only for lines in the current window', async () => {
    setup();
    render(<BankReconciliation />);
    tableData.v_bank_possible_double_entries = [
      { statement_line_id: 'line-1' },
      { statement_line_id: 'line-outside-window' },
    ];
    await openAccount('Stanbic-001');

    const alert = await screen.findByTestId('double-entry-alert');
    expect(alert.textContent).toContain('1 statement line could match both');
    expect(screen.getByText('Possible double entry')).toBeTruthy();
  });

  it('reports a non-zero variance after a match', async () => {
    setup({
      extraHandlers: { match_bank_statement_line_to_settlement: () => ({ data: { variance: 1500 }, error: null }) },
    });
    const user = userEvent.setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('STL-0001');
    await user.click(screen.getByText('CLIENT DEPOSIT'));
    await user.click(screen.getByText('STL-0001'));
    await user.click(screen.getByRole('button', { name: 'Match Selected Pair' }));

    await screen.findByText(/Matched with a variance of 1,500/);
  });

  it('surfaces a server-side match refusal instead of swallowing it', async () => {
    setup({
      extraHandlers: {
        match_bank_statement_line_to_settlement: () => ({ data: null, error: { message: 'currency mismatch' } }),
      },
    });
    const user = userEvent.setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('STL-0001');
    await user.click(screen.getByText('CLIENT DEPOSIT'));
    await user.click(screen.getByText('STL-0001'));
    await user.click(screen.getByRole('button', { name: 'Match Selected Pair' }));

    await screen.findByText('currency mismatch');
  });
});
