import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CommissionReceivable from './CommissionReceivable';

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
  open_item_id: 'o1', policy_id: 'p1', policy_no: 'POL-1', insurer_id: 'i1', insurer_name: 'Alpha Assurance', currency: 'UGX',
  document_no: 'CR-1', document_date: '2026-09-01', due_date: '2026-09-01', billed: 1000, received: 400, credited: 0, outstanding: 600,
  days_overdue: 10, age_bucket: '1-30', ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    line({}),
    line({ open_item_id: 'o2', policy_id: 'p2', policy_no: 'POL-2', insurer_name: 'Beta Re', outstanding: 250.5, currency: 'USD', billed: 250.5, received: 0, days_overdue: 120, age_bucket: '90+' }),
  ];
});

const mount = () => render(<MemoryRouter><CommissionReceivable /></MemoryRouter>);

describe('commission receivable report', () => {
  it('asks the server for the chosen as-at date', async () => {
    mount();
    await screen.findByText('Total receivable:');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_commission_receivable', { p_as_of: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/) });
  });

  it('lists each insurer and totals currencies separately', async () => {
    mount();
    await screen.findByText('Total receivable:');
    expect(screen.getByText('Alpha Assurance')).toBeInTheDocument();
    expect(screen.getByText('Beta Re')).toBeInTheDocument();
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Total receivable: USh 600 US$250.50');
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
    expect(subtitle).toContain('Receivable:');
  });

  it('offers no export when no insurer owes commission', async () => {
    report = [];
    mount();
    await screen.findByText('No insurer owes commission on this date.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
