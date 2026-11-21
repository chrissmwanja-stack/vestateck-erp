import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClaimsAgeing from './ClaimsAgeing';

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

const row = (over: Record<string, unknown>) => ({
  group_key: 'all', group_label: 'All open claims', currency: 'UGX', age_bucket: '0-30', claim_count: 2, reserve_total: 900,
  outstanding_total: 900, oldest_age_days: 12, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    row({}),
    row({ age_bucket: '180+', claim_count: 1, reserve_total: 100, outstanding_total: 100, oldest_age_days: 240 }),
    row({ currency: 'USD', claim_count: 1, reserve_total: 50.5, outstanding_total: 50.5 }),
  ];
});

describe('claims ageing report', () => {
  it('asks the server for the chosen date with no grouping by default', async () => {
    render(<ClaimsAgeing />);
    await screen.findByText('Total outstanding:');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_claims_ageing', { p_as_of: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/), p_group_by: 'none' });
  });

  it('shows each age bucket and totals currencies separately', async () => {
    render(<ClaimsAgeing />);
    await screen.findByText('Total outstanding:');
    expect(screen.getByText('Over 180 days')).toBeInTheDocument();
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Total outstanding: USh 1,000 US$50.50');
  });

  it('exports the rows shown', async () => {
    render(<ClaimsAgeing />);
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [, , , rows] = mockExcel.mock.calls[0];
    expect(rows).toHaveLength(3);
    await userEvent.click(screen.getByRole('button', { name: 'Export PDF' }));
    expect(mockPdf.mock.calls[0][4]).toContain('Outstanding:');
  });

  it('offers no export when nothing was open', async () => {
    report = [];
    render(<ClaimsAgeing />);
    await screen.findByText('No claims were open on this date.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
