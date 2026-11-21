import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CancellationsReport from './CancellationsReport';

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
  group_key: 'k1', group_label: 'Motor', currency: 'UGX', cancellation_count: 2,
  return_premium: 300, commission_clawback: 30, retained_commission: 20, total_insurer_credit: 250, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [line({}), line({ group_key: 'k2', group_label: 'Marine', return_premium: 100, commission_clawback: 10, cancellation_count: 1 }),
    line({ group_key: 'k3', group_label: 'Marine', currency: 'USD', return_premium: 50.5, commission_clawback: 5, cancellation_count: 1 })];
});

const mount = () => render(<MemoryRouter><CancellationsReport /></MemoryRouter>);

describe('cancellations report', () => {
  it('asks the server for the period, grouping and imported flag', async () => {
    mount();
    await screen.findByText('Return premium:');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_cancellations', expect.objectContaining({ p_group_by: 'product_line', p_include_imported: false }));
  });

  it('totals return premium per currency and never across currencies', async () => {
    mount();
    await screen.findByText('Return premium:');
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Return premium: USh 400 US$50.50');
    expect(text).not.toContain('450');
  });

  it('exports every row with the chosen group heading', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [name, sheet, columns, rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^cancellations-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Cancellations');
    expect(rows).toHaveLength(3);
    expect(columns[0].header).toBe('Product line');
    expect(columns[3].accessor(rows[0])).toBe(300);
    expect(columns[6].accessor(rows[0])).toBe(250);
  });

  it('offers no export when nothing was cancelled', async () => {
    report = [];
    mount();
    await screen.findByText('No business was cancelled in this period.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});