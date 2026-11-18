import { describe, expect, it } from 'vitest';
import { buildAgentStatementPdf, pdfText } from './agentStatementPdf';
import type { AgentStatement, AgentStatementLine } from './agentStatements';

// The PDF writer is hand-rolled, so the things that make a PDF readable by other
// software have to be tested rather than assumed: byte offsets in the xref table,
// balanced delimiters in text, and money that is never summed across currencies.

const line = (over: Partial<AgentStatementLine> = {}): AgentStatementLine => ({
  accrual_id: 'a1',
  policy_no: 'POL-001',
  currency: 'UGX',
  accrued_on: '2026-11-01',
  paid_on: '2026-11-18',
  statement_date: '2026-11-18',
  basis: 'pct_of_broker_commission',
  gross_amount: 300000,
  wht_rate_pct: 10,
  wht_amount: 30000,
  wht_is_final: true,
  net_amount: 270000,
  status: 'paid',
  ...over,
});

const statement = (over: Partial<AgentStatement> = {}): AgentStatement => ({
  intermediary_id: 'i1',
  name: 'Acme Agents',
  category: 'sub_agent',
  from: '2026-11-01',
  to: '2026-11-30',
  gross_commission: 300000,
  wht_withheld: 30000,
  net_commission: 270000,
  paid: 270000,
  outstanding: 0,
  by_currency: [{
    currency: 'UGX', gross_commission: 300000, wht_withheld: 30000,
    net_commission: 270000, paid: 270000, outstanding: 0, lines: 1,
  }],
  lines: [line()],
  ...over,
});

const pdf = (s: AgentStatement) => buildAgentStatementPdf(s, '18 Nov 2026');

/** The xref table must point at the actual byte offset of each object. */
function xrefIsConsistent(out: string): boolean {
  const startxref = Number(/startxref\n(\d+)\n/.exec(out)?.[1]);
  if (!Number.isFinite(startxref)) return false;
  if (!out.slice(startxref).startsWith('xref')) return false;
  const body = /xref\n0 \d+\n([\s\S]*?)trailer/.exec(out)?.[1];
  if (!body) return false;
  const rows = body.trim().split('\n').filter((r) => r.trim() !== '');
  // row 0 is the free-list head
  for (let i = 1; i < rows.length; i += 1) {
    const offset = Number(rows[i].slice(0, 10));
    if (!out.slice(offset).startsWith(`${i} 0 obj`)) return false;
  }
  return true;
}

describe('the file is structurally a PDF', () => {
  it('starts and ends the way a reader expects', () => {
    const out = pdf(statement());
    expect(out.startsWith('%PDF-1.4\n')).toBe(true);
    expect(out.trimEnd().endsWith('%%EOF')).toBe(true);
  });

  it('has an xref table whose offsets point at the right objects', () => {
    // The classic hand-rolled-PDF failure: offsets that are off by a few bytes
    // produce a file that opens in one reader and is refused by the next.
    expect(xrefIsConsistent(pdf(statement()))).toBe(true);
  });

  it('declares a catalog and a page tree', () => {
    const out = pdf(statement());
    expect(out).toContain('/Type /Catalog');
    expect(out).toContain('/Type /Pages');
    expect(out).toContain('/Type /Page ');
  });

  it('counts its own pages', () => {
    const out = pdf(statement());
    const kids = /\/Kids \[([^\]]*)\]/.exec(out)?.[1] ?? '';
    const count = Number(/\/Count (\d+)/.exec(out)?.[1]);
    expect(count).toBe(kids.split(' 0 R').length - 1);
    expect(count).toBeGreaterThanOrEqual(1);
  });
});

describe('text cannot break the syntax', () => {
  it('escapes parentheses and backslashes', () => {
    expect(pdfText('O\'Brien (Sons) & Co\\')).toBe("O'Brien \\(Sons\\) & Co\\\\");
  });

  it('replaces characters outside the encoding rather than dropping the delimiter', () => {
    // Curly quotes and em dashes arrive from the database and from Intl; a raw
    // 0x2019 in a WinAnsi stream is not the problem, an unbalanced paren is.
    expect(pdfText('agent\u2019s \u201cfee\u201d \u2013 5\u00a0days')).toBe('agent\'s "fee" - 5 days');
  });

  it('survives a name that would otherwise unbalance the stream', () => {
    const out = pdf(statement({ name: 'O\'Brien (Sons) & Co' }));
    expect(xrefIsConsistent(out)).toBe(true);
    expect(out).toContain("O'Brien \\(Sons\\) & Co");
  });

  it('survives a name with characters outside the encoding', () => {
    const out = pdf(statement({ name: 'Müller Agencies \u2013 Kampala' }));
    expect(xrefIsConsistent(out)).toBe(true);
  });
});

describe('the figures on the page', () => {
  it('prints each currency, and never a total across them', () => {
    const out = pdf(statement({
      by_currency: [
        { currency: 'UGX', gross_commission: 900000, wht_withheld: 0, net_commission: 900000, paid: 0, outstanding: 900000, lines: 1 },
        { currency: 'USD', gross_commission: 500, wht_withheld: 0, net_commission: 500, paid: 0, outstanding: 500, lines: 1 },
      ],
      gross_commission: 900500,
    }));
    expect(out).toContain('UGX 900,000');
    expect(out).toContain('USD 500');
    // The flat sum is not money and must not be printed anywhere.
    expect(out).not.toContain('900,500');
  });

  it('shows the withholding, the net and the outstanding', () => {
    const out = pdf(statement());
    expect(out).toContain('Gross commission');
    expect(out).toContain('Tax withheld');
    expect(out).toContain('Net commission');
    expect(out).toContain('Outstanding');
    expect(out).toContain('UGX 30,000');
    expect(out).toContain('UGX 270,000');
  });

  it('says in words whether the tax was final', () => {
    expect(pdf(statement())).toContain('final tax');
    const onAccount = pdf(statement({
      lines: [line({ wht_is_final: false })],
    }));
    expect(onAccount).toContain('payment on account');
  });

  it('lists the shares themselves', () => {
    const out = pdf(statement());
    expect(out).toContain('POL-001');
    expect(out).toContain('2026-11-18');
  });

  it('says so plainly when the period is empty', () => {
    const out = pdf(statement({
      lines: [],
      by_currency: [{ currency: 'UGX', gross_commission: 0, wht_withheld: 0, net_commission: 0, paid: 0, outstanding: 0, lines: 0 }],
      gross_commission: 0, wht_withheld: 0, net_commission: 0, paid: 0, outstanding: 0,
    }));
    expect(out).toContain('No commission falls in this period');
  });

  it('is a pure function of its arguments', () => {
    // No clock, no randomness: the same statement and date produce the same bytes,
    // which is what lets a reprint be compared with the original.
    expect(pdf(statement())).toBe(pdf(statement()));
  });
});
