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
