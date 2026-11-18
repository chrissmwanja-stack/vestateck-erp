// ---------------------------------------------------------------------------
// A minimal PDF writer for agent commission statements
// ---------------------------------------------------------------------------
// Why hand-rolled rather than a library: this module has no PDF dependency, and
// adding one to render two tables of text would be a supply chain for a feature
// that needs Helvetica and a page counter. The output is deliberately plain --
// A4, one font, no images -- which is what a statement should be anyway.
//
// What it must get right, and what the tests check:
//   * the xref offsets must be byte offsets into the file as written, or readers
//     refuse the file;
//   * text must be escaped, because an agent called "O'Brien & Sons" would
//     otherwise produce a PDF whose parentheses no longer balance;
//   * money must be formatted per currency, never summed across them.
//
// It is a text renderer. It does not calculate anything: the figures arrive from
// the statement RPC, already decided.

import type { AgentStatement } from './agentStatements';
import { statementCurrencies, statementLineNet, statementPeriodLabel, statementWithholdingSentence } from './agentStatements';

const PAGE_W = 595; // A4 points
const PAGE_H = 842;
const MARGIN = 48;

/** WinAnsi-safe: drop anything outside ASCII and escape the three PDF delimiters. */
export function pdfText(value: string): string {
  const ascii = value
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[\u2013\u2014]/g, '-')
    .replace(/\u2026/g, '...')
    // Anything else outside printable ASCII becomes a space rather than a
    // replacement char: a statement with a gap is readable, a broken glyph is not.
    .replace(/[^\x20-\x7E]/g, ' ');
  return ascii.replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

const money = (amount: number, currency: string): string =>
  new Intl.NumberFormat('en-GB', { style: 'currency', currency, currencyDisplay: 'code' }).format(amount);

interface Line { text: string; size: number; x: number; bold?: boolean }

const wrap = (text: string, max: number): string[] => {
  const words = text.split(/\s+/);
  const out: string[] = [];
  let cur = '';
  for (const w of words) {
    if ((cur + ' ' + w).trim().length <= max) cur = (cur + ' ' + w).trim();
    else { if (cur) out.push(cur); cur = w; }
  }
  if (cur) out.push(cur);
  return out;
};

/**
 * Build the statement as a PDF byte string.
 *
 * `generatedOn` is passed in rather than read from the clock so the output is a
 * pure function of its arguments, which is what makes it testable at all.
 */
export function buildAgentStatementPdf(statement: AgentStatement, generatedOn: string): string {
  const pages: Line[][] = [];
  let page: Line[] = [];
  let y = PAGE_H - MARGIN;

  const emit = (text: string, size: number, x = MARGIN, bold = false) => {
    if (y < MARGIN + 60) { pages.push(page); page = []; y = PAGE_H - MARGIN; }
    page.push({ text, size, x, bold });
  };

  emit('AGENT COMMISSION STATEMENT', 16, MARGIN, true);
  y -= 20;
  emit(statement.name, 12, MARGIN, true);
  y -= 16;
  emit(`Period: ${statementPeriodLabel(statement)}`, 9);
  y -= 12;
  emit(`Generated: ${generatedOn}`, 9);
  y -= 12;
  emit(`Reference: ${statement.intermediary_id}`, 9, MARGIN);
  y -= 22;

  for (const c of statementCurrencies(statement)) {
    emit(`${c.currency}`, 11, MARGIN, true);
    y -= 14;
    for (const [label, value] of [
      ['Gross commission', c.gross_commission],
      ['Tax withheld', c.wht_withheld],
      ['Net commission', c.net_commission],
      ['Paid to agent', c.paid],
      ['Outstanding', c.outstanding],
    ] as [string, number][]) {
      emit(label, 9);
      // Right-aligned by placing at a fixed column; mono spacing is not available
      // in Helvetica, so the label and value are one string with padding.
      page[page.length - 1] = { text: `${label.padEnd(34, ' ')}${money(value, c.currency)}`, size: 9, x: MARGIN };
    }
    y -= 18;
  }

  y -= 6;
  emit('Shares', 11, MARGIN, true);
  y -= 14;
  const header = 'Date        Policy              Status      Gross            Tax              Net';
  emit(header, 8, MARGIN, true);
  y -= 12;

  const sorted = [...statement.lines].sort((a, b) => a.statement_date.localeCompare(b.statement_date));
  for (const l of sorted) {
    const row = [
      l.statement_date,
      (l.policy_no ?? '-').slice(0, 18).padEnd(18, ' '),
      l.status.slice(0, 10).padEnd(10, ' '),
      money(l.gross_amount, l.currency),
      money(l.wht_amount, l.currency),
      money(statementLineNet(l), l.currency),
    ].join('  ');
    emit(row, 8);
    y -= 11;
  }
  if (sorted.length === 0) {
    emit('No commission falls in this period.', 9);
    y -= 12;
  }

  y -= 10;
  for (const l of wrap(statementWithholdingSentence(statement), 100)) {
    emit(l, 8);
    y -= 10;
  }
  y -= 10;
  for (const l of wrap(
    'Amounts in different currencies are never added together; each is stated separately above. '
    + 'This statement is produced from the brokerage commission ledger and is not a tax document.',
    100,
  )) {
    emit(l, 8);
    y -= 10;
  }
  pages.push(page);

  // ---- serialisation -----------------------------------------------------
  const contentStreams = pages.map((lines) => {
    let out = 'BT\n';
    let cursor = PAGE_H - MARGIN;
    for (const line of lines) {
      cursor -= line.size + 3;
      out += `/${line.bold ? 'F2' : 'F1'} ${line.size} Tf\n1 0 0 1 ${line.x} ${cursor} Tm\n(${pdfText(line.text)}) Tj\n`;
    }
    return out + 'ET\n';
  });

  const objects: string[] = [];
  const add = (body: string): number => { objects.push(body); return objects.length; };

  const catalogId = add('');           // 1, filled below
  const pagesId = add('');
  const f1 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
  const f2 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');

  const pageIds: number[] = [];
  const contentIds: number[] = [];
  for (const stream of contentStreams) {
    contentIds.push(add(`<< /Length ${stream.length} >>\nstream\n${stream}endstream`));
  }
  for (const cid of contentIds) {
    pageIds.push(add(
      `<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 ${PAGE_W} ${PAGE_H}] `
      + `/Resources << /Font << /F1 ${f1} 0 R /F2 ${f2} 0 R >> >> /Contents ${cid} 0 R >>`,
    ));
  }
  objects[pagesId - 1] = `<< /Type /Pages /Kids [${pageIds.map((i) => `${i} 0 R`).join(' ')}] /Count ${pageIds.length} >>`;
  objects[catalogId - 1] = `<< /Type /Catalog /Pages ${pagesId} 0 R >>`;

  let out = '%PDF-1.4\n';
  const offsets: number[] = [];
  objects.forEach((body, i) => {
    offsets.push(out.length);
    out += `${i + 1} 0 obj\n${body}\nendobj\n`;
  });
  const xrefStart = out.length;
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const off of offsets) out += `${String(off).padStart(10, '0')} 00000 n \n`;
  out += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R >>\nstartxref\n${xrefStart}\n%%EOF\n`;

  return out;
}
