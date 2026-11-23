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

import InsurerPerformance from './InsurerPerformance';

const row = (over: Record<string, unknown>) => ({
  insurer_id: 'i1', insurer_name: 'Alpha', currency: 'UGX', policy_count: 2, cancelled_policy_count: 0, premium_placed: 130000,
  commission: 13000, commission_pct: 10, claim_count: 3, open_claim_count: 3, claims_paid: 3000, claims_outstanding: 19600.61,
  claims_incurred: 22600.61, loss_ratio_pct: 17.4, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    row({}),
    row({ insurer_id: 'i2', insurer_name: 'Beta', policy_count: 1, cancelled_policy_count: 1, premium_placed: 20000, commission: 2000, claim_count: 2,
      open_claim_count: 2, claims_paid: 2000, claims_outstanding: 6400.4, claims_incurred: 8400.4, loss_ratio_pct: 42 }),
    row({ insurer_id: 'i3', insurer_name: 'Gamma', currency: 'USD', policy_count: 1, premium_placed: 500, commission: 50, claim_count: 0,
      open_claim_count: 0, claims_paid: 0, claims_outstanding: 0, claims_incurred: 0, loss_ratio_pct: 0 }),
  ];
});

const mount = () => render(<MemoryRouter><InsurerPerformance /></MemoryRouter>);

describe('insurer performance', () => {
  it('asks the server for the period and the imported flag, and lists each insurer', async () => {
    mount();
    await screen.findByText('Alpha');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_insurer_performance', expect.objectContaining({ p_include_imported: false }));
    expect(screen.getByText('Beta')).toBeInTheDocument();
    expect(screen.getByText('Gamma')).toBeInTheDocument();
  });

  it('shows the loss ratio the server computed and notes cancelled policies', async () => {
    mount();
    await screen.findByText('17.4%');
    expect(screen.getByText('42.0%')).toBeInTheDocument();
    expect(screen.getByText('1 cancelled')).toBeInTheDocument();
  });

  it('adds totals per currency and never across currencies', async () => {
    mount();
    await screen.findByText('Totals:');
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('UGX: premium placed');
    expect(text).toContain('USD: premium placed');
    expect(text).not.toContain('150,500');
  });

  it('exports every row', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [name, sheet, columns, rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^insurer-performance-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Insurer performance');
    expect(rows).toHaveLength(3);
    expect(columns[4].accessor(rows[0])).toBe(130000);
    expect(columns[12].accessor(rows[0])).toBe('17.4%');
  });

  it('offers no export when nothing was bound', async () => {
    report = [];
    mount();
    await screen.findByText('No policies were bound in this period.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
