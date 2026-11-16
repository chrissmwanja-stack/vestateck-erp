import { describe, expect, it } from 'vitest';
import { fmt, parseCsv, shiftDate } from './utils';

describe('parseCsv', () => {
  it('maps rows to lower-cased header keys', () => {
    const rows = parseCsv('Statement_Date,Description,Reference,Amount\n2026-09-06,SALARY,REF1,-1674500\n');
    expect(rows).toEqual([{ statement_date: '2026-09-06', description: 'SALARY', reference: 'REF1', amount: '-1674500' }]);
  });

  it('keeps a comma inside a quoted field and handles CRLF line endings', () => {
    const rows = parseCsv('statement_date,description,amount\r\n2026-09-06,"ACME, LTD",500\r\n');
    expect(rows[0].description).toBe('ACME, LTD');
    expect(rows[0].amount).toBe('500');
  });

  it('returns nothing for a header-only or empty input', () => {
    expect(parseCsv('')).toEqual([]);
    expect(parseCsv('statement_date,amount')).toEqual([]);
  });

  it('fills missing trailing cells with an empty string', () => {
    expect(parseCsv('a,b,c\n1,2\n')[0]).toEqual({ a: '1', b: '2', c: '' });
  });
});

describe('shiftDate', () => {
  it('moves across month and year boundaries', () => {
    expect(shiftDate('2026-03-01', -5)).toBe('2026-02-24');
    expect(shiftDate('2026-12-30', 5)).toBe('2027-01-04');
  });

  it('returns an unparseable date unchanged', () => {
    expect(shiftDate('not-a-date', 3)).toBe('not-a-date');
  });
});

describe('fmt', () => {
  it('renders a dash for null/undefined and a localised number otherwise', () => {
    expect(fmt(null)).toBe('—');
    expect(fmt(undefined)).toBe('—');
    expect(fmt(1500)).toBe(Number(1500).toLocaleString());
  });
});
