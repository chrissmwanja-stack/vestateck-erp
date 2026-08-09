// Shared CSV parser used by every bulk-import screen (Employees, Accounts,
// Equipment, BD Leads, and any future ones). Handles the two things the
// old ImportLeads.tsx naive `line.split(",")` implementation could not:
//   - quoted fields containing commas, e.g. "Doe, John"
//   - escaped quotes inside quoted fields ("" -> ")
//   - CRLF and mixed line endings
//
// Row objects are keyed by lowercased/trimmed header names so callers can
// do `row.email`, `row.first_name`, etc. regardless of how the source
// spreadsheet capitalized its headers.

export interface ParsedCsv {
  headers: string[];
  rows: Record<string, string>[];
  /** 1-indexed line number in the source file for each row, for error messages */
  rowLineNumbers: number[];
}

/**
 * Parses raw CSV text into records, respecting RFC4180 quoting rules.
 */
export function parseCsv(text: string): ParsedCsv {
  // Normalize line endings, strip BOM if present
  const clean = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");

  const records: string[][] = [];
  let field = "";
  let record: string[] = [];
  let inQuotes = false;
  let i = 0;

  while (i < clean.length) {
    const char = clean[i];

    if (inQuotes) {
      if (char === '"') {
        if (clean[i + 1] === '"') {
          field += '"';
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      field += char;
      i++;
      continue;
    }

    if (char === '"') {
      inQuotes = true;
      i++;
      continue;
    }
    if (char === ",") {
      record.push(field);
      field = "";
      i++;
      continue;
    }
    if (char === "\n") {
      record.push(field);
      records.push(record);
      record = [];
      field = "";
      i++;
      continue;
    }
    field += char;
    i++;
  }
  // flush trailing field/record (handles files without a final newline)
  if (field.length > 0 || record.length > 0) {
    record.push(field);
    records.push(record);
  }

  // drop fully-blank rows (common trailing-newline artifact)
  const nonEmpty = records
    .map((r, idx) => ({ r, idx }))
    .filter(({ r }) => r.some((v) => v.trim() !== ""));

  if (nonEmpty.length === 0) {
    return { headers: [], rows: [], rowLineNumbers: [] };
  }

  const headers = nonEmpty[0].r.map((h) => h.trim().toLowerCase());
  const dataRows = nonEmpty.slice(1);

  const rows: Record<string, string>[] = [];
  const rowLineNumbers: number[] = [];
  for (const { r, idx } of dataRows) {
    const obj: Record<string, string> = {};
    headers.forEach((h, colIdx) => {
      obj[h] = (r[colIdx] ?? "").trim();
    });
    rows.push(obj);
    rowLineNumbers.push(idx + 1); // +1 for 1-indexed, header already accounted for by using original idx
  }

  return { headers, rows, rowLineNumbers };
}
