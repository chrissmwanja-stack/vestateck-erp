import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import BankAdjustmentRegister from './BankAdjustmentRegister';
import BankAdjustmentUnusualAccounts from './BankAdjustmentUnusualAccounts';

// The two accountant-facing D4e screens read through the untyped db handle.
// These tests pin the parts that matter to a reviewer:
//   register      - self-approved rows are surfaced and counted, filters work,
//                   and a rejected row keeps its reason on screen;
//   unusual       - an empty usual-account list explains itself, flagged rows
//                   render, and adding/removing a usual account goes through
//                   the RPCs rather than a table write.

const ADJ_SELF = {
  id: 'a-self', kind: 'adjustment', status: 'posted',
  amount: 50000, currency: 'UGX', direction: 'out', reason: 'bank charge',
  bank_account: 'Stanbic-001', statement_date: '2026-11-10',
  created_by: 'u1', created_at: '2026-11-10T09:00:00Z',
  decided_at: '2026-11-10T09:05:00Z', self_approved: true, approval_mode: 'one_person_exception',
  rejection_reason: null, reversal_reason: null, reworked_from: null,
  line: { statement_date: '2026-11-10', description: 'BANK CHARGE', reference: 'CHG1' },
  counter: { account_code: '5000', name: 'Bank Charges' },
  created_by_name: 'Finance Maker', approver_name: 'Finance Maker',
};
const ADJ_REJECTED = {
  ...ADJ_SELF, id: 'a-rej', status: 'rejected', self_approved: false, approval_mode: null,
  reason: 'interest first attempt', rejection_reason: 'wrong counter-account',
  decided_at: '2026-11-11T09:00:00Z', created_by: 'u2', created_by_name: 'Finance Checker',
};
const UNUSUAL = [
  {
    adjustment_id: 'a-self', bank_account: 'Stanbic-001', statement_date: '2026-11-10',
    currency: 'UGX', amount: 50000, direction: 'out',
    counter_account_code: '5099', counter_account_name: 'Sundry Expenses',
    reason: 'bank charge', created_by_name: 'Finance Maker', approver_name: 'Finance Maker',
    approval_date: '2026-11-10T09:05:00Z', posting_journal_reference: 'je-1', self_approved: true,
  },
];
const GL_OPTIONS = [
  { id: 'gl-1', account_code: '5000', name: 'Bank Charges' },
  { id: 'gl-7', account_code: '1100', name: 'Trade Receivables', is_control_account: true },
];

let tableData: Record<string, unknown[]>;
let rpcData: Record<string, unknown>;
const mockRpc = vi.fn();
const mockFrom = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: [string]) => mockFrom(...args),
    rpc: (...args: [string, unknown?]) => mockRpc(...args),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }) },
  },
}));

function builderFor(table: string) {
  const builder: any = {};
  for (const m of ['select', 'eq', 'gte', 'lte', 'in', 'order', 'limit']) builder[m] = () => builder;
  builder.then = (resolve: (v: { data: unknown; error: unknown }) => void) =>
    resolve({ data: tableData[table] ?? [], error: null });
  return builder;
}

function setup({
  adjustments = [ADJ_SELF, ADJ_REJECTED],
  unusual = UNUSUAL,
  usual = [] as unknown[],
  gl = GL_OPTIONS,
}: {
  adjustments?: unknown[];
  unusual?: unknown[];
  usual?: unknown[];
  gl?: unknown[];
} = {}) {
  tableData = { bank_adjustments: adjustments, gl_accounts: gl };
  rpcData = {
    bank_adjustment_unusual_account_usage: unusual,
    bank_adjustment_list_usual_accounts: usual,
    bank_adjustment_can_self_approve: true,
    bank_adjustment_add_usual_account: null,
    bank_adjustment_remove_usual_account: null,
  };
  mockFrom.mockImplementation((table: string) => builderFor(table));
  mockRpc.mockImplementation((name: string) =>
    Promise.resolve({ data: rpcData[name] ?? null, error: null })
  );
}

