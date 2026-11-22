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

let summary: unknown[] = [];
let exceptions: unknown[] = [];
let trace: unknown[] = [];
const rpcMock = vi.fn((fn: string, _args: Record<string, unknown>) => {
  const data = fn === 'ins_report_statutory_charges' ? summary
    : fn === 'ins_report_statutory_charge_exceptions' ? exceptions
    : fn === 'ins_report_statutory_charge_trace' ? trace : [];
  return Promise.resolve({ data, error: null });
});
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { rpc: (fn: string, args: Record<string, unknown>) => rpcMock(fn, args) },
}));

import StatutoryChargesReport from './StatutoryChargesReport';

const line = (over: Record<string, unknown>) => ({
  group_key: 'UG_INSURANCE_TRAINING_LEVY', group_label: 'Insurance Training Levy', currency: 'UGX', policy_count: 3,
  assessed: 1166.67, collected: 165.84, uncollected: 1000.83, remitted: 110.5, held_unremitted: 55.34, remitter: 'insurer', ...over,
});

const traceRow = (over: Record<string, unknown>) => ({
  stage: 'collected', cohort_month: '2026-11', policy_id: 'p1', policy_no: 'POL-001', client_name: 'Acme', policy_status: 'active',
  insurer_id: 'i1', insurer_name: 'Alpha', charge_id: 'c1', charge_code: 'UG_INSURANCE_TRAINING_LEVY', charge_name: 'Levy',
  charge_class: 'statutory_levy', collector: 'insurer', recipient_name: 'Insurance Training College', payable_role: 'x',
  currency: 'UGX', event_date: '2026-11-22', settlement_id: 's1', settlement_no: 'RCP-001', amount: 165.84,
  basis: 'pro rata: receipt 33333 x allocation 500 / invoice 100500', ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  summary = [line({}), line({ group_key: 'X', group_label: 'Dollar levy', currency: 'USD', assessed: 40.5, collected: 0, uncollected: 40.5, remitted: 0, held_unremitted: 0, policy_count: 1 })];
  exceptions = [];
  trace = [traceRow({}), traceRow({ stage: 'assessed', settlement_id: null, settlement_no: null, amount: 500, basis: 'charge line allocated to the insurer share' })];
});

const mount = () => render(<MemoryRouter><StatutoryChargesReport /></MemoryRouter>);

describe('statutory charges report', () => {
  it('asks the server for the summary and the reconciliation for the same period', async () => {
    mount();
    await screen.findByText('Insurance Training Levy');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_statutory_charges', expect.objectContaining({ p_group_by: 'charge', p_include_imported: false, p_include_manual: false }));
    expect(rpcMock).toHaveBeenCalledWith('ins_report_statutory_charge_exceptions', expect.objectContaining({ p_include_imported: false }));
    expect(rpcMock).not.toHaveBeenCalledWith('ins_report_statutory_charge_trace', expect.anything());
  });

  it('shows who remits to the authority and never adds currencies together', async () => {
    mount();
    expect((await screen.findAllByText('Insurer remits')).length).toBe(2);
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('UGX: assessed');
    expect(text).toContain('USD: assessed');
    expect(text).not.toContain('1,207');
  });

  it('says the reconciliation holds when nothing is listed', async () => {
    mount();
    await screen.findByText(/the charge allocations equal the pass-through booked/);
    expect(screen.queryByText(/do not reconcile/)).not.toBeInTheDocument();
  });

  it('lists every item that does not reconcile, with recorded, booked and difference', async () => {
    exceptions = [{ check_name: 'allocation', policy_id: 'p2', policy_no: 'POL-002', insurer_name: 'Alpha', recorded_amount: 300, booked_amount: 301, difference: -1 }];
    mount();
    await screen.findByText(/1 item do not reconcile/);
    expect(screen.getByText('POL-002')).toBeInTheDocument();
    expect(screen.getByText('Charge allocations differ from the booked pass-through')).toBeInTheDocument();
    expect(screen.getByText('-1')).toBeInTheDocument();
  });

  it('loads the trace only when asked, then shows the working of each split', async () => {
    mount();
    await screen.findByText('Insurance Training Levy');
    await userEvent.click(screen.getByLabelText(/Show the trace/));
    await screen.findByText('pro rata: receipt 33333 x allocation 500 / invoice 100500');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_statutory_charge_trace', expect.objectContaining({ p_include_manual: false }));
    expect(screen.getByText('RCP-001')).toBeInTheDocument();
  });

  it('exports the summary rows as the server returned them', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [name, sheet, columns, rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^statutory-charges-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Statutory charges');
    expect(rows).toHaveLength(2);
    expect(columns[0].header).toBe('Charge');
    expect(columns[3].accessor(rows[0])).toBe(1166.67);
    expect(columns[8].accessor(rows[0])).toBe('Insurer remits');
  });

  it('offers no export when nothing was assessed', async () => {
    summary = [];
    mount();
    await screen.findByText('No statutory charges were assessed on policies bound in this period.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
