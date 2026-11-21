import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PremiumCollected from './PremiumCollected';

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

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    { group_key: '2026-11', group_label: '2026-11', currency: 'UGX', collected: 400, receipt_count: 1 },
    { group_key: '2026-10', group_label: '2026-10', currency: 'UGX', collected: 600, receipt_count: 2 },
    { group_key: '2026-11', group_label: '2026-11', currency: 'USD', collected: 75, receipt_count: 1 },
  ];
});

const mount = () => render(<MemoryRouter><PremiumCollected /></MemoryRouter>);

describe('premium collected report', () => {
  it('asks the server for the period grouped by month', async () => {
    mount();
    await screen.findByText('Total collected:');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_premium_collected', expect.objectContaining({ p_group_by: 'month' }));
  });

  it('totals each currency on its own', async () => {
    mount();
    await screen.findByText('Total collected:');
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Total collected: USh 1,000 US$75.00'); // UGX 400 + 600, USD on its own
    expect(text).not.toContain('1,075');
  });

  it('exports what is shown, and says the period in the PDF subtitle', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export PDF' }));
    const [name, title, , rows, subtitle] = mockPdf.mock.calls[0];
    expect(name).toMatch(/^premium-collected-/);
    expect(title).toBe('Premium collected');
    expect(rows).toHaveLength(3);
    expect(subtitle).toContain(' to ');
    expect(subtitle).toContain('By month');
  });

  it('offers no export when nothing was collected', async () => {
    report = [];
    mount();
    await screen.findByText('No premium was collected in this period.');
    expect(screen.queryByRole('button', { name: 'Export PDF' })).not.toBeInTheDocument();
  });
});
