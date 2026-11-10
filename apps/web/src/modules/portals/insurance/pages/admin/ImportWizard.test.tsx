import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ImportWizard from './ImportWizard';

// ins_import_validate_batch records row errors and returns normally with an
// error_count, so the wizard must read that report: a batch with failing rows
// stays on the validation step and lists the rows, it never reports success.

const mockRpc = vi.fn();
const mockRows = vi.fn();
vi.mock('../../db', () => ({
  rpc: (...a: unknown[]) => mockRpc(...a),
  rows: (...a: unknown[]) => mockRows(...a),
  table: () => {
    const c: Record<string, unknown> = {};
    for (const m of ['select', 'eq', 'order', 'limit']) c[m] = () => c;
    return c;
  },
  errorText: (e: unknown) => (e instanceof Error ? e.message : 'Something went wrong'),
}));
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage: true }) }));
vi.mock('../../../../../lib/csvParser', () => ({ parseCsv: () => ({ rows: [{ legacy_policy_no: 'P1' }] }) }));
vi.mock('../../../../../lib/xlsxParser', () => ({ parseXlsx: vi.fn() }));

let validateReport: { error_count: number };

async function stageAndOpenValidation() {
  const user = userEvent.setup();
  render(<MemoryRouter><ImportWizard /></MemoryRouter>);
  await user.type(screen.getByLabelText('Batch label'), 'Legacy book');
  await user.type(screen.getByLabelText('Cut-over date'), '2026-10-31');
  const file = new File(['legacy_policy_no\nP1'], 'book.csv', { type: 'text/csv' });
  // jsdom's File has no text(); the parser is mocked, so any string will do
  Object.defineProperty(file, 'text', { value: async () => 'legacy_policy_no\nP1' });
  await user.upload(document.querySelector('input[type="file"]') as HTMLInputElement, file);
  await user.click(screen.getByRole('button', { name: 'Stage rows' }));
  await user.click(await screen.findByRole('button', { name: 'Run validation' }));
  return user;
}

beforeEach(() => {
  mockRpc.mockReset();
  mockRows.mockReset();
  validateReport = { error_count: 0 };
  mockRpc.mockImplementation(async (fn: string) => {
    if (fn === 'ins_import_create_batch') return { id: 'b1234567-0000', label: 'Legacy book', status: 'staged', cut_over_date: '2026-10-31', error_count: 0 };
    if (fn === 'ins_import_validate_batch') return validateReport;
    return null;
  });
});

describe('ImportWizard validation', () => {
  it('advances to commit when the report has no errors', async () => {
    await stageAndOpenValidation();
    expect(await screen.findByText('Validation passed.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Commit policies' })).toBeTruthy();
  });

  it('stays on validation and lists the failing rows when the report has errors', async () => {
    validateReport = { error_count: 2 };
    mockRows.mockResolvedValue([
      { sheet: 'policies', line: 3, errors: [{ code: 'CLIENT_NOT_FOUND', message: 'no client matches Acme' }] },
    ]);
    await stageAndOpenValidation();
    expect(await screen.findByText(/2 row\(s\) failed validation/)).toBeTruthy();
    expect(screen.getByText('no client matches Acme')).toBeTruthy();
    expect(screen.getByText(/Showing the first 1 of 2 failing rows/)).toBeTruthy();
    expect(screen.queryByText('Validation passed.')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Commit policies' })).toBeNull();
    await waitFor(() => expect(screen.getByRole('button', { name: 'Run validation' })).toBeTruthy());
  });
});

describe('ImportWizard reconciliation', () => {
  // The reconciliation returns null for a measure the batch's control_totals
  // sheet never recorded. Rendering that as a difference would report a
  // mismatch on a perfect batch, which is exactly what the SQL report used to
  // do; "not recorded" has to stay visibly distinct from "DIFF".
  it('separates match, difference and not-recorded', async () => {
    mockRpc.mockImplementation(async (fn: string) => {
      if (fn === 'ins_import_create_batch') return { id: 'b1234567-0000', label: 'Legacy book', status: 'staged', cut_over_date: '2026-10-31', error_count: 0 };
      if (fn === 'ins_import_validate_batch') return { error_count: 0 };
      if (fn === 'ins_import_post_opening_position') return { already_posted: false, journal_entry_id: 'je-000000' };
      if (fn === 'ins_import_reconciliation') return [
        { currency: 'UGX', measure: 'gross_premium', imported_amount: 1000, control_amount: 1000, match: true },
        { currency: 'UGX', measure: 'commission', imported_amount: 100, control_amount: 125, match: false },
        { currency: 'UGX', measure: 'remittances_to_date', imported_amount: 0, control_amount: null, match: null },
      ];
      return null;
    });

    const user = await stageAndOpenValidation();
    await user.click(await screen.findByRole('button', { name: 'Commit policies' }));
    await user.click(await screen.findByRole('button', { name: 'Post opening position' }));
    await user.click(await screen.findByRole('button', { name: 'Run reconciliation' }));

    expect(await screen.findByText('match')).toBeTruthy();
    expect(screen.getByText('DIFF')).toBeTruthy();
    expect(screen.getByText('not recorded')).toBeTruthy();
    // a not-recorded measure shows no control figure at all
    expect(screen.getByText('—')).toBeTruthy();
  });
});

