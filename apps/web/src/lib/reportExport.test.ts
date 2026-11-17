import { beforeEach, describe, expect, it, vi } from 'vitest';

// The export functions load xlsx / jspdf / jspdf-autotable with dynamic import()
// so report pages do not pay for them up front. These tests exercise the real
// functions against stand-ins for the libraries, which also proves the on-demand
// loading path works (the page tests mock this module out entirely).

const aoaToSheet = vi.fn((aoa: unknown) => ({ aoa }));
const bookAppendSheet = vi.fn();
const writeFile = vi.fn();
vi.mock('xlsx', () => ({
  utils: {
    aoa_to_sheet: (aoa: unknown) => aoaToSheet(aoa),
    book_new: () => ({ book: true }),
    book_append_sheet: (...args: unknown[]) => bookAppendSheet(...args),
  },
  writeFile: (...args: unknown[]) => writeFile(...args),
}));

const docs: FakeDoc[] = [];
class FakeDoc {
  options: unknown;
  texts: string[] = [];
  saved: string | null = null;
  pages = 0;
  lastAutoTable?: { finalY: number } = { finalY: 60 };
  internal = { pageSize: { getHeight: () => 200 } };
  constructor(options: unknown) {
    this.options = options;
    docs.push(this);
  }
  setFontSize() {}
  setTextColor() {}
  addPage() {
    this.pages += 1;
  }
  text(value: string) {
    this.texts.push(value);
  }
  save(name: string) {
    this.saved = name;
  }
}
vi.mock('jspdf', () => ({ default: FakeDoc }));

const autoTable = vi.fn();
vi.mock('jspdf-autotable', () => ({ default: (...args: unknown[]) => autoTable(...args) }));

import {
  eraseSection,
  exportMultiSectionToExcel,
  exportMultiSectionToPdf,
  exportReportToExcel,
  exportReportToPdf,
  type ReportExportColumn,
} from './reportExport';

interface Row {
  name: string;
  amount: string | number;
}
const columns: ReportExportColumn<Row>[] = [
  { header: 'Name', accessor: (r) => r.name },
  { header: 'Amount', accessor: (r) => r.amount, align: 'right' },
];

beforeEach(() => {
  aoaToSheet.mockClear();
  bookAppendSheet.mockClear();
  writeFile.mockClear();
  autoTable.mockClear();
  docs.length = 0;
});

describe('exportReportToExcel', () => {
  it('writes comma-grouped strings as real numbers and leaves text and dates alone', async () => {
    await exportReportToExcel('vat', 'VAT', columns, [
      { name: 'Acme', amount: '1,234.50' },
      { name: '2026-01-05', amount: 7 },
      { name: 'n/a', amount: '' },
    ]);

    expect(aoaToSheet).toHaveBeenCalledWith([
      ['Name', 'Amount'],
      ['Acme', 1234.5],
      ['2026-01-05', 7],
      ['n/a', ''],
    ]);
  });

  it('adds the .xlsx extension once and trims the sheet name to Excel\'s 31 characters', async () => {
    await exportReportToExcel('vat', 'x'.repeat(40), columns, []);
    expect(bookAppendSheet.mock.calls[0][2]).toBe('x'.repeat(31));
    expect(writeFile.mock.calls[0][1]).toBe('vat.xlsx');

    await exportReportToExcel('already.xlsx', 'S', columns, []);
    expect(writeFile.mock.calls[1][1]).toBe('already.xlsx');
  });

  it('returns a promise, so an unawaited call from an onClick is safe', () => {
    const result = exportReportToExcel('vat', 'VAT', columns, []);
    expect(result).toBeInstanceOf(Promise);
    return result;
  });
});

describe('exportReportToPdf', () => {
  it('draws a landscape table, shifts it down for a subtitle and right-aligns marked columns', async () => {
    await exportReportToPdf('vat', 'VAT Report', columns, [{ name: 'Acme', amount: 5 }], 'Sept 2026');

    const doc = docs[0];
    expect(doc.options).toEqual({ orientation: 'landscape' });
    expect(doc.texts).toEqual(['VAT Report', 'Sept 2026']);
    expect(doc.saved).toBe('vat.pdf');

    const opts = autoTable.mock.calls[0][1];
    expect(opts.startY).toBe(27);
    expect(opts.head).toEqual([['Name', 'Amount']]);
    expect(opts.body).toEqual([['Acme', '5']]);
    expect(opts.columnStyles).toEqual({ 1: { halign: 'right' } });
  });

  it('starts the table higher when there is no subtitle', async () => {
    await exportReportToPdf('vat.pdf', 'VAT Report', columns, []);
    expect(autoTable.mock.calls[0][1].startY).toBe(22);
    expect(docs[0].saved).toBe('vat.pdf');
  });
});

describe('multi-section exports', () => {
  const sections = [
    eraseSection({ title: 'Supplier', summaryLines: ['2 invoices'], columns, rows: [{ name: 'A', amount: 1 }] }),
    eraseSection<Row>({ title: 'Supplier', columns, rows: [] }),
  ];

  it('writes one sheet per section, de-duplicates names and puts summary lines above the header', async () => {
    await exportMultiSectionToExcel('dash', sections);

    expect(aoaToSheet.mock.calls[0][0]).toEqual([['2 invoices'], [], ['Name', 'Amount'], ['A', 1]]);
    expect(bookAppendSheet.mock.calls.map((c) => c[2])).toEqual(['Supplier', 'Supplier 2']);
    expect(writeFile.mock.calls[0][1]).toBe('dash.xlsx');
  });

  it('prints a placeholder instead of an empty table for a section with no rows', async () => {
    await exportMultiSectionToPdf('dash', 'Dashboard', sections);

    const doc = docs[0];
    expect(doc.texts).toContain('No data for this period.');
    expect(autoTable).toHaveBeenCalledTimes(1);
    expect(doc.saved).toBe('dash.pdf');
  });
});
