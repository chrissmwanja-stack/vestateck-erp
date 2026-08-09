import * as XLSX from "xlsx";
import type { ParsedCsv } from "./csvParser";

/**
 * Parses the first sheet of an Excel workbook (.xlsx/.xls) into the same
 * { headers, rows, rowLineNumbers } shape parseCsv() produces, so
 * BulkImportDialog can validate/import rows from either format with no
 * format-specific branching beyond picking which parser to call.
 */
export async function parseXlsx(file: File): Promise<ParsedCsv> {
  const buffer = await file.arrayBuffer();
  const workbook = XLSX.read(buffer, { type: "array" });

  const firstSheetName = workbook.SheetNames[0];
  if (!firstSheetName) {
    return { headers: [], rows: [], rowLineNumbers: [] };
  }
  const sheet = workbook.Sheets[firstSheetName];

  // header: 1 -> array-of-arrays instead of array-of-objects, so headers are
  // read exactly like the CSV parser reads them (lowercased/trimmed below),
  // regardless of how the spreadsheet author capitalized or spaced them.
  // defval: "" -> keeps ragged rows (a row shorter than the header row)
  // aligned instead of throwing off column indexes.
  const raw: unknown[][] = XLSX.utils.sheet_to_json(sheet, {
    header: 1,
    defval: "",
    blankrows: false,
  });

  if (raw.length === 0) {
    return { headers: [], rows: [], rowLineNumbers: [] };
  }

  const headers = raw[0].map((h) => String(h ?? "").trim().toLowerCase());
  const dataRows = raw.slice(1);

  const rows: Record<string, string>[] = [];
  const rowLineNumbers: number[] = [];
  dataRows.forEach((r, idx) => {
    const obj: Record<string, string> = {};
    headers.forEach((h, colIdx) => {
      const cell = r[colIdx];
      // Excel gives back numbers/dates as JS values, not strings -- normalize
      // to string here so every downstream validator/lookup that expects
      // row[col] to be a string (same as the CSV path) works unmodified.
      obj[h] = cell === undefined || cell === null ? "" : String(cell).trim();
    });
    rows.push(obj);
    rowLineNumbers.push(idx + 2); // +1 for header row, +1 for 1-indexing
  });

  return { headers, rows, rowLineNumbers };
}
