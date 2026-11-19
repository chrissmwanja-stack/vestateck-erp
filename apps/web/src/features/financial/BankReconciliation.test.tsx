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
  subledger_only: false,
  funding_transaction_id: null,
};
const SETTLEMENT_RECONCILED = { ...SETTLEMENT_OPEN, id: 'set-done', settlement_no: 'STL-0002' };
// A procurement settlement: allocation only, its GL entry came from the
// cash/bank transaction named by funding_transaction_id.
const SETTLEMENT_PROCUREMENT = {
  ...SETTLEMENT_OPEN,
  id: 'set-proc',
  settlement_no: 'STL-0003',
  direction: 'out',
  reference: 'INV-100',
  subledger_only: true,
  funding_transaction_id: 'cash-1',
};
// Commission transfers: money moves between two registered banks.
const TRANSFER_IN = {
  id: 'tr-in',
  transfer_no: 'CTR-0001',
  from_bank_account_id: 'bank-client-money',
  to_bank_account_id: BANK_ID,
  transfer_date: '2026-10-01',
  amount: 500000,
  currency: 'UGX',
  notes: null,
};
const TRANSFER_OUT_DONE = { ...TRANSFER_IN, id: 'tr-out-done', transfer_no: 'CTR-0002', from_bank_account_id: BANK_ID, to_bank_account_id: 'bank-other' };
const TRANSFER_ELSEWHERE = { ...TRANSFER_IN, id: 'tr-else', transfer_no: 'CTR-0003', from_bank_account_id: 'bank-x', to_bank_account_id: 'bank-y' };
const SUGGESTION = {
  statement_line_id: 'line-1',
  statement_date: '2026-10-02',
  reference: 'REF1',
  line_amount: 500000,
  currency: 'UGX',
  suggestion_rank: 1,
  source: 'cash_bank',
  candidate_id: 'cash-1',
  candidate_ref: 'Legacy receipt',
  candidate_date: '2026-10-02',
  candidate_amount: 500000,
  day_gap: 0,
  needs_third_user: false,
};

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
    auth: {
      getUser: () => Promise.resolve({ data: { user: { id: 'fin-user-1' } } }),
    },
  },
}));

function builderFor(table: string) {
  const builder: any = {};
  for (const m of ['select', 'eq', 'gte', 'lte', 'in', 'order', 'limit']) builder[m] = () => builder;
  builder.then = (resolve: (v: { data: unknown; error: unknown }) => void) =>
    resolve({ data: tableData[table] ?? [], error: null });
  return builder;
}

