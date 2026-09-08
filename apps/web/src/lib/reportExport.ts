import * as XLSX from "xlsx";
import jsPDF from "jspdf";
import autoTable from "jspdf-autotable";

/**
 * Generic column definition for exporting a report's on-screen table to
 * Excel or PDF. `accessor` should return the same formatted value shown in
 * the UI (e.g. already comma-grouped numbers as strings, or raw numbers --
 * both are handled below).
 */
export interface ReportExportColumn<T> {
  header: string;
  accessor: (row: T) => string | number;
  align?: "left" | "right";
}

function toCellValue<T>(row: T, col: ReportExportColumn<T>): string | number {
  const value = col.accessor(row);
  return value ?? "";
}

/**
 * One block of a multi-section report (e.g. a dashboard's "Supplier
 * Invoices" card): an optional list of summary lines (rendered as plain
 * text above the table -- e.g. "42 invoices | 1,234,567 total incl. VAT"),
 * plus the underlying breakdown table for that section.
 */
export interface ReportSection<T> {
  title: string;
  summaryLines?: string[];
  columns: ReportExportColumn<T>[];
  rows: T[];
}

/**
 * Exports rows to a single-sheet .xlsx file using the same column
 * definitions the on-screen table uses. Numbers are written as real
 * numbers (not strings) so totals/sums work if the user pivots the sheet.
 */
export function exportReportToExcel<T>(
  filename: string,
  sheetName: string,
  columns: ReportExportColumn<T>[],
  rows: T[]
): void {
  const aoa: (string | number)[][] = [
    columns.map((c) => c.header),
    ...rows.map((row) =>
      columns.map((col) => {
        const value = toCellValue(row, col);
        if (typeof value === "string") {
          // Undo display-time comma grouping (e.g. "1,234.50") so Excel
          // stores it as a number, not a text string.
          const numeric = Number(value.replace(/,/g, ""));
          return value !== "" && !Number.isNaN(numeric) && /^[\d,.\-]+$/.test(value)
            ? numeric
            : value;
        }
        return value;
      })
    ),
  ];

  const worksheet = XLSX.utils.aoa_to_sheet(aoa);
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, worksheet, sheetName.slice(0, 31));
  XLSX.writeFile(workbook, filename.endsWith(".xlsx") ? filename : `${filename}.xlsx`);
}

/**
 * Exports rows to a landscape PDF with a title, optional subtitle (e.g. the
 * active date-range/organization filter), and an auto-paginated table.
 */
export function exportReportToPdf<T>(
  filename: string,
  title: string,
  columns: ReportExportColumn<T>[],
  rows: T[],
  subtitle?: string
): void {
  const doc = new jsPDF({ orientation: "landscape" });

  doc.setFontSize(14);
  doc.text(title, 14, 15);

  if (subtitle) {
    doc.setFontSize(10);
    doc.setTextColor(100);
    doc.text(subtitle, 14, 22);
  }

  autoTable(doc, {
    startY: subtitle ? 27 : 22,
    head: [columns.map((c) => c.header)],
    body: rows.map((row) => columns.map((col) => String(toCellValue(row, col)))),
    styles: { fontSize: 8 },
    headStyles: { fillColor: [18, 59, 68] }, // Harbor Slate
    columnStyles: columns.reduce<Record<number, { halign: "left" | "right" }>>(
      (acc, col, i) => {
        if (col.align === "right") acc[i] = { halign: "right" };
        return acc;
      },
      {}
    ),
  });

  doc.save(filename.endsWith(".pdf") ? filename : `${filename}.pdf`);
}

/**
 * Exports a dashboard made of several distinct summary blocks (each with
 * its own summary lines + breakdown table, e.g. Supplier / Receivable /
 * Cash & Bank / Expenditure / Petty Cash) to one workbook, one sheet per
 * section. Summary lines are written as plain rows above the header row.
 */
export function exportMultiSectionToExcel(
  filename: string,
  sections: ReportSection<any>[]
): void {
  const workbook = XLSX.utils.book_new();
  const usedNames = new Set<string>();

  sections.forEach((section) => {
    const aoa: (string | number)[][] = [];

    (section.summaryLines ?? []).forEach((line) => aoa.push([line]));
    if (section.summaryLines?.length) aoa.push([]);

    aoa.push(section.columns.map((c) => c.header));
    section.rows.forEach((row) =>
      aoa.push(
        section.columns.map((col) => {
          const value = toCellValue(row, col);
          if (typeof value === "string") {
            const numeric = Number(value.replace(/,/g, ""));
            return value !== "" && !Number.isNaN(numeric) && /^[\d,.\-]+$/.test(value)
              ? numeric
              : value;
          }
          return value;
        })
      )
    );

    const worksheet = XLSX.utils.aoa_to_sheet(aoa);
    let sheetName = section.title.slice(0, 31);
    let suffix = 2;
    while (usedNames.has(sheetName)) {
      sheetName = `${section.title.slice(0, 28)} ${suffix}`;
      suffix += 1;
    }
    usedNames.add(sheetName);

    XLSX.utils.book_append_sheet(workbook, worksheet, sheetName);
  });

  XLSX.writeFile(workbook, filename.endsWith(".xlsx") ? filename : `${filename}.xlsx`);
}

/**
 * Exports the same multi-section dashboard to a single PDF: one heading +
 * summary lines + table per section, flowing down the page and paginating
 * automatically via jspdf-autotable.
 */
export function exportMultiSectionToPdf(
  filename: string,
  title: string,
  sections: ReportSection<any>[],
  subtitle?: string
): void {
  const doc = new jsPDF({ orientation: "landscape" });
  const pageHeight = doc.internal.pageSize.getHeight();
  const marginLeft = 14;

  doc.setFontSize(16);
  doc.text(title, marginLeft, 15);

  let cursorY = 22;
  if (subtitle) {
    doc.setFontSize(10);
    doc.setTextColor(100);
    doc.text(subtitle, marginLeft, cursorY);
    cursorY += 6;
  }

  sections.forEach((section) => {
    // Start a new page if there's not enough room left for a section header.
    if (cursorY > pageHeight - 30) {
      doc.addPage();
      cursorY = 15;
    }

    doc.setFontSize(12);
    doc.setTextColor(18, 59, 68); // Harbor Slate
    doc.text(section.title, marginLeft, cursorY);
    cursorY += 5;

    if (section.summaryLines?.length) {
      doc.setFontSize(9);
      doc.setTextColor(80);
      section.summaryLines.forEach((line) => {
        doc.text(line, marginLeft, cursorY);
        cursorY += 4.5;
      });
      cursorY += 1;
    }

    if (section.rows.length === 0) {
      doc.setFontSize(9);
      doc.setTextColor(140);
      doc.text("No data for this period.", marginLeft, cursorY);
      cursorY += 8;
      return;
    }

    autoTable(doc, {
      startY: cursorY,
      margin: { left: marginLeft },
      head: [section.columns.map((c) => c.header)],
      body: section.rows.map((row) => section.columns.map((col) => String(toCellValue(row, col)))),
      styles: { fontSize: 8 },
      headStyles: { fillColor: [18, 59, 68] },
      columnStyles: section.columns.reduce<Record<number, { halign: "left" | "right" }>>(
        (acc, col, i) => {
          if (col.align === "right") acc[i] = { halign: "right" };
          return acc;
        },
        {}
      ),
    });

    cursorY = (doc as any).lastAutoTable.finalY + 10;
  });

  doc.save(filename.endsWith(".pdf") ? filename : `${filename}.pdf`);
}