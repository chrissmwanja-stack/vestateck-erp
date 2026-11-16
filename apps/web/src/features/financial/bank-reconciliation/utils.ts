// Matching looks up to this many days either side of the statement date
// (fin_bank_line_candidates), so the book-side lists reach that far past
// the statement window or a candidate just outside it would be invisible.
export const MATCH_WINDOW_DAYS = 5;

export const today = () => new Date().toISOString().slice(0, 10);
export const monthAgo = () => {
  const d = new Date();
  d.setMonth(d.getMonth() - 1);
  return d.toISOString().slice(0, 10);
};
export const shiftDate = (iso: string, days: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return iso;
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
};
export const fmt = (n: number | null | undefined) => (n == null ? '—' : Number(n).toLocaleString());

// Minimal CSV parser -- no external dependency. Handles a header row
// plus simple quoted fields (a bank export with a comma inside a
// quoted description). Doesn't attempt full RFC 4180 edge cases
// (escaped quotes within quotes) -- good enough for a bank statement
// export, and the import RPC validates required fields regardless.
export function parseCsv(text: string): Record<string, string>[] {
  const lines = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  if (lines.length < 2) return [];
  const splitLine = (line: string) => {
    const cells: string[] = [];
    let cur = '';
    let inQuotes = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === ',' && !inQuotes) {
        cells.push(cur.trim());
        cur = '';
      } else {
        cur += ch;
      }
    }
    cells.push(cur.trim());
    return cells;
  };
  const headers = splitLine(lines[0]).map((h) => h.toLowerCase());
  return lines.slice(1).map((line) => {
    const cells = splitLine(line);
    const row: Record<string, string> = {};
    headers.forEach((h, i) => (row[h] = cells[i] ?? ''));
    return row;
  });
}
