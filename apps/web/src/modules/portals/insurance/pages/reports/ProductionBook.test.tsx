import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ProductionBook from './ProductionBook';

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
  group_key: 'k1', group_label: 'Motor', currency: 'UGX', new_business: 1000, endorsements: 100, cancellations: -200, reversals: 0,
  net_written: 900, policy_count: 2, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [line({}), line({ group_key: 'k2', group_label: 'Marine', net_written: 400, new_business: 400, endorsements: 0, cancellations: 0, policy_count: 1 }),
    line({ group_key: 'k3', group_label: 'Marine', currency: 'USD', net_written: 250.5, new_business: 250.5, endorsements: 0, cancellations: 0, policy_count: 1 })];
});

const mount = () => render(<MemoryRouter><ProductionBook /></MemoryRouter>);

describe('Production Book', () => {
  it('asks the server for the period, grouping and imported flag', async () => {
    mount();
    await screen.findByText('Net written premium:');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_production', expect.objectContaining({ p_group_by: 'product_line', p_include_imported: false }));
    const args = rpcMock.mock.calls[0][1] as { p_from: string; p_to: string };
    expect(args.p_from).toMatch(/^\d{4}-\d{2}-01$/);
    expect(args.p_to).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('shows the rows and totals each currency separately', async () => {
    mount();
    await screen.findByText('Net written premium:');
    expect(screen.getAllByText('Marine')).toHaveLength(2);
    const totals = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(totals).toContain('Net written premium: USh 1,300 US$250.50'); // UGX 900 + 400, USD on its own
    expect(totals).not.toContain('1,550'); // never added across currencies
  });

  it('exports every row shown, with the group heading the user chose', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [name, sheet, columns, rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^production-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Production');
    expect(rows).toHaveLength(3);
    expect(columns[0].header).toBe('Product line');
    expect(columns[6].accessor(rows[0])).toBe(900);
  });

  it('offers no export when nothing was written', async () => {
    report = [];
    mount();
    await screen.findByText('No premium was written in this period.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
