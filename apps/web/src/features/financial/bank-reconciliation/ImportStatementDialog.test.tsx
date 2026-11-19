import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ImportStatementDialog } from './ImportStatementDialog';

const mockRpc = vi.fn();
vi.mock('../../../lib/supabaseClient', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

const CSV = 'statement_date,description,reference,amount\n2026-09-06,SALARY PYMT,REF001,-1674500';
const CSV_TWO =
  'statement_date,description,reference,amount\n2026-09-06,SALARY PYMT,REF001,-1674500\n2026-09-07,NEW RECEIPT,RCP9,250000';

const LINE = { statement_date: '2026-09-06', description: 'SALARY PYMT', reference: 'REF001', amount: -1674500, currency: undefined };

type RpcReply = { data: unknown; error: { message: string } | null };

// Replies keyed by RPC name; a test overrides only what it cares about.
function reply(overrides: Record<string, RpcReply> = {}) {
  const defaults: Record<string, RpcReply> = {
    preview_bank_statement_import: { data: [{ line_no: 1, already_imported: false }], error: null },
    import_bank_statement_batch: { data: { import_batch_id: 'b1', imported: 1, skipped: 0 }, error: null },
  };
  const table = { ...defaults, ...overrides };
  mockRpc.mockImplementation((name: string) => Promise.resolve(table[name] ?? { data: null, error: null }));
}

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
    reply();
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

  it('checks for duplicates, then imports the trimmed account and parsed lines when none are found', async () => {
    const user = userEvent.setup();
    const { onImported } = setup(' Stanbic-001 ');
    await pasteCsv(user, CSV);
    await user.click(screen.getByRole('button', { name: 'Import' }));

    await waitFor(() => expect(onImported).toHaveBeenCalledWith(1, 0));
    expect(mockRpc).toHaveBeenNthCalledWith(1, 'preview_bank_statement_import', {
      p_bank_account: 'Stanbic-001',
      p_lines: [LINE],
    });
    expect(mockRpc).toHaveBeenNthCalledWith(2, 'import_bank_statement_batch', {
      p_bank_account: 'Stanbic-001',
      p_lines: [LINE],
      p_skip_duplicates: false,
    });
  });

  it('warns when some lines are already on file and imports only the rest when asked to skip', async () => {
    reply({
      preview_bank_statement_import: {
        data: [
          { line_no: 1, already_imported: true },
          { line_no: 2, already_imported: false },
        ],
        error: null,
      },
      import_bank_statement_batch: { data: { import_batch_id: 'b2', imported: 1, skipped: 1 }, error: null },
    });
    const user = userEvent.setup();
    const { onImported } = setup();
    await pasteCsv(user, CSV_TWO);
    await user.click(screen.getByRole('button', { name: 'Import' }));

    expect(await screen.findByText(/1 of 2 lines are already on file/)).toBeInTheDocument();
    // Nothing is written until the user chooses.
    expect(mockRpc).toHaveBeenCalledTimes(1);
    expect(onImported).not.toHaveBeenCalled();

    await user.click(screen.getByRole('button', { name: 'Skip duplicates and import the rest' }));
    await waitFor(() => expect(onImported).toHaveBeenCalledWith(1, 1));
    expect(mockRpc).toHaveBeenLastCalledWith(
      'import_bank_statement_batch',
      expect.objectContaining({ p_skip_duplicates: true }),
    );
  });

  it('can import everything anyway after the warning', async () => {
    reply({
      preview_bank_statement_import: {
        data: [
          { line_no: 1, already_imported: true },
          { line_no: 2, already_imported: false },
        ],
        error: null,
      },
      import_bank_statement_batch: { data: { import_batch_id: 'b3', imported: 2, skipped: 0 }, error: null },
    });
    const user = userEvent.setup();
    const { onImported } = setup();
    await pasteCsv(user, CSV_TWO);
    await user.click(screen.getByRole('button', { name: 'Import' }));
    await user.click(await screen.findByRole('button', { name: 'Import all anyway' }));

    await waitFor(() => expect(onImported).toHaveBeenCalledWith(2, 0));
    expect(mockRpc).toHaveBeenLastCalledWith(
      'import_bank_statement_batch',
      expect.objectContaining({ p_skip_duplicates: false }),
    );
  });

  it('offers no skip button when every line is already on file', async () => {
    reply({ preview_bank_statement_import: { data: [{ line_no: 1, already_imported: true }], error: null } });
    const user = userEvent.setup();
    setup();
    await pasteCsv(user, CSV);
    await user.click(screen.getByRole('button', { name: 'Import' }));

    expect(await screen.findByText(/already on file for this account\. This looks like a statement/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Skip duplicates and import the rest' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Import all anyway' })).toBeInTheDocument();
  });

  it('Back to file returns to the editor without importing', async () => {
    reply({ preview_bank_statement_import: { data: [{ line_no: 1, already_imported: true }], error: null } });
    const user = userEvent.setup();
    const { onImported } = setup();
    await pasteCsv(user, CSV);
    await user.click(screen.getByRole('button', { name: 'Import' }));
    await user.click(await screen.findByRole('button', { name: 'Back to file' }));

    expect(screen.getByRole('button', { name: 'Import' })).toBeInTheDocument();
    expect(onImported).not.toHaveBeenCalled();
    expect(mockRpc).toHaveBeenCalledTimes(1);
    // The pasted CSV is still there to fix.
    expect(screen.getByLabelText('CSV contents')).toHaveValue(CSV);
  });

  it('shows a preview error and writes nothing', async () => {
    reply({ preview_bank_statement_import: { data: null, error: { message: 'not authorized to import bank statement lines' } } });
    const user = userEvent.setup();
    const { onImported } = setup();
    await pasteCsv(user, CSV);
    await user.click(screen.getByRole('button', { name: 'Import' }));

    expect(await screen.findByText('not authorized to import bank statement lines')).toBeInTheDocument();
    expect(onImported).not.toHaveBeenCalled();
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });

  it('shows the server error from the import and does not report success', async () => {
    reply({ import_bank_statement_batch: { data: null, error: { message: 'bank account not found' } } });
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