function setup(opts: {
  registry?: unknown[];
  position?: unknown[];
  positionError?: { message: string } | null;
  extraHandlers?: Record<string, (args: unknown) => { data?: unknown; error?: unknown }>;
  transfers?: unknown[];
  reconRows?: unknown[];
  settlements?: unknown[];
  suggestions?: unknown[];
  suggestionsError?: { message: string } | null;
} = {}) {
  tableData = {
    fin_bank_accounts: opts.registry ?? [{ id: BANK_ID, name: 'Stanbic-001', currency: 'UGX' }],
    v_bank_statement_unmatched: [LINE],
    v_cash_bank_unmatched: [CASH_TXN],
    v_bank_reconciliation_variance: [],
    v_bank_possible_double_entries: [],
    fin_settlements: opts.settlements ?? [SETTLEMENT_OPEN, SETTLEMENT_RECONCILED],
    bank_reconciliations: opts.reconRows ?? [{ settlement_id: SETTLEMENT_RECONCILED.id }],
    ins_commission_transfers: opts.transfers ?? [],
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
    match_bank_statement_line_to_commission_transfer: () => ({ data: { variance: 0 }, error: null }),
    // Suggest-and-confirm (migration 20261117170000).
    fin_bank_suggested_matches: () =>
      opts.suggestionsError
        ? { data: null, error: opts.suggestionsError }
        : { data: opts.suggestions ?? [], error: null },
    fin_bank_confirm_match: () => ({ data: { variance: 0 }, error: null }),
    auto_match_bank_statement: () => ({ data: 2, error: null }),
    // The adjustments panel asks the server whether the company's one-person
    // exception is in force before it offers self-approval (D4e completion).
    bank_adjustment_can_self_approve: () => ({ data: false, error: null }),
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

  it('shows suggested matches and confirms one through fin_bank_confirm_match', async () => {
    const { callsTo } = setup({ suggestions: [SUGGESTION] });
    const user = userEvent.setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText(/Suggested matches \(1 line\)/);
    expect(screen.getAllByText('Legacy receipt').length).toBeGreaterThan(0);

    await user.click(screen.getByRole('button', { name: 'Confirm' }));

    await waitFor(() => expect(callsTo('fin_bank_confirm_match').length).toBe(1));
    expect(callsTo('fin_bank_confirm_match')[0].args).toMatchObject({
      p_statement_line_id: 'line-1',
      p_source: 'cash_bank',
      p_candidate_id: 'cash-1',
    });
  });

  it('warns before confirming a match that needs a third Finance user', async () => {
    // The badge is a hint; the database refuses the match either way. But the
    // desk should be told what will happen before it clicks.
    setup({ suggestions: [{ ...SUGGESTION, source: 'settlement', needs_third_user: true }] });
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('Needs a third Finance user');
  });

  it('keeps manual matching usable when the suggestion queue fails to load', async () => {
    setup({ suggestionsError: { message: 'not authorized to see bank reconciliation suggestions' } });
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText(/Suggested matches could not be loaded/);
    // The statement lines themselves are still there to work with.
    expect(await screen.findByText(/CLIENT DEPOSIT/)).toBeTruthy();
  });

  it('marks a procurement settlement as an allocation only, not as its own journal', async () => {
    // Finding E1: a procurement payment settles its open item through a
    // subledger-only settlement. Its GL entry came from the cash/bank
    // transaction, so the book must not imply this row posted a journal.
    setup({ settlements: [SETTLEMENT_PROCUREMENT] });
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('STL-0003');
    expect(screen.getByText('From procurement')).toBeTruthy();
    expect(screen.queryByText('STL-0001')).toBeNull();
  });

  it('matches a statement line to a commission transfer through the transfer RPC', async () => {
    const { callsTo } = setup({ transfers: [TRANSFER_IN] });
    const user = userEvent.setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('CTR-0001');
    expect(screen.getByText('Into this account')).toBeTruthy();
    await user.click(screen.getByText('CLIENT DEPOSIT'));
    await user.click(screen.getByText('CTR-0001'));
    await user.click(screen.getByRole('button', { name: 'Match Selected Pair' }));

    await waitFor(() => expect(callsTo('match_bank_statement_line_to_commission_transfer')).toHaveLength(1));
    expect(callsTo('match_bank_statement_line_to_commission_transfer')[0].args).toEqual({
      p_statement_line_id: 'line-1',
      p_transfer_id: 'tr-in',
    });
    expect(callsTo('match_bank_statement_line_to_settlement')).toHaveLength(0);
    expect(callsTo('match_bank_statement_line')).toHaveLength(0);
  });

  it('hides a transfer side that is already reconciled and transfers between other banks', async () => {
    setup({
      transfers: [TRANSFER_IN, TRANSFER_OUT_DONE, TRANSFER_ELSEWHERE],
      reconRows: [{ commission_transfer_id: 'tr-out-done', transfer_side: 'from' }],
    });
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('CTR-0001');
    expect(screen.queryByText('CTR-0002')).toBeNull();
    expect(screen.queryByText('CTR-0003')).toBeNull();
    expect(screen.getByText(/Open Commission Transfers \(1\)/)).toBeTruthy();
  });

  it('shows no transfer list when the account has no open transfers', async () => {
    setup();
    render(<BankReconciliation />);
    await openAccount('Stanbic-001');

    await screen.findByText('STL-0001');
    expect(screen.queryByTestId('transfer-sides-table')).toBeNull();
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
