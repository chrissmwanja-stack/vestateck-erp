import { describe, expect, it } from 'vitest';
import { REMITTANCE_EXPORT_COLUMNS, chunk, daysPastDeadline, remittanceExportRows, remittanceFacts, sortRemittanceRows, type RemittanceRow } from './remittance';

const row = (over: Partial<RemittanceRow>): RemittanceRow => ({
  policy_id: 'p', policy_no: 'POL-1', insurer_id: 'i', unremitted_amount: 100, receipt_date: '2026-10-01', deadline_date: '2026-10-02', status: 'overdue', ...over,
});

describe('remittance report helpers', () => {
  it('counts each status that raises an alert', () => {
    const rows = [row({}), row({}), row({ status: 'due_today' }), row({ status: 'deadline_not_set' }), row({ status: 'receipt_date_missing' }), row({ status: 'within_deadline' })];
    expect(remittanceFacts(rows)).toEqual({ overdue: 2, dueToday: 1, deadlineNotSet: 1, receiptMissing: 1 });
    expect(remittanceFacts([])).toEqual({ overdue: 0, dueToday: 0, deadlineNotSet: 0, receiptMissing: 0 });
  });
  it('counts days past the deadline and never goes below zero', () => {
    expect(daysPastDeadline('2026-10-10', '2026-10-17')).toBe(7);
    expect(daysPastDeadline('2026-10-17', '2026-10-17')).toBe(0);
    expect(daysPastDeadline('2026-10-20', '2026-10-17')).toBe(0);
    expect(daysPastDeadline(null, '2026-10-17')).toBe(0);
  });
  it('puts the most urgent first, then the earliest deadline', () => {
    const sorted = sortRemittanceRows([
      row({ policy_no: 'C', status: 'within_deadline', deadline_date: '2026-10-30' }),
      row({ policy_no: 'B', status: 'overdue', deadline_date: '2026-10-10' }),
      row({ policy_no: 'A', status: 'overdue', deadline_date: '2026-10-05' }),
      row({ policy_no: 'D', status: 'deadline_not_set', deadline_date: null }),
      row({ policy_no: 'E', status: 'due_today', deadline_date: '2026-10-17' }),
    ]);
    expect(sorted.map((r) => r.policy_no)).toEqual(['A', 'B', 'E', 'D', 'C']);
  });
  it('splits a list into groups no larger than the size, keeping order', () => {
    expect(chunk([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(chunk([], 3)).toEqual([]);
    expect(chunk([1, 2], 5)).toEqual([[1, 2]]);
  });
  it('builds export rows with the lookups applied, the amount as a number and days late only for overdue rows', () => {
    const rows = [
      row({ policy_no: 'A', unremitted_amount: '1250.5', status: 'overdue', deadline_date: '2026-10-05' }),
      row({ policy_no: 'B', unremitted_amount: 40, status: 'within_deadline', deadline_date: null, receipt_date: null }),
    ];
    const out = remittanceExportRows(rows, '2026-10-08', { client: () => 'Acme', insurer: () => 'Jubilee', currency: (r) => (r.policy_no === 'A' ? 'USD' : 'UGX') });
    expect(out[0]).toMatchObject({ policy_no: 'A', client: 'Acme', insurer: 'Jubilee', currency: 'USD', amount: 1250.5, status: 'Overdue', days_late: 3 });
    expect(out[1]).toMatchObject({ currency: 'UGX', receipt_date: '', deadline_date: '', status: 'Within deadline', days_late: 0 });
    expect(REMITTANCE_EXPORT_COLUMNS.map((c) => c.header)).toEqual([
      'Policy', 'Client', 'Insurer', 'Currency', 'Held, not remitted', 'Received', 'Deadline', 'Status', 'Days late',
    ]);
    expect(REMITTANCE_EXPORT_COLUMNS[4].accessor(out[0])).toBe('1,250.50');
  });
});
