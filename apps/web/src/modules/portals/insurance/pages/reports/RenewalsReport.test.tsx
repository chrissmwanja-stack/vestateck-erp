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

import RenewalsReport from './RenewalsReport';

const row = (over: Record<string, unknown>) => ({
  policy_id: 'p1', policy_no: 'POL-001', client_id: 'cl1', client_name: 'Acme', insurer_id: 'i1', insurer_name: 'Alpha',
  product_line_id: 'pl1', product_line_name: 'Motor', branch_id: null, branch_name: null, agent_id: null, agent_name: null,
  currency: 'UGX', expiry_date: '2026-12-01', days_to_expiry: 10, expiring_premium: 1000, outcome: 'upcoming',
  outcome_reason: null, renewal_policy_id: null, renewal_policy_no: null, renewal_premium: null, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    row({}),
    row({ policy_id: 'p2', policy_no: 'POL-002', outcome: 'renewed', renewal_policy_no: 'POL-002-R', renewal_premium: 1100, expiring_premium: 2000 }),
    row({ policy_id: 'p3', policy_no: 'POL-003', outcome: 'lost', outcome_reason: 'Went to competitor', expiring_premium: 500, days_to_expiry: -5 }),
    row({ policy_id: 'p4', policy_no: 'POL-004', currency: 'USD', expiring_premium: 40.5 }),
  ];
});

const mount = () => render(<MemoryRouter><RenewalsReport /></MemoryRouter>);

describe('renewals report', () => {
  it('asks the server for the period and includes imported policies by default', async () => {
    mount();
    await screen.findByText('POL-001');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_renewals', expect.objectContaining({ p_include_imported: true }));
  });

  it('shows the outcome, the reason and the renewal policy', async () => {
    mount();
    await screen.findByText('POL-002-R');
    expect(screen.getByText('Went to competitor')).toBeInTheDocument();
    expect(screen.getByText('Renewed')).toBeInTheDocument();
    expect(screen.getByText('Lost')).toBeInTheDocument();
  });

  it('totals expiring premium per currency and never across currencies', async () => {
    mount();
    await screen.findByText('Expiring premium:');
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Expiring premium: USh 3,500 US$40.50');
  });

  it('exports every row', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [name, sheet, columns, rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^renewals-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Renewals');
    expect(rows).toHaveLength(4);
    expect(columns[10].accessor(rows[1])).toBe('Renewed');
  });

  it('offers no export when nothing falls due', async () => {
    report = [];
    mount();
    await screen.findByText('No policies fall due in this period.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
