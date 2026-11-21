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

import CancellationRegister from './CancellationRegister';

const row = (over: Record<string, unknown>) => ({
  cancellation_id: 'c1', cancellation_no: 'CAN-001', policy_id: 'p1', policy_no: 'POL-001', client_name: 'Acme', insurer_name: 'Alpha',
  product_line_name: 'Motor', currency: 'UGX', reason: 'Client request', effective_date: '2026-11-02', posting_date: '2026-11-03',
  return_premium: 300, commission_clawback: 30, retained_commission: 20, total_insurer_credit: 250, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [row({}), row({ cancellation_id: 'c2', cancellation_no: 'CAN-002', return_premium: 100 }),
    row({ cancellation_id: 'c3', cancellation_no: 'CAN-003', currency: 'USD', return_premium: 50.5 })];
});

const mount = () => render(<MemoryRouter><CancellationRegister /></MemoryRouter>);

describe('cancellation register', () => {
  it('asks the server for the period and the imported flag, and lists each cancellation', async () => {
    mount();
    await screen.findByText('CAN-001');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_cancellation_register', expect.objectContaining({ p_include_imported: false }));
    expect(screen.getByText('CAN-002')).toBeInTheDocument();
    expect(screen.getByText('CAN-003')).toBeInTheDocument();
  });

  it('totals return premium per currency and never across currencies', async () => {
    mount();
    await screen.findByText('Return premium:');
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Return premium: USh 400 US$50.50');
    expect(text).not.toContain('450');
  });

  it('exports every row', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [name, sheet, columns, rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^cancellation-register-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Cancellation register');
    expect(rows).toHaveLength(3);
    expect(columns[0].accessor(rows[0])).toBe('CAN-001');
    expect(columns[9].accessor(rows[0])).toBe(300);
  });

  it('offers no export when nothing was cancelled', async () => {
    report = [];
    mount();
    await screen.findByText('No business was cancelled in this period.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
