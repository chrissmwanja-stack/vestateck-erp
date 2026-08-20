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
    expect(result).toEqual({ headers: [], rows: [], rowLineNumbers: [] });
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
