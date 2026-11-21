import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import OutstandingPremium from './OutstandingPremium';

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

const line = (over: Record<string, unknown>) => ({
  open_item_id: 'o1', policy_id: 'p1', policy_no: 'POL-1', client_id: 'c1', client_name: 'Acme Ltd', currency: 'UGX', document_no: 'INV-1',
  document_date: '2026-09-01', due_date: '2026-09-01', billed: 1000, received: 400, credited: 0, outstanding: 600, days_overdue: 10, age_bucket: '1-30', ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    line({}),
    line({ open_item_id: 'o2', policy_id: 'p2', policy_no: 'POL-2', client_name: 'Beta Co', outstanding: 250.5, currency: 'USD', billed: 250.5, received: 0, days_overdue: 120, age_bucket: '90+' }),
  ];
});

const mount = () => render(<MemoryRouter><OutstandingPremium /></MemoryRouter>);

describe('outstanding premium report', () => {
  it('asks the server for the chosen as-at date', async () => {
    mount();
    await screen.findByText('Total outstanding:');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_outstanding_premium', { p_as_of: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/) });
  });

  it('lists each debtor and totals currencies separately', async () => {
    mount();
    await screen.findByText('Total outstanding:');
    expect(screen.getByText('Acme Ltd')).toBeInTheDocument();
    expect(screen.getByText('Beta Co')).toBeInTheDocument();
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Total outstanding: USh 600 US$250.50');
    expect(text).not.toContain('850');
  });

  it('filters by age and exports only the rows left, saying so in the subtitle', async () => {
    mount();
    await userEvent.click(await screen.findByText(/^Over 90 days \(1\)/));
    await userEvent.click(screen.getByRole('button', { name: 'Export Excel' }));
    const [, , , rows] = mockExcel.mock.calls[0];
    expect(rows.map((r: { policy_no: string }) => r.policy_no)).toEqual(['POL-2']);
    await userEvent.click(screen.getByRole('button', { name: 'Export PDF' }));
    const subtitle = mockPdf.mock.calls[0][4] as string;
    expect(subtitle).toContain('Age: Over 90 days');
    expect(subtitle).toContain('Outstanding:');
  });

  it('offers no export when no client owes premium', async () => {
    report = [];
    mount();
    await screen.findByText('No client owes premium on this date.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
