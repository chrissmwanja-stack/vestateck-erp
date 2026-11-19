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
  id: 'adj-own', kind: 'adjustment', status: 'pending', bank_statement_line_id: 'line-1',
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
const ADJ_REJECTED = {
  ...ADJ_OWN, id: 'adj-rejected', status: 'rejected', created_by: 'user-a',
  bank_statement_line_id: 'line-1', rejection_reason: 'wrong counter-account',
  reason: 'bank charge, first attempt',
  line: { statement_date: '2026-11-10', description: 'BANK CHARGE', reference: 'CHG1' },
};
const ADJ_HEADER_GL = {
  id: 'gl-9', account_code: '9000', name: 'Suspense Header', is_header: true,
};
const ADJ_CONTROL_GL = {
  id: 'gl-8', account_code: '1100', name: 'Trade Receivables', is_control_account: true,
};
const ADJ_OWN_REVERSAL = {
  ...ADJ_OWN, id: 'adj-own-rev', kind: 'reversal', reason: 'posted in error',
  reverses_adjustment_id: 'adj-posted', counter: { account_code: '4100', name: 'Interest Received' },
  line: { statement_date: '2026-11-08', description: 'INTEREST', reference: 'INT1' },
};
const ADJ_ELSEWHERE = {
  ...ADJ_OWN, id: 'adj-elsewhere', bank_account: 'OtherBank-9', reason: 'account at another bank',
};
const GL_OPTIONS = [
  { id: 'gl-1', account_code: '5000', name: 'Bank Charges' },
  { id: 'gl-2', account_code: '4100', name: 'Interest Received' },
  ADJ_HEADER_GL,
  ADJ_CONTROL_GL,
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

function setup(rows: unknown[] = [ADJ_OWN, ADJ_OTHER, ADJ_POSTED], canSelfApprove = false) {
  tableData = { bank_adjustments: rows, gl_accounts: GL_OPTIONS };
  mockFrom.mockImplementation((table: string) => builderFor(table));
  mockRpc.mockImplementation((name: string) => {
    if (name === 'bank_adjustment_can_self_approve') {
      return Promise.resolve({ data: canSelfApprove, error: null });
    }
    if (name === 'bank_adjustment_history') {
      return Promise.resolve({ data: HISTORY, error: null });
    }
    return Promise.resolve({ data: { id: 'new-adj' }, error: null });
  });
}

const HISTORY = [
  { event: 'created', actor_id: 'user-a', actor_name: 'Finance Maker', note: null, created_at: '2026-11-10T09:00:00Z' },
  { event: 'rejected', actor_id: 'user-b', actor_name: 'Finance Checker', note: 'wrong counter-account', created_at: '2026-11-10T10:00:00Z' },
];

function renderPanel(overrides: Partial<Parameters<typeof BankAdjustmentsPanel>[0]> = {}) {
  const onChanged = vi.fn();
  const onError = vi.fn();
  const onSelectLine = vi.fn();
  render(
    <BankAdjustmentsPanel
      bankAccountName="Stanbic-001"
      selectedLine={LINE}
      onChanged={onChanged}
      onError={onError}
      onSelectLine={onSelectLine}
      {...overrides}
    />
  );
  return { onChanged, onError, onSelectLine };
}

describe('BankAdjustmentsPanel', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    mockFrom.mockReset();
  });

  it('disables Approve on your own proposal when the one-person exception is not in force', async () => {
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
  it('enables self-approval on your own proposal when the company has the exception, and says what it means', async () => {
    setup([ADJ_OWN], true);
    const { onChanged } = renderPanel();
    const user = userEvent.setup();

    expect(await screen.findByTestId('self-approve-banner')).toBeInTheDocument();
    expect(screen.getByTestId('self-approve-chip')).toBeInTheDocument();

    const approve = screen.getByRole('button', { name: 'Approve' });
    expect(approve).toBeEnabled();
    await user.click(approve);

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/self-approved under your company/i)).toBeInTheDocument();
    await user.click(within(dialog).getByRole('button', { name: 'Approve and post' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('approve_bank_adjustment', { p_adjustment_id: 'adj-own' })
    );
    expect(onChanged).toHaveBeenCalledWith(expect.stringContaining('one-person exception'));
  });

  it('explains that a header or control account cannot be the other side, and refuses to submit it', async () => {
    setup([]);
    renderPanel();
    const user = userEvent.setup();

    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'bank charge per statement' } });
    const combo = screen.getByLabelText('Other side of the entry');
    fireEvent.mouseDown(combo);

    const header = await screen.findByRole('option', { name: /9000 Suspense Header/ });
    expect(header).toHaveAttribute('aria-disabled', 'true');
    expect(within(header).getByText(/header account cannot be posted to/)).toBeInTheDocument();

    const control = await screen.findByRole('option', { name: /1100 Trade Receivables/ });
    expect(control).toHaveAttribute('aria-disabled', 'true');
    expect(within(control).getByText(/control account/)).toBeInTheDocument();

    await user.keyboard('{Escape}');
    expect(screen.getByRole('button', { name: 'Propose adjustment' })).toBeDisabled();
    expect(mockRpc).not.toHaveBeenCalledWith('create_bank_adjustment', expect.anything());
  });

  it('reworking a rejected proposal re-selects its line and links the new one with p_reworked_from', async () => {
    setup([ADJ_REJECTED]);
    const { onSelectLine, onChanged } = renderPanel();
    const user = userEvent.setup();

    await user.click(await screen.findByTestId('rework-adj-rejected'));
    expect(onSelectLine).toHaveBeenCalledWith('line-1');
    expect(await screen.findByTestId('rework-banner')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Propose rework' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('create_bank_adjustment', {
        p_statement_line_id: 'line-1',
        p_counter_account_id: 'gl-1',
        p_reason: 'bank charge, first attempt',
        p_reworked_from: 'adj-rejected',
      })
    );
    expect(onChanged).toHaveBeenCalledWith(expect.stringContaining('linked to the rejected adjustment'));
  });

  it('shows the audit history of an adjustment, with who did what', async () => {
    setup([ADJ_REJECTED]);
    renderPanel();
    const user = userEvent.setup();

    await user.click(await screen.findByTestId('history-adj-rejected'));
    const dialog = await screen.findByRole('dialog');

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('bank_adjustment_history', { p_adjustment_id: 'adj-rejected' })
    );
    expect(await within(dialog).findByText('Proposed')).toBeInTheDocument();
    expect(within(dialog).getByText('Rejected')).toBeInTheDocument();
    expect(within(dialog).getByText('Finance Maker')).toBeInTheDocument();
    expect(within(dialog).getByText('wrong counter-account')).toBeInTheDocument();
  });

  it('tells the reader how many of their proposals are waiting, and that they cannot approve them', async () => {
    setup([ADJ_OWN], false);
    renderPanel();
    const hint = await screen.findByTestId('pending-own-hint');
    expect(within(hint).getByText(/waiting/i)).toBeInTheDocument();
    expect(within(hint).getByText(/cannot approve/)).toBeInTheDocument();
  });
  it('drills through from a row to its statement line in the table above', async () => {
    setup([ADJ_POSTED]);
    const { onSelectLine } = renderPanel();
    const user = userEvent.setup();
    await user.click(await screen.findByTestId('line-adj-posted'));
    expect(onSelectLine).toHaveBeenCalledWith('line-1');
  });
  it('lets a one-person team approve its own reversal request, since nobody else can', async () => {
    setup([ADJ_OWN_REVERSAL], true);
    const { onChanged: onChangedForSelfApproval } = renderPanel();
    const user = userEvent.setup();

    const row = await screen.findByRole('row', { name: /posted in error/ });
    const approve = within(row).getByRole('button', { name: 'Approve' });
    expect(approve).toBeEnabled();
    await user.click(approve);

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/your own reversal request/i)).toBeInTheDocument();
    await user.click(within(dialog).getByRole('button', { name: 'Approve and post' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('approve_bank_adjustment', { p_adjustment_id: 'adj-own-rev' })
    );
    expect(onChangedForSelfApproval).toHaveBeenCalled();
  });

  it('still refuses to let you approve your own reversal request without the exception', async () => {
    setup([ADJ_OWN_REVERSAL], false);
    renderPanel();
    const row = await screen.findByRole('row', { name: /posted in error/ });
    expect(within(row).getByRole('button', { name: 'Approve' })).toBeDisabled();
  });
});