describe('ImportWizard multi-sheet staging', () => {
  // The canonical import is one workbook with a sheet per file. Until
  // parseXlsx returned every sheet, the wizard could only ever stage the
  // policies sheet, so the receipts, remittances, shares and control totals
  // the opening position is computed from were unreachable from the UI.
  it('stages every sheet of a workbook, not just the first', async () => {
    const { parseXlsx } = await import('../../../../../lib/xlsxParser');
    vi.mocked(parseXlsx).mockResolvedValue({
      headers: ['legacy_policy_no'],
      rows: [{ legacy_policy_no: 'P1' }],
      rowLineNumbers: [2],
      sheets: {
        policies: [{ legacy_policy_no: 'P1', gross_premium: '1000', commission_rate_pct: '10' }],
        receipts: [{ legacy_policy_no: 'P1', receipt_date: '2026-02-01', amount: '400' }],
        control_totals: [{ currency: 'UGX', gross_premium: '1000' }],
      },
    });

    const user = userEvent.setup();
    render(<MemoryRouter><ImportWizard /></MemoryRouter>);
    await user.type(screen.getByLabelText('Batch label'), 'Legacy book');
    await user.type(screen.getByLabelText('Cut-over date'), '2026-10-31');
    const file = new File(['binary'], 'book.xlsx', { type: 'application/vnd.ms-excel' });
    await user.upload(document.querySelector('input[type="file"]') as HTMLInputElement, file);
    await user.click(screen.getByRole('button', { name: 'Stage rows' }));

    const staged = mockRpc.mock.calls
      .filter((c) => c[0] === 'ins_import_stage_rows')
      .map((c) => (c[1] as { p_sheet: string }).p_sheet);
    expect(staged).toEqual(['policies', 'receipts', 'control_totals']);
  });
});

describe('ImportWizard resuming a batch', () => {
  // The approver is never the uploader, so the wizard has to be openable on
  // another person's screen with nothing but the URL: the batch id travels in
  // ?batch= and the status decides which step to show.
  it('opens the batch named in the URL on the step its status implies', async () => {
    mockRows.mockResolvedValue([
      { id: 'b1234567-0000', label: 'Legacy book', status: 'validated', cut_over_date: '2026-10-31', error_count: 0 },
    ]);
    render(
      <MemoryRouter initialEntries={['/insurance/admin/import?batch=b1234567-0000']}>
        <ImportWizard />
      </MemoryRouter>,
    );
    expect(await screen.findByText(/Opened batch b1234567 \(validated\)/)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Compare with control totals' })).toBeTruthy();
  });
});

describe('ImportWizard control totals before commit', () => {
  // The commit gate lives on the server (a trigger on the batch), so the
  // manager hits it at the commit step - before the reconcile step exists.
  // That is why the comparison and the approval live there.
  it('shows the difference, requires a reason, and approves it', async () => {
    mockRpc.mockImplementation(async (fn: string) => {
      if (fn === 'ins_import_create_batch') return { id: 'b1234567-0000', label: 'Legacy book', status: 'staged', cut_over_date: '2026-10-31', error_count: 0 };
      if (fn === 'ins_import_validate_batch') return { error_count: 0 };
      if (fn === 'ins_import_reconciliation') return [
        { currency: 'UGX', measure: 'gross_premium', imported_amount: 1000, control_amount: 1250, match: false },
        { currency: 'UGX', measure: 'client_money', imported_amount: 400, control_amount: 400, match: true },
      ];
      if (fn === 'ins_import_override_control_totals') {
        return { approved_differences: [{ currency: 'UGX', measure: 'gross_premium' }] };
      }
      return null;
    });

    const user = await stageAndOpenValidation();
    await user.click(await screen.findByRole('button', { name: 'Compare with control totals' }));

    expect(await screen.findByText('DIFF')).toBeTruthy();
    expect(screen.getByText(/disagree with the staged book on\s*1 measure/)).toBeTruthy();

    const approve = screen.getByRole('button', { name: 'Approve difference' }) as HTMLButtonElement;
    expect(approve.disabled).toBe(true);

    const reason = screen.getByLabelText('Why do the totals differ?');
    await user.type(reason, 'too short');
    expect(approve.disabled).toBe(true);

    await user.type(reason, ' — two merged policies in the legacy ledger');
    expect(approve.disabled).toBe(false);
    await user.click(approve);

    expect(await screen.findByText(/Approved 1 difference/)).toBeTruthy();
    const call = mockRpc.mock.calls.find((c) => c[0] === 'ins_import_override_control_totals');
    expect((call?.[1] as { p_reason: string }).p_reason).toContain('two merged policies');
    expect(call?.[1]).toMatchObject({ p_batch_id: 'b1234567-0000' });
  });
});
