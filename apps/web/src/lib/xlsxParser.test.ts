import { describe, expect, it } from 'vitest';
import * as XLSX from 'xlsx';
import { parseXlsx } from './xlsxParser';

// Builds a real .xlsx file in memory from an array-of-arrays sheet, then
// wraps it in a File the same way a <input type="file"> upload would --
// so these tests exercise the actual XLSX binary round-trip, not a mock.
function makeXlsxFile(rows: unknown[][], sheetName = 'Sheet1'): File {
  const worksheet = XLSX.utils.aoa_to_sheet(rows);
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, worksheet, sheetName);
  const buffer = XLSX.write(workbook, { type: 'array', bookType: 'xlsx' });
  return new File([buffer], 'test.xlsx', {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  });
}

describe('parseXlsx', () => {
  it('parses headers and string rows from the first sheet', async () => {
    const file = makeXlsxFile([
      ['Name', 'Email'],
      ['John', 'john@example.com'],
      ['Jane', 'jane@example.com'],
    ]);
    const result = await parseXlsx(file);
    expect(result.headers).toEqual(['name', 'email']);
    expect(result.rows).toEqual([
      { name: 'John', email: 'john@example.com' },
      { name: 'Jane', email: 'jane@example.com' },
    ]);
  });

  it('lowercases and trims headers regardless of source capitalization/spacing', async () => {
    const file = makeXlsxFile([[' Full Name ', 'Email Address'], ['John', 'j@example.com']]);
    const result = await parseXlsx(file);
    expect(result.headers).toEqual(['full name', 'email address']);
  });

  it('formats a real Date cell as YYYY-MM-DD, not JS toString output', async () => {
    const file = makeXlsxFile([
      ['name', 'hire_date'],
      ['John', new Date(2024, 2, 12)], // March 12 2024 -- local, zero-indexed month
    ]);
    const result = await parseXlsx(file);
    expect(result.rows[0].hire_date).toBe('2024-03-12');
  });

  it('zero-pads single-digit month and day in date formatting', async () => {
    const file = makeXlsxFile([
      ['name', 'hire_date'],
      ['Jane', new Date(2024, 0, 5)], // Jan 5 2024
    ]);
    const result = await parseXlsx(file);
    expect(result.rows[0].hire_date).toBe('2024-01-05');
  });

  it('stringifies numeric cells', async () => {
    const file = makeXlsxFile([
      ['name', 'age'],
      ['John', 30],
    ]);
    const result = await parseXlsx(file);
    expect(result.rows[0].age).toBe('30');
  });

  it('converts undefined/empty cells to empty string for ragged rows', async () => {
    const file = makeXlsxFile([
      ['name', 'email', 'phone'],
      ['John', 'john@example.com'], // missing phone column
    ]);
    const result = await parseXlsx(file);
    expect(result.rows[0]).toEqual({ name: 'John', email: 'john@example.com', phone: '' });
  });

  it('returns empty result for a sheet with no rows', async () => {
    // A workbook with genuinely zero sheets can't be serialized by
    // XLSX.write in the first place (it throws "Workbook is empty"), so
    // the realistic "empty file" case parseXlsx needs to handle is a
    // present-but-empty sheet, not a missing one.
    const emptyFile = makeXlsxFile([]);
    const result = await parseXlsx(emptyFile);
    // the single-sheet view is empty, and the workbook map still names the
    // (empty) sheet it found
    expect(result).toEqual({ headers: [], rows: [], rowLineNumbers: [], sheets: { sheet1: [] } });
  });

  it('returns 2-indexed source row numbers (header row + 1-indexing)', async () => {
    const file = makeXlsxFile([
      ['name', 'email'],
      ['John', 'john@example.com'],
      ['Jane', 'jane@example.com'],
    ]);
    const result = await parseXlsx(file);
    // header occupies row 1, so first data row is row 2, second is row 3
    expect(result.rowLineNumbers).toEqual([2, 3]);
  });

  it('reads only the first sheet when multiple sheets exist', async () => {
    const worksheet1 = XLSX.utils.aoa_to_sheet([
      ['name'],
      ['FirstSheetRow'],
    ]);
    const worksheet2 = XLSX.utils.aoa_to_sheet([
      ['name'],
      ['SecondSheetRow'],
    ]);
    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, worksheet1, 'First');
    XLSX.utils.book_append_sheet(workbook, worksheet2, 'Second');
    const buffer = XLSX.write(workbook, { type: 'array', bookType: 'xlsx' });
    const file = new File([buffer], 'multi.xlsx');

    const result = await parseXlsx(file);
    expect(result.rows).toEqual([{ name: 'FirstSheetRow' }]);
  });
});