describe('BankAdjustmentRegister', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    mockFrom.mockReset();
  });

  it('surfaces self-approved adjustments for the accountant and flags them per row', async () => {
    setup();
    render(<BankAdjustmentRegister />);

    const alert = await screen.findByTestId('register-exception-alert');
    expect(within(alert).getByText(/1 adjustment is self-approved/i)).toBeInTheDocument();

    const table = await screen.findByTestId('adjustment-register-table');
    expect(within(table).getByText('self-approved')).toBeInTheDocument();
    expect(within(table).getByText('Finance Maker')).toBeInTheDocument();
  });

  it('keeps the rejection reason visible in the register', async () => {
    setup();
    render(<BankAdjustmentRegister />);
    const table = await screen.findByTestId('adjustment-register-table');
    expect(within(table).getByText(/Rejected: wrong counter-account/)).toBeInTheDocument();
  });

  it('filters to self-approved only, and says so when nothing matches', async () => {
    setup({ adjustments: [ADJ_REJECTED] });
    render(<BankAdjustmentRegister />);
    await screen.findByTestId('adjustment-register-table');

    fireEvent.mouseDown(screen.getByLabelText('Show'));
    fireEvent.click(await screen.findByRole('option', { name: 'Self-approved (one-person exception)' }));

    expect(await screen.findByText('No adjustments match this filter.')).toBeInTheDocument();
  });

  it('filters by bank account', async () => {
    setup();
    render(<BankAdjustmentRegister />);
    await screen.findByTestId('adjustment-register-table');

    fireEvent.change(screen.getByLabelText('Bank account'), { target: { value: 'other bank' } });
    expect(await screen.findByText('No adjustments match this filter.')).toBeInTheDocument();
  });
});

describe('BankAdjustmentUnusualAccounts', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    mockFrom.mockReset();
  });

  it('explains that everything is flagged while no usual accounts are configured', async () => {
    setup({ usual: [] });
    render(<BankAdjustmentUnusualAccounts />);

    expect(await screen.findByTestId('usual-empty-alert')).toBeInTheDocument();
    const table = await screen.findByTestId('unusual-accounts-table');
    expect(within(table).getByText('5099 Sundry Expenses')).toBeInTheDocument();
    expect(within(table).getByText('self-approved')).toBeInTheDocument();
  });

  it('reads the report for the selected period', async () => {
    setup();
    render(<BankAdjustmentUnusualAccounts />);
    await screen.findByTestId('unusual-accounts-table');
    expect(mockRpc).toHaveBeenCalledWith('bank_adjustment_unusual_account_usage', { p_days: 90 });

    fireEvent.mouseDown(screen.getByLabelText('Period'));
    fireEvent.click(await screen.findByRole('option', { name: 'Last 30 days' }));
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('bank_adjustment_unusual_account_usage', { p_days: 30 })
    );
  });

  it('adds a usual account through the RPC, not a table write, and refuses a control account', async () => {
    setup();
    render(<BankAdjustmentUnusualAccounts />);
    const user = userEvent.setup();

    await user.click(await screen.findByRole('button', { name: /Usual accounts/ }));
    const dialog = await screen.findByRole('dialog');

    await user.click(within(dialog).getByLabelText('Add an account'));
    const control = await screen.findByRole('option', { name: '1100 Trade Receivables' });
    expect(control).toHaveAttribute('aria-disabled', 'true');

    const usable = await screen.findByRole('option', { name: '5000 Bank Charges' });
    await user.click(usable);
    await user.click(within(dialog).getByRole('button', { name: 'Add' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('bank_adjustment_add_usual_account', { p_gl_account_id: 'gl-1' })
    );
    expect(mockFrom).not.toHaveBeenCalledWith('bank_adjustment_usual_accounts');
  });

  it('removes a usual account through the RPC', async () => {
    setup({ usual: [{ gl_account_id: 'gl-1', account_code: '5000', account_name: 'Bank Charges', created_at: '2026-11-01T00:00:00Z' }] });
    render(<BankAdjustmentUnusualAccounts />);
    const user = userEvent.setup();

    await user.click(await screen.findByRole('button', { name: /Usual accounts \(1\)/ }));
    await user.click(await screen.findByRole('button', { name: 'Remove 5000' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('bank_adjustment_remove_usual_account', { p_gl_account_id: 'gl-1' })
    );
  });
});
