import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ImportStatementDialog } from './ImportStatementDialog';

const mockRpc = vi.fn();
vi.mock('../../../lib/supabaseClient', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

const CSV = 'statement_date,description,reference,amount\n2026-09-06,SALARY PYMT,REF001,-1674500';

function setup(bankAccount = 'Stanbic-001') {
  const onClose = vi.fn();
  const onImported = vi.fn();
  render(<ImportStatementDialog open bankAccount={bankAccount} onClose={onClose} onImported={onImported} />);
  return { onClose, onImported };
}

// userEvent.type treats `{` and `[` as key descriptors; pasting is closer to
// what a user does with a CSV anyway.
async function pasteCsv(user: ReturnType<typeof userEvent.setup>, text: string) {
  await user.click(screen.getByLabelText('CSV contents'));
  await user.paste(text);
}

describe('ImportStatementDialog', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    mockRpc.mockResolvedValue({ data: null, error: null });
  });

  it('refuses to import without a bank account', async () => {
    const user = userEvent.setup();
    setup('   ');
    await pasteCsv(user, CSV);
    await user.click(screen.getByRole('button', { name: 'Import' }));
    expect(await screen.findByText('Enter a bank account above before importing.')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('asks for a header row when the CSV has no data rows', async () => {
    const user = userEvent.setup();
    setup();
    await pasteCsv(user, 'statement_date,amount');
    await user.click(screen.getByRole('button', { name: 'Import' }));
    expect(await screen.findByText(/Paste CSV with a header row/)).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('blocks rows with a missing date or a non-numeric amount', async () => {
    const user = userEvent.setup();
    setup();
    await pasteCsv(user, 'statement_date,description,amount\n2026-09-06,X,abc');
    await user.click(screen.getByRole('button', { name: 'Import' }));
    expect(await screen.findByText('Every row needs a statement_date and a numeric amount.')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('sends the trimmed account and parsed lines, then reports the count', async () => {
    const user = userEvent.setup();
    const { onImported } = setup(' Stanbic-001 ');
    await pasteCsv(user, CSV);
    await user.click(screen.getByRole('button', { name: 'Import' }));

    await waitFor(() => expect(onImported).toHaveBeenCalledWith(1));
    expect(mockRpc).toHaveBeenCalledWith('import_bank_statement_lines', {
      p_bank_account: 'Stanbic-001',
      p_lines: [
        { statement_date: '2026-09-06', description: 'SALARY PYMT', reference: 'REF001', amount: -1674500, currency: undefined },
      ],
    });
  });

  it('shows the server error and does not report success', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'bank account not found' } });
    const user = userEvent.setup();
    const { onImported } = setup();
    await pasteCsv(user, CSV);
    await user.click(screen.getByRole('button', { name: 'Import' }));

    expect(await screen.findByText('bank account not found')).toBeInTheDocument();
    expect(onImported).not.toHaveBeenCalled();
  });

  it('closes on Cancel without calling the server', async () => {
    const user = userEvent.setup();
    const { onClose } = setup();
    await user.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onClose).toHaveBeenCalled();
    expect(mockRpc).not.toHaveBeenCalled();
  });
});
