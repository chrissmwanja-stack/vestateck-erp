import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mockExcel = vi.fn();
const mockPdf = vi.fn();
vi.mock('../../../../../lib/reportExport', () => ({
  exportReportToExcel: (...a: unknown[]) => mockExcel(...a),
  exportReportToPdf: (...a: unknown[]) => mockPdf(...a),
}));

let report: unknown[] = [];
const rpcMock = vi.fn((_fn: string, _args: Record<string, unknown>) => Promise.resolve({ data: report, error: null }));
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { rpc: (fn: string, args: Record<string, unknown>) => rpcMock(fn, args) },
}));

import RenewalRetention from './RenewalRetention';

const row = (over: Record<string, unknown>) => ({
  group_key: '2026-10', group_label: 'Oct 2026', currency: 'UGX', due_count: 10, renewed_count: 7, lost_count: 2, unresolved_count: 1,
  upcoming_count: 0, expiring_premium: 10000, renewed_premium: 8000, retention_count_pct: 70, retention_premium_pct: 80, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [row({}), row({ group_key: '2026-12', group_label: 'Dec 2026', due_count: 4, renewed_count: 0, lost_count: 0, unresolved_count: 0,
    upcoming_count: 4, retention_count_pct: null, retention_premium_pct: null })];
});

const mount = () => render(<MemoryRouter><RenewalRetention /></MemoryRouter>);

describe('renewal retention', () => {
  it('asks the server for the period, grouping and imported flag', async () => {
    mount();
    await screen.findByText('Oct 2026');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_renewal_retention', expect.objectContaining({ p_group_by: 'month', p_include_imported: true }));
  });

  it('shows the server percentages and a dash when nothing has expired yet', async () => {
    mount();
    await screen.findByText('70.0%');
    expect(screen.getByText('80.0%')).toBeInTheDocument();
    expect(screen.getAllByText('-')).toHaveLength(2);
  });

  it('exports every row with the chosen group heading', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [name, sheet, columns, rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^renewal-retention-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Renewal retention');
    expect(rows).toHaveLength(2);
    expect(columns[0].header).toBe('Month');
    expect(columns[9].accessor(rows[0])).toBe('70.0%');
    expect(columns[9].accessor(rows[1])).toBe('-');
  });

  it('offers no export when nothing falls due', async () => {
    report = [];
    mount();
    await screen.findByText('No policies fall due in this period.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
