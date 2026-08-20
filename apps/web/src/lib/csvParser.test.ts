import { describe, expect, it } from 'vitest';
import { parseCsv } from './csvParser';

describe('parseCsv', () => {
  it('parses a simple unquoted CSV', () => {
    const result = parseCsv('name,email\nJohn,john@example.com\nJane,jane@example.com');
    expect(result.headers).toEqual(['name', 'email']);
    expect(result.rows).toEqual([
      { name: 'John', email: 'john@example.com' },
      { name: 'Jane', email: 'jane@example.com' },
    ]);
  });

  it('lowercases and trims headers regardless of source capitalization', () => {
    const result = parseCsv(' Full Name , Email Address \nJohn,john@example.com');
    expect(result.headers).toEqual(['full name', 'email address']);
  });

  it('handles a quoted field containing a comma', () => {
    const result = parseCsv('name,city\n"Doe, John",Kampala');
    expect(result.rows).toEqual([{ name: 'Doe, John', city: 'Kampala' }]);
  });

  it('handles escaped double quotes inside a quoted field', () => {
    const result = parseCsv('name,nickname\nJohn,"""Big John"""');
    expect(result.rows).toEqual([{ name: 'John', nickname: '"Big John"' }]);
  });

  it('handles a quoted field containing a newline', () => {
    const result = parseCsv('name,note\nJohn,"line one\nline two"');
    expect(result.rows).toEqual([{ name: 'John', note: 'line one\nline two' }]);
  });

  it('normalizes CRLF line endings', () => {
    const result = parseCsv('name,email\r\nJohn,john@example.com\r\nJane,jane@example.com');
    expect(result.rows).toHaveLength(2);
    expect(result.rows[0]).toEqual({ name: 'John', email: 'john@example.com' });
  });

  it('normalizes bare CR line endings', () => {
    const result = parseCsv('name,email\rJohn,john@example.com');
    expect(result.rows).toEqual([{ name: 'John', email: 'john@example.com' }]);
  });

  it('strips a leading UTF-8 BOM', () => {
    const result = parseCsv('\uFEFFname,email\nJohn,john@example.com');
    expect(result.headers).toEqual(['name', 'email']);
  });

  it('drops fully-blank rows (trailing newline artifact)', () => {
    const result = parseCsv('name,email\nJohn,john@example.com\n\n');
    expect(result.rows).toHaveLength(1);
  });

  it('drops a blank row in the middle of the data', () => {
    const result = parseCsv('name,email\nJohn,john@example.com\n,\nJane,jane@example.com');
    expect(result.rows).toHaveLength(2);
    expect(result.rows.map((r) => r.name)).toEqual(['John', 'Jane']);
  });

  it('handles a file with no trailing newline', () => {
    const result = parseCsv('name,email\nJohn,john@example.com');
    expect(result.rows).toEqual([{ name: 'John', email: 'john@example.com' }]);
  });

  it('pads missing trailing columns with empty string for ragged rows', () => {
    const result = parseCsv('name,email,phone\nJohn,john@example.com');
    expect(result.rows).toEqual([{ name: 'John', email: 'john@example.com', phone: '' }]);
  });

  it('returns 1-indexed source line numbers per row for error messages', () => {
    const result = parseCsv('name,email\nJohn,john@example.com\nJane,jane@example.com');
    // header is line 1, so first data row is line 2, second is line 3
    expect(result.rowLineNumbers).toEqual([2, 3]);
  });

  it('returns empty result for empty input', () => {
    const result = parseCsv('');
    expect(result).toEqual({ headers: [], rows: [], rowLineNumbers: [] });
  });

  it('returns empty result for header-only input', () => {
    const result = parseCsv('name,email');
    expect(result.headers).toEqual(['name', 'email']);
    expect(result.rows).toEqual([]);
  });

  it('trims whitespace from unquoted field values', () => {
    const result = parseCsv('name,email\n  John  ,  john@example.com  ');
    expect(result.rows).toEqual([{ name: 'John', email: 'john@example.com' }]);
  });
});
