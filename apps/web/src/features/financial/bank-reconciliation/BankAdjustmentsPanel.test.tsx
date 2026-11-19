import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { BankAdjustmentsPanel } from './BankAdjustmentsPanel';
import type { StatementLine } from './types';

// D4e: the adjustments panel talks to bank_adjustments via the untyped db
// handle and to create_bank_adjustment / approve_bank_adjustment /
// reject_bank_adjustment / request_bank_adjustment_reversal. The server
// enforces the two-person rule; these tests pin the client-side behaviour:
// own proposals cannot be self-approved from the screen, proposing requires a
// counter-account and >= 5 character reason, rejection requires a reason, and
// reversing a POSTED adjustment requests a reversal instead of doing it.

const LINE: StatementLine = {
  id: 'line-1',
  statement_date: '2026-11-10',
  description: 'BANK CHARGE',
  reference: 'CHG1',
  amount: -50000,
  currency: 'UGX',
};

const ADJ_OWN = {
  id: 'adj-own', kind: 'adjustment', status: 'pending',
  amount: 50000, currency: 'UGX', direction: 'out',
  reason: 'bank charge per statement', bank_account: 'Stanbic-001',
  created_by: 'user-a', created_at: '2026-11-10T09:00:00Z',
  rejection_reason: null, reversal_reason: null,
  line: { statement_date: '2026-11-10', description: 'BANK CHARGE', reference: 'CHG1' },
  counter: { account_code: '5000', name: 'Bank Charges' },
};
const ADJ_OTHER = {
  ...ADJ_OWN, id: 'adj-other', created_by: 'user-b', reason: 'insurance settlement fee',
  line: { statement_date: '2026-11-10', description: 'FEE', reference: 'FEE1' },
};
const ADJ_POSTED = {
  ...ADJ_OWN, id: 'adj-posted', status: 'posted', created_by: 'user-b',
  amount: 20000, direction: 'in', reason: 'interest received',
  line: { statement_date: '2026-11-08', description: 'INTEREST', reference: 'INT1' },
  counter: { account_code: '4100', name: 'Interest Received' },
};
const ADJ_ELSEWHERE = {
  ...ADJ_OWN, id: 'adj-elsewhere', bank_account: 'OtherBank-9', reason: 'account at another bank',
};
const GL_OPTIONS = [
  { id: 'gl-1', account_code: '5000', name: 'Bank Charges' },
  { id: 'gl-2', account_code: '4100', name: 'Interest Received' },
];

let tableData: Record<string, unknown[]>;
const mockRpc = vi.fn();
const mockFrom = vi.fn();

vi.mock('../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: [string]) => mockFrom(...args),
    rpc: (...args: [string, unknown?]) => mockRpc(...args),
    auth: {
      getUser: () => Promise.resolve({ data: { user: { id: 'user-a' } } }),
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

function setup(rows: unknown[] = [ADJ_OWN, ADJ_OTHER, ADJ_POSTED]) {
  tableData = { bank_adjustments: rows, gl_accounts: GL_OPTIONS };
  mockFrom.mockImplementation((table: string) => builderFor(table));
  mockRpc.mockImplementation(() => Promise.resolve({ data: { id: 'new-adj' }, error: null }));
}

function renderPanel(overrides: Partial<Parameters<typeof BankAdjustmentsPanel>[0]> = {}) {
  const onChanged = vi.fn();
  const onError = vi.fn();
  render(
    <BankAdjustmentsPanel
      bankAccountName="Stanbic-001"
      selectedLine={LINE}
      onChanged={onChanged}
      onError={onError}
      {...overrides}
    />
  );
  return { onChanged, onError };
}

describe('BankAdjustmentsPanel', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    mockFrom.mockReset();
  });

  it('hides the approve button state on your own proposal but not on somebody else’s', async () => {
    setup();
    renderPanel();
    const approves = await screen.findAllByRole('button', { name: 'Approve' });
    expect(approves[0]).toBeDisabled();
    expect(approves[1]).toBeEnabled();
    // The creator sees Withdraw on their own proposal; others see Reject.
    expect(screen.getByRole('button', { name: 'Withdraw' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Reject' })).toBeInTheDocument();
  });

  it('hides adjustments booked to a different bank account', async () => {
    setup([ADJ_ELSEWHERE]);
    renderPanel();
    await waitFor(() => expect(screen.queryByText('account at another bank')).not.toBeInTheDocument());
    expect(screen.getByText(/No adjustments for this bank account yet/)).toBeInTheDocument();
  });

  it('proposes an adjustment for the selected line through create_bank_adjustment', async () => {
    setup([]);
    const { onChanged, onError } = renderPanel();
    const user = userEvent.setup();

    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'bank charge per statement' } });
    const combo = screen.getByLabelText('Other side of the entry');
    fireEvent.mouseDown(combo);
    const option = await screen.findByRole('option', { name: '5000 Bank Charges' });
    await user.click(option);

    await user.click(screen.getByRole('button', { name: 'Propose adjustment' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('create_bank_adjustment', {
        p_statement_line_id: 'line-1',
        p_counter_account_id: 'gl-1',
        p_reason: 'bank charge per statement',
      })
    );
    expect(onChanged).toHaveBeenCalledWith(expect.stringContaining('different finance user must approve'));
    expect(onError).not.toHaveBeenCalled();
  });

  it('approving somebody else’s proposal calls approve_bank_adjustment', async () => {
    setup();
    renderPanel();
    const user = userEvent.setup();
    const approves = await screen.findAllByRole('button', { name: 'Approve' });
    await user.click(approves[1]);
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: 'Approve and post' }));
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('approve_bank_adjustment', { p_adjustment_id: 'adj-other' })
    );
  });

  it('rejection requires at least 5 characters of reason, then calls reject_bank_adjustment', async () => {
    setup();
    renderPanel();
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Reject' }));
    const dialog = await screen.findByRole('dialog');
    const confirm = within(dialog).getByRole('button', { name: 'Reject' });
    expect(confirm).toBeDisabled();

    fireEvent.change(within(dialog).getByLabelText(/Why is it being rejected/), { target: { value: 'abc' } });
    expect(confirm).toBeDisabled();

    fireEvent.change(within(dialog).getByLabelText(/Why is it being rejected/), { target: { value: 'wrong counter-account' } });
    expect(confirm).toBeEnabled();
    await user.click(confirm);
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('reject_bank_adjustment', {
        p_adjustment_id: 'adj-other',
        p_reason: 'wrong counter-account',
      })
    );
  });

  it('reversing a posted adjustment requests a reversal instead of reversing in one click', async () => {
    setup();
    const { onChanged } = renderPanel();
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Reverse' }));
    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText('interest received', { exact: false })).toBeInTheDocument();

    fireEvent.change(within(dialog).getByLabelText(/Why is it being reversed/), {
      target: { value: 'wrong counter-account' },
    });
    await user.click(within(dialog).getByRole('button', { name: 'Request reversal' }));
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('request_bank_adjustment_reversal', {
        p_adjustment_id: 'adj-posted',
        p_reason: 'wrong counter-account',
      })
    );
    expect(mockRpc).not.toHaveBeenCalledWith('approve_bank_adjustment', expect.anything());
    expect(onChanged).toHaveBeenCalledWith(expect.stringContaining('Reversal requested'));
  });
});