describe('parseXlsx multi-sheet workbooks', () => {
  // The in-force import template is one workbook with a sheet per file
  // (policies, receipts, remittances, shares, control_totals). Before `sheets`
  // existed the wizard only ever saw the first sheet, so the history and the
  // control totals could not be staged at all.
  function makeWorkbookFile(sheets: { name: string; rows: unknown[][] }[]): File {
    const workbook = XLSX.utils.book_new();
    for (const s of sheets) {
      XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet(s.rows), s.name);
    }
    const buffer = XLSX.write(workbook, { type: 'array', bookType: 'xlsx' });
    return new File([buffer], 'book.xlsx', {
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    });
  }

  it('returns every sheet keyed by lowercased name, and the first sheet as rows', async () => {
    const file = makeWorkbookFile([
      { name: 'Policies', rows: [['legacy_policy_no', 'gross_premium'], ['P1', '1000']] },
      { name: 'Receipts', rows: [['legacy_policy_no', 'receipt_date', 'amount'], ['P1', '2026-02-01', '400']] },
      { name: 'Control Totals', rows: [['currency', 'gross_premium'], ['UGX', '1000']] },
    ]);

    const result = await parseXlsx(file);

    expect(Object.keys(result.sheets).sort()).toEqual(['control totals', 'policies', 'receipts']);
    expect(result.sheets.receipts).toEqual([
      { legacy_policy_no: 'P1', receipt_date: '2026-02-01', amount: '400' },
    ]);
    // the first sheet is still what single-sheet importers read
    expect(result.rows).toEqual([{ legacy_policy_no: 'P1', gross_premium: '1000' }]);
    expect(result.headers).toEqual(['legacy_policy_no', 'gross_premium']);
  });

  it('keeps an empty sheet as an empty list rather than dropping it', async () => {
    const file = makeWorkbookFile([
      { name: 'policies', rows: [['legacy_policy_no'], ['P1']] },
      { name: 'remittances', rows: [] },
    ]);
    const result = await parseXlsx(file);
    expect(result.sheets.remittances).toEqual([]);
  });
});

describe('parseXlsx on the in-force import workbook', () => {
  // The workbook the import wizard is given has one sheet per source file.
  // This mirrors e2e/insurance-import.spec.ts exactly (json_to_sheet, sheets
  // named policies/receipts/remittances/control_totals) so a change in
  // either side - header casing, a number arriving as a number - shows up
  // here rather than as a staging error in a live run.
  it('returns every import sheet, keyed by lowercased name, with string cells', async () => {
    const sheets: Record<string, Record<string, string | number>[]> = {
      policies: [{
        legacy_policy_no: 'E2E-1', client_name: 'Kampala Transport Ltd', insurer: 'SAV',
        product_line: 'MOTOR', inception_date: '2026-01-01', expiry_date: '2026-12-31',
        currency: 'UGX', gross_premium: 1_000_000, commission_rate_pct: 10,
      }],
      receipts: [{ legacy_policy_no: 'E2E-1', receipt_date: '2026-02-01', amount: 400_000 }],
      remittances: [{ legacy_policy_no: 'E2E-1', remit_date: '2026-02-03', amount: 200_000 }],
      control_totals: [{ currency: 'UGX', gross_premium: 1_000_000, client_money: 200_000 }],
    };
    const workbook = XLSX.utils.book_new();
    for (const [name, rows] of Object.entries(sheets)) {
      XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(rows), name);
    }
    const file = new File([XLSX.write(workbook, { type: 'array', bookType: 'xlsx' })], 'book.xlsx');

    const result = await parseXlsx(file);

    expect(Object.keys(result.sheets)).toEqual(['policies', 'receipts', 'remittances', 'control_totals']);
    // Numbers arrive as strings, which is what the CSV path produces and what
    // the staging validators (platform_ins_import_num) expect.
    expect(result.sheets.policies[0]).toMatchObject({
      legacy_policy_no: 'E2E-1', gross_premium: '1000000', commission_rate_pct: '10',
    });
    expect(result.sheets.receipts[0]).toEqual({
      legacy_policy_no: 'E2E-1', receipt_date: '2026-02-01', amount: '400000',
    });
    // A sheet with columns the policies sheet lacks must not be re-indexed
    // through the first sheet's headers.
    expect(result.sheets.control_totals[0]).toEqual({
      currency: 'UGX', gross_premium: '1000000', client_money: '200000',
    });
    // The wizard still falls back to the first sheet for the CSV/single-sheet path.
    expect(result.rows[0].legacy_policy_no).toBe('E2E-1');
  });
});
